# Demo 2 middleware API

A .NET 10 minimal API standing in for your integration middleware. `POST /ingest`
receives a partner file and parses it inside a disposable, egress-denied sandbox
forked from the `parser-warm` snapshot instead of parsing it in-process.

## Run it (terminal 1, before Demo 2)

```powershell
. .\demos\shared\env.ps1
dotnet run --project .\demos\demo2-hostile-file\Middleware
# listening on http://localhost:5099
```

## Endpoints

| | |
|---|---|
| `GET /healthz` | Polled by `watch-health.ps1`; stays 200 throughout. |
| `POST /ingest` | Body = partner file. 200 = parsed, 422 = the parse failed *inside* the sandbox. |
| `POST /ingest?keep=true` | Same, but leaves the sandbox running so you can run `aca sandbox egress decisions` on it live. |

```powershell
Invoke-WebRequest -Method Post -InFile ..\samples\order-good.xml -Uri http://localhost:5099/ingest -SkipHttpErrorCheck
```

## Notes

- `parser/parser.cs` is a .NET 10 file-based app. It runs **only** inside the sandbox
  (`dotnet run /app/parser.cs -- <file>`); this project ships it as content.
- The sandbox client (`demos/shared/Sandbox/SandboxClient.cs`) drives the `aca` CLI:
  no .NET SDK exists yet (Python and TypeScript do; .NET is announced).
- The same image is deployed to Express in Demo 4. There `/ingest` would need the
  `aca` CLI plus a managed identity with the SandboxGroup Data Owner role; for the demo
  only `/healthz` is exercised.
