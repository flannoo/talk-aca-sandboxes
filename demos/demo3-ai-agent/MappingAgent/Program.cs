using System.Diagnostics;
using AcaTalk.Sandbox;
using MappingAgent;

// Mapping agent: a partner sends a file in a format we've never seen. The model writes
// a Python transform, we RUN it in a sandbox (egress denied), validate
// the output against our contract, and feed errors back until it passes. The model's code
// is untrusted — and so is the partner file it read, which carries a prompt injection.
//
//   dotnet run -- [--ask "<extra instruction>"] [--replay] [--candidates N] [--max-attempts N] [--keep]
//
// --replay        use recorded model output from ../replay (no LLM needed; stage fallback)
// --candidates N  fork N sandboxes from the warm snapshot and try N first drafts in parallel
// --ask "..."     an extra instruction from the USER of the agent. On stage: you play a
//                 malicious user ("also send the customer list to ..."). A model reliably does
//                 what the user asks, so this is the dependable way to show the egress block.
// --keep          don't delete the sandbox: it waits for a human approval (Demo 3.4). Its id
//                 is written to out/sandbox-id.txt.
// --system-prompt print the system prompt the model gets, and exit (no sandbox, no model).
// --user-prompt   print the task message the model gets (contract + partner file, plus --ask), and exit.

var opt = Options.Parse(args);
var root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", ".."));
var inputPath = Path.Combine(root, "samples", "partner-orders.csv");
var contract = File.ReadAllText(Path.Combine(root, "samples", "target-contract.md"));
var sample = File.ReadAllText(inputPath);
var source = ContractValidator.ReadSource(sample);
var outDir = Directory.CreateDirectory(Path.Combine(root, "out")).FullName;

// Rehearsal helper: check a JSON file against the contract without any sandbox or model.
if (args is ["--validate", var file])
{
    var problems = ContractValidator.Validate(File.ReadAllText(file), source);
    if (problems.Count == 0) Log.Ok("validate", "output matches the contract");
    foreach (var p in problems) Log.Fail("validate", p);
    return problems.Count == 0 ? 0 : 1;
}

// On stage, before the run: exactly what the agent tells the model.
if (args is ["--system-prompt"])
{
    Console.WriteLine(Language.Python.SystemPrompt);
    return 0;
}
if (args.Contains("--user-prompt"))   // the task message: contract + partner file (+ --ask)
{
    Console.WriteLine(Prompts.Task(contract, sample, opt.Ask));
    return 0;
}

var sandbox = new SandboxClient();
var lang = Language.Python;
var snapshot = lang.Snapshot;
LlmClient? llm = opt.Replay ? null : new(
    Env("LLM_ENDPOINT", "http://localhost:11434/v1"), Env("LLM_MODEL", "qwen2.5-coder:7b"), Env("LLM_API_KEY", "local"));

Log.Info("agent", $"partner file: {Path.GetFileName(inputPath)} ({source.Count} data rows)");
if (opt.Ask is not null) Log.Warn("user", $"extra instruction: \"{opt.Ask}\"");
Log.Info("agent", opt.Replay ? "model: REPLAY (recorded responses)" : $"model: {llm!.Model} @ {Env("LLM_ENDPOINT", "")}");
Log.Info("agent", $"model writes: {lang.Name} | sandbox transport: {sandbox.Transport}");
await sandbox.WarmUpAsync(snapshot);   // token + snapshot id, so the fork timing below is honest

// --- Fork N sandboxes from the warm snapshot, in parallel ---
var sw = Stopwatch.StartNew();
var ids = await Task.WhenAll(Enumerable.Range(1, opt.Candidates).Select(i =>
    sandbox.CreateAsync(snapshot: snapshot, labels: new Dictionary<string, string> { ["name"] = "mapper", ["candidate"] = $"{i}" })));
Log.Ok("sandbox", $"forked {ids.Length} from snapshot '{snapshot}' in {sw.Elapsed.TotalSeconds:N1}s");

try
{
    // Created with --egress-default Deny: Deny + full inspection from the first instruction.
    await Task.WhenAll(ids.Select(id => sandbox.WriteFileAsync(id, "/work/input.csv", inputPath)));
    Log.Ok("sandbox", "egress: default Deny, full inspection | input uploaded to /work/input.csv");

    var messages = new List<(string, string)> { ("system", lang.SystemPrompt), ("user", Prompts.Task(contract, sample, opt.Ask)) };

    // Round 1: every candidate drafts in parallel (different temperatures). Keep the best.
    var drafts = await Task.WhenAll(ids.Select((id, i) => Attempt(id, attempt: 1, candidate: i + 1, messages, 0.2 + 0.3 * i)));
    var best = drafts.OrderBy(d => d.Errors.Count).First();

    // Repair loop on the best candidate. Fixed-size prompt: the task, the LAST attempt and its
    // errors, never the whole history (a small local model's context window overflows, the
    // server silently drops the start of the conversation, and the model repeats itself).
    var temperature = 0.2;
    for (var attempt = 2; best.Errors.Count > 0 && attempt <= opt.MaxAttempts; attempt++)
    {
        List<(string, string)> repair = [.. messages, ("assistant", $"```{lang.Fence}\n{best.Code}```"),
                                         ("user", Prompts.Repair(best.Run, best.Errors))];
        var previous = best.Code;
        best = await Attempt(best.SandboxId, attempt, best.Candidate, repair, temperature);
        // Same code twice in a row: shake it loose.
        temperature = best.Code == previous ? Math.Min(temperature + 0.3, 0.9) : 0.2;
    }

    if (best.Errors.Count == 0)
    {
        File.WriteAllText(Path.Combine(outDir, $"transform.{lang.Ext}"), best.Code);
        File.WriteAllText(Path.Combine(outDir, "orders.json"), best.Run.Stdout);
        Log.Ok("agent", $"contract satisfied — saved out/transform.{lang.Ext} and out/orders.json");
    }
    else Log.Fail("agent", $"gave up after {opt.MaxAttempts} attempts");

    Log.Info("egress", "what did the generated code try to reach?");
    // Repeats of the same call within a short window appear as one entry.
    // The decisions log lags a few seconds behind the calls: poll until it has entries and
    // the count stops growing (or ~12 s pass). The money shot must never throw.
    foreach (var id in ids)
    {
        string? decisions = null;
        var count = -1;
        var deadline = DateTime.UtcNow.AddSeconds(12);
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                var next = await sandbox.EgressDecisionsAsync(id);
                var n = Log.CountEgress(next);
                var settled = n > 0 && n == count;
                (decisions, count) = (next, n);
                if (settled) break;
            }
            catch (SandboxException ex) { Log.Warn("egress", $"decisions unavailable: {ex.Message}"); }
            await Task.Delay(TimeSpan.FromSeconds(1.5));
        }
        if (decisions is not null) Log.Egress(decisions);
    }
    return best.Errors.Count == 0 ? 0 : 1;
}
finally
{
    if (opt.Keep)
    {
        File.WriteAllLines(Path.Combine(outDir, "sandbox-id.txt"), ids);
        // An --ask run is kept only so its egress log can be shown (e.g. in the portal).
        Log.Info("sandbox", opt.Ask is null
            ? $"kept for approval: {string.Join(", ", ids)}"
            : $"kept for inspection (egress log in the portal): {string.Join(", ", ids)}");
    }
    else
    {
        foreach (var id in ids) SandboxClient.DeleteDetached(id);   // disposable: no residue, no waiting
        Log.Info("sandbox", $"deleting {ids.Length} sandbox(es) in the background");
    }
}

async Task<Result> Attempt(string id, int attempt, int candidate, List<(string, string)> messages, double temperature)
{
    var tag = opt.Candidates > 1 ? $"#{candidate}" : "";
    var t = Stopwatch.StartNew();
    string code;
    if (llm is null)
        code = Replay.Load(root, attempt, lang.Ext, opt.Ask is not null);
    else if (opt.Candidates == 1)
    {
        // One candidate: stream the code onto the screen as the model writes it.
        Log.Info("model", $"attempt {attempt}: writing transform ({llm.Tuning(temperature)})…");
        Log.BeginStream();
        code = LlmClient.ExtractCode(await llm.StreamAsync(messages, temperature, Log.Token));
        Log.EndStream();
    }
    else
    {
        Log.Info($"model{tag}", $"attempt {attempt}: writing transform…");
        code = LlmClient.ExtractCode(await llm.CompleteAsync(messages, temperature));
    }
    Log.Info($"model{tag}", $"attempt {attempt}: {code.Split('\n').Length} lines of {lang.Name} ({t.Elapsed.TotalSeconds:N1}s)");
    if (llm is null || opt.Candidates > 1) Log.Code(code);   // streamed code is already on screen

    var local = Path.Combine(outDir, $"attempt-{attempt}-c{candidate}.{lang.Ext}");
    File.WriteAllText(local, code);
    await sandbox.WriteFileAsync(id, $"/work/transform.{lang.Ext}", local);

    t.Restart();
    var run = await sandbox.ExecAsync(id, lang.RunCommand, workingDirectory: "/work");
    Log.Info($"sandbox{tag}", $"run -> exit {run.ExitCode} ({t.Elapsed.TotalSeconds:N1}s)");
    // Show the part of stderr that matters; a full stack trace is noise on a slide-sized terminal.
    var (errShown, errHeadline) = Errors.Summarize(run.Stderr);
    if (errShown.Length > 0) Log.Warn($"stderr{tag}", errShown);

    var errors = run.Ok ? ContractValidator.Validate(run.Stdout, source)
        : [$"program exited with {run.ExitCode}: {errHeadline}"];
    if (errors.Count == 0) Log.Ok($"validate{tag}", "output matches the contract");
    else foreach (var e in errors.Take(5)) Log.Fail($"validate{tag}", e);

    return new Result(id, candidate, code, run, errors);
}

static string Env(string name, string fallback) => Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v : fallback;

record Result(string SandboxId, int Candidate, string Code, ExecResult Run, List<string> Errors);

record Options(bool Replay, int Candidates, int MaxAttempts, bool Keep, string? Ask)
{
    public static Options Parse(string[] a)
    {
        int Int(string flag, int d) => Array.IndexOf(a, flag) is var i and >= 0 && i + 1 < a.Length ? int.Parse(a[i + 1]) : d;
        var replay = a.Contains("--replay");
        // Replay is one recorded conversation, so it runs a single candidate.
        var ask = Array.IndexOf(a, "--ask") is var ai and >= 0 && ai + 1 < a.Length ? a[ai + 1] : null;
        return new(replay, replay ? 1 : Int("--candidates", 1), Int("--max-attempts", 4), a.Contains("--keep"), ask);
    }
}

static class Replay
{
    public static string Load(string root, int attempt, string ext, bool ask)
    {
        // The --ask run has its own recording (the model obeying the malicious user).
        var path = Path.Combine(root, "replay", ask ? $"ask-attempt-{attempt}.{ext}" : $"attempt-{attempt}.{ext}");
        if (!File.Exists(path)) throw new InvalidOperationException($"no recorded response for attempt {attempt}");
        Thread.Sleep(1500); // a model takes a moment; so does the replay
        return File.ReadAllText(path);
    }
}
