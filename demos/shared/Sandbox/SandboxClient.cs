using System.Diagnostics;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace AcaTalk.Sandbox;

/// <summary>
/// Thin .NET client over Azure Container Apps Sandboxes, shared by Demo 2 and Demo 3.
/// There is no .NET SDK yet (Python and TypeScript exist, .NET is announced).
///
/// Two transports, picked with SANDBOX_TRANSPORT:
///   rest (default) — hot-path calls (create, file write, exec, delete) go straight to the
///                    data-plane REST API with ONE cached Entra token. Sub-second forks.
///                    Pins a preview api-version (SANDBOX_API_VERSION), so it can break
///                    when the service moves.
///   cli            — every call shells out to the `aca` CLI. Slower (~1.1 s per call: the CLI
///                    fetches a fresh token via `az` each time) but tracks the service for you.
/// Off-path calls (egress decisions, file read, snapshot lookup) always use the CLI.
/// </summary>
public sealed class SandboxClient
{
    private readonly bool _rest;
    private readonly RestTransport? _api;

    public SandboxClient()
    {
        var mode = Environment.GetEnvironmentVariable("SANDBOX_TRANSPORT");
        _rest = !string.Equals(mode, "cli", StringComparison.OrdinalIgnoreCase);
        if (_rest) _api = RestTransport.FromEnvironment();
    }

    /// <summary>"rest" or "cli" — surfaced in logs and API responses.</summary>
    public string Transport => _rest ? "rest" : "cli";

    /// <param name="diskId">Private disk id (e.g. the .NET 10 SDK disk). Ignored when <paramref name="snapshot"/> is set.</param>
    public async Task<string> CreateAsync(string? diskId = null, string? snapshot = null,
        IDictionary<string, string>? labels = null, bool denyEgress = true)
    {
        if (snapshot is null && diskId is null) throw new ArgumentNullException(nameof(diskId));
        if (_rest)
        {
            var snapshotId = snapshot is null ? null : await ResolveSnapshotIdAsync(snapshot);
            return await _api!.CreateAsync(diskId, snapshotId, labels, denyEgress);
        }

        var args = new List<string> { "sandbox", "create" };
        if (snapshot is not null) args.AddRange(["--snapshot", snapshot]);
        else args.AddRange(["--disk-id", diskId!]);
        foreach (var (k, v) in labels ?? new Dictionary<string, string>())
            args.AddRange(["--label", $"{k}={v}"]);
        // Deny from the first instruction: no window where the box can talk out.
        if (denyEgress) args.AddRange(["--egress-default", "Deny"]);

        // create prints "Creating sandbox <id>..." before the JSON, even with -o json.
        var output = await Aca(args, json: true);
        var start = output.IndexOfAny(['{', '[']);
        if (start >= 0)
        {
            using var doc = JsonDocument.Parse(output[start..]);
            if (doc.RootElement.TryGetProperty("id", out var idProp)) return idProp.GetString()!;
        }
        var m = Regex.Match(output, @"[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}");
        return m.Success ? m.Value : throw new SandboxException($"no sandbox id in: {output.Trim()}");
    }

    public Task WriteFileAsync(string id, string remotePath, string localPath) => _rest
        ? _api!.WriteFileAsync(id, remotePath, localPath)
        : Aca(["sandbox", "fs", "write", "--id", id, "--path", remotePath, "--file", localPath]);

    public Task<string> ReadFileAsync(string id, string remotePath) =>
        Aca(["sandbox", "fs", "cat", "--id", id, "--path", remotePath]);

    /// <summary>Run a shell command in the sandbox. Never throws on a non-zero remote exit code.</summary>
    public async Task<ExecResult> ExecAsync(string id, string command, string? workingDirectory = null)
    {
        // The .NET CLI phones home with telemetry (dc.services.visualstudio.com). Under
        // deny-default egress those show up as extra Denied entries; opt out so the
        // decisions log only shows what the workload itself tried.
        command = "export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1; " + command;

        if (_rest)
        {
            if (workingDirectory is not null) command = $"cd '{workingDirectory}' && {command}";
            return await _api!.ExecAsync(id, command);
        }

        // CLI: remote stdout/stderr pass straight through, and the CLI's exit code IS the
        // remote exit code (verified on aca 1.0.0-preview.4). No JSON envelope.
        var args = new List<string> { "sandbox", "exec", "--id", id, "-c", command };
        if (workingDirectory is not null) args.AddRange(["--working-directory", workingDirectory]);
        var (code, stdout, stderr) = await Run(args, json: false);
        return new ExecResult(code, stdout, stderr);
    }

    public Task<string> EgressDecisionsAsync(string id) =>
        Aca(["sandbox", "egress", "decisions", "--id", id]);

    /// <summary>
    /// Takes ~6 s for a running sandbox on either transport (the service-side DELETE blocks),
    /// so callers on a request path should not await it.
    /// </summary>
    public Task DeleteAsync(string id) => _rest
        ? _api!.DeleteAsync(id)
        : Aca(["sandbox", "delete", "--id", id, "--yes", "--no-wait"]);

    /// <summary>
    /// Pay the one-off costs (token fetch, snapshot name lookup) up front, so the first
    /// request isn't the slow one. No-op for the CLI transport.
    /// </summary>
    public async Task WarmUpAsync(string? snapshot = null)
    {
        if (!_rest) return;
        await _api!.WarmUpAsync();
        if (snapshot is not null) await ResolveSnapshotIdAsync(snapshot);
    }

    /// <summary>
    /// Fire-and-forget delete that outlives this process: for a CLI tool that exits right
    /// after its work (the service-side delete blocks ~6 s; nobody should watch that).
    /// </summary>
    public static void DeleteDetached(string id)
    {
        var psi = new ProcessStartInfo("aca") { UseShellExecute = false, CreateNoWindow = true };
        foreach (var a in new[] { "sandbox", "delete", "--id", id, "--yes" }) psi.ArgumentList.Add(a);
        Process.Start(psi);
    }

    // Snapshot name -> id, cached (REST create takes the id).
    private readonly Dictionary<string, string> _snapshotIds = [];

    private async Task<string> ResolveSnapshotIdAsync(string name)
    {
        lock (_snapshotIds) if (_snapshotIds.TryGetValue(name, out var cached)) return cached;
        using var doc = JsonDocument.Parse(await Aca(["sandboxgroup", "snapshot", "list"], json: true));
        foreach (var s in doc.RootElement.EnumerateArray())
            if (s.TryGetProperty("labels", out var l) && l.TryGetProperty("name", out var n) && n.GetString() == name)
            {
                var id = s.GetProperty("id").GetString()!;
                lock (_snapshotIds) _snapshotIds[name] = id;
                return id;
            }
        throw new SandboxException($"snapshot '{name}' not found (aca sandboxgroup snapshot list)");
    }

    private static async Task<string> Aca(IEnumerable<string> args, bool json = false)
    {
        var (code, stdout, stderr) = await Run(args, json);
        if (code != 0)
            throw new SandboxException($"aca {string.Join(' ', args)} failed ({code}): {stderr.Trim()}");
        return stdout;
    }

    internal static async Task<(int, string, string)> Run(IEnumerable<string> args, bool json, string exe = "aca")
    {
        var psi = new ProcessStartInfo(exe)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        if (json) { psi.ArgumentList.Add("-o"); psi.ArgumentList.Add("json"); }

        using var p = Process.Start(psi) ?? throw new SandboxException($"could not start {exe}");
        var stdout = p.StandardOutput.ReadToEndAsync();
        var stderr = p.StandardError.ReadToEndAsync();
        await p.WaitForExitAsync();
        return (p.ExitCode, await stdout, await stderr);
    }
}

/// <summary>
/// Direct data-plane calls with a cached token. Shapes captured from `aca --verbose`
/// (aca 1.0.0-preview.4, api-version 2026-02-01-preview).
/// </summary>
internal sealed class RestTransport(string baseUrl, string apiVersion)
{
    private const string Scope = "https://dynamicsessions.io";
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromMinutes(5) };
    private readonly SemaphoreSlim _tokenLock = new(1, 1);
    private string? _token;
    private DateTimeOffset _tokenExpires;

    public static RestTransport FromEnvironment()
    {
        string Need(string name) => Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v
            : throw new SandboxException($"SANDBOX_TRANSPORT=rest needs {name} (dot-source demos\\shared\\env.ps1), or set SANDBOX_TRANSPORT=cli");
        var baseUrl = $"https://management.{Need("ACA_REGION")}.azuredevcompute.io/subscriptions/{Need("ACA_SUBSCRIPTION")}" +
                      $"/resourceGroups/{Need("ACA_RESOURCE_GROUP")}/sandboxGroups/{Need("ACA_SANDBOX_GROUP")}/sandboxes";
        var api = Environment.GetEnvironmentVariable("SANDBOX_API_VERSION") is { Length: > 0 } v ? v : "2026-02-01-preview";
        return new RestTransport(baseUrl, api);
    }

    public async Task<string> CreateAsync(string? diskId, string? snapshotId, IDictionary<string, string>? labels, bool denyEgress)
    {
        var body = new JsonObject
        {
            ["labels"] = new JsonObject((labels ?? new Dictionary<string, string>())
                .Select(kv => KeyValuePair.Create(kv.Key, (JsonNode?)kv.Value))),
            ["sourcesRef"] = snapshotId is not null
                ? new JsonObject { ["snapshot"] = new JsonObject { ["id"] = snapshotId } }
                : new JsonObject { ["diskImage"] = new JsonObject { ["id"] = diskId } },
        };
        if (denyEgress) body["egressPolicy"] = new JsonObject { ["defaultAction"] = "Deny" };
        if (snapshotId is null)
        {
            // A disk create must state its size (the CLI fills in defaults); a snapshot carries its own.
            body["resources"] = new JsonObject
            {
                ["cpu"] = Environment.GetEnvironmentVariable("DEMO_SIZE_CPU") is { Length: > 0 } c ? c : "1000m",
                ["memory"] = Environment.GetEnvironmentVariable("DEMO_SIZE_MEMORY") is { Length: > 0 } m ? m : "2048Mi",
            };
            body["lifecycle"] = new JsonObject   // what the CLI sends for a disk create
            {
                ["autoSuspendPolicy"] = new JsonObject { ["enabled"] = true, ["interval"] = 600, ["mode"] = "Memory" },
            };
        }

        var created = await SendJsonAsync(HttpMethod.Put, Url(""), JsonContent.Create(body));
        var id = created["id"]!.GetValue<string>();

        // The PUT normally returns with state=Running already; poll just in case.
        var deadline = DateTimeOffset.UtcNow.AddSeconds(60);
        var state = created["state"]?.GetValue<string>();
        while (state != "Running")
        {
            if (DateTimeOffset.UtcNow > deadline) throw new SandboxException($"sandbox {id} stuck in state {state}");
            await Task.Delay(250);
            state = (await SendJsonAsync(HttpMethod.Get, Url($"/{id}"), null))["state"]?.GetValue<string>();
        }
        return id;
    }

    public async Task WriteFileAsync(string id, string remotePath, string localPath)
    {
        var content = new ByteArrayContent(await File.ReadAllBytesAsync(localPath));
        content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        await SendJsonAsync(HttpMethod.Put,
            Url($"/{id}/files", $"path={Uri.EscapeDataString(remotePath)}&createDirs=true"), content);
    }

    public async Task<ExecResult> ExecAsync(string id, string command)
    {
        var r = await SendJsonAsync(HttpMethod.Post, Url($"/{id}/executeShellCommand"),
            JsonContent.Create(new JsonObject { ["command"] = command }));
        return new ExecResult(
            r["exitCode"]?.GetValue<int>() ?? -1,
            r["stdout"]?.GetValue<string>() ?? "",
            r["stderr"]?.GetValue<string>() ?? "");
    }

    public Task DeleteAsync(string id) => SendJsonAsync(HttpMethod.Delete, Url($"/{id}"), null);

    public Task WarmUpAsync() => TokenAsync();

    private string Url(string path, string? query = null) =>
        $"{baseUrl}{path}?api-version={apiVersion}" + (query is null ? "" : "&" + query);

    private async Task<JsonNode> SendJsonAsync(HttpMethod method, string url, HttpContent? content)
    {
        using var req = new HttpRequestMessage(method, url) { Content = content };
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await TokenAsync());
        using var res = await _http.SendAsync(req);
        var text = await res.Content.ReadAsStringAsync();
        if (!res.IsSuccessStatusCode)
            throw new SandboxException($"{method} {url.Split('?')[0]} -> {(int)res.StatusCode}: {text.Trim()}");
        return string.IsNullOrWhiteSpace(text) ? new JsonObject() : JsonNode.Parse(text)!;
    }

    /// <summary>One `az` call per ~hour instead of one per operation.</summary>
    private async Task<string> TokenAsync()
    {
        await _tokenLock.WaitAsync();
        try
        {
            if (_token is not null && DateTimeOffset.UtcNow < _tokenExpires.AddMinutes(-5)) return _token;
            // In production: Azure.Identity (managed identity). For the demo, reuse `az login`.
            // On Windows, az is a .cmd wrapper that fails ("Failed to load python executable")
            // when launched by bare name without a shell, so go through cmd.exe.
            string[] azArgs = ["account", "get-access-token", "--resource", Scope];
            var (code, stdout, stderr) = OperatingSystem.IsWindows()
                ? await SandboxClient.Run(["/d", "/c", "az", .. azArgs], json: true, "cmd.exe")
                : await SandboxClient.Run(azArgs, json: true, "az");
            if (code != 0) throw new SandboxException($"az account get-access-token failed: {stderr.Trim()}");
            var t = JsonNode.Parse(stdout)!;
            _token = t["accessToken"]!.GetValue<string>();
            _tokenExpires = t["expires_on"] is { } unix
                ? DateTimeOffset.FromUnixTimeSeconds(unix.GetValueKind() == JsonValueKind.Number ? unix.GetValue<long>() : long.Parse(unix.GetValue<string>()))
                : DateTimeOffset.UtcNow.AddMinutes(30);
            return _token;
        }
        finally { _tokenLock.Release(); }
    }
}

/// <summary>Result of a command run inside the sandbox.</summary>
public sealed record ExecResult(int ExitCode, string Stdout, string Stderr)
{
    public bool Ok => ExitCode == 0;
}

public sealed class SandboxException(string message) : Exception(message);
