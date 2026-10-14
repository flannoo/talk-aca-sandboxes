using System.Diagnostics;
using AcaTalk.Sandbox;

// Middleware API — the integration-team shape. It receives an inbound partner file
// and, instead of parsing it in-process (next to our Service Bus connection and
// managed identity), hands the parse to a disposable, egress-denied sandbox.

var app = WebApplication.CreateBuilder(args).Build();

var snapshot = Environment.GetEnvironmentVariable("PARSER_SNAPSHOT");
var diskId = Environment.GetEnvironmentVariable("DEMO_DISK_ID");
var parserPath = Path.Combine(AppContext.BaseDirectory, "parser", "parser.cs");

// The sandbox client needs the sandbox-group settings (env.ps1) and the az/aca CLIs. Without
// them (e.g. the Express deployment in Demo 4) the API still starts: /healthz works and
// /ingest answers 503, instead of the container crashing at startup.
SandboxClient? client = null;
try
{
    client = new SandboxClient();
    await client.WarmUpAsync(snapshot is { Length: > 0 } ? snapshot : null);   // token + snapshot id, before the first request
    app.Logger.LogInformation("sandbox transport: {Transport} (set SANDBOX_TRANSPORT=cli to fall back)", client.Transport);
}
catch (Exception ex)
{
    client = null;
    app.Logger.LogWarning("sandbox client not configured ({Message}); /ingest disabled, /healthz still up", ex.Message);
}

app.MapGet("/healthz", () => Results.Ok(new { status = "healthy", at = DateTimeOffset.Now }));

// POST a partner file. ?keep=true leaves the sandbox running so you can inspect it live.
app.MapPost("/ingest", async (HttpRequest req, ILogger<Program> log, bool keep = false) =>
{
    if (client is not { } sandbox)
        return Results.Problem("Sandbox client not configured in this deployment (no sandbox-group settings).", statusCode: 503);
    var transport = sandbox.Transport;

    var tmp = Path.GetTempFileName();
    await using (var fs = File.Create(tmp))
        await req.Body.CopyToAsync(fs);
    log.LogInformation("ingest: {Bytes} bytes received, handing off to a sandbox", new FileInfo(tmp).Length);

    var sw = Stopwatch.StartNew();
    string? id = null;
    try
    {
        // From the warm snapshot the parser is already on disk and compiled.
        id = snapshot is { Length: > 0 }
            ? await sandbox.CreateAsync(snapshot: snapshot, labels: Labels())
            : await sandbox.CreateAsync(diskId: diskId, labels: Labels());
        var bootMs = sw.ElapsedMilliseconds;
        log.LogInformation("ingest: sandbox {Id} up in {Ms} ms", id, bootMs);

        // No separate `egress set`: create --egress-default Deny already yields
        // Deny + Full inspection (verified), and it's in force before the box runs anything.
        if (snapshot is not { Length: > 0 })
            await sandbox.WriteFileAsync(id, "/app/parser.cs", parserPath);
        await sandbox.WriteFileAsync(id, "/in/input.xml", tmp);

        var run = await sandbox.ExecAsync(id, "dotnet run /app/parser.cs -- /in/input.xml");
        var body = new
        {
            parsedIn = "sandbox",
            transport,
            sandboxId = id,
            kept = keep,
            bootMs,
            totalMs = sw.ElapsedMilliseconds,
            exitCode = run.ExitCode,
            output = run.Stdout.TrimEnd().Split('\n'),
        };
        // A failed parse is the partner's problem, not an outage: 422, API stays healthy.
        if (run.Ok) log.LogInformation("ingest: parsed OK in {Ms} ms", sw.ElapsedMilliseconds);
        else log.LogWarning("ingest: parse FAILED inside sandbox (exit {Code}) — API unaffected", run.ExitCode);
        return run.Ok ? Results.Ok(body) : Results.UnprocessableEntity(body);
    }
    catch (SandboxException ex)
    {
        log.LogError("ingest: sandbox call failed: {Message}", ex.Message);
        return Results.Problem(ex.Message, statusCode: 502);
    }
    finally
    {
        // Disposable: no residue. Delete in the background — even with --no-wait the call
        // takes seconds, and the partner shouldn't wait for our cleanup.
        if (id is not null && !keep)
            _ = sandbox.DeleteAsync(id).ContinueWith(
                t => log.LogWarning("ingest: cleanup of {Id} failed: {Error}", id, t.Exception?.GetBaseException().Message),
                TaskContinuationOptions.OnlyOnFaulted);
        File.Delete(tmp);
    }
});

app.Run(Environment.GetEnvironmentVariable("MIDDLEWARE_URL") ?? "http://localhost:5099");

static Dictionary<string, string> Labels() => new() { ["name"] = "parsebox", ["demo"] = "2" };
