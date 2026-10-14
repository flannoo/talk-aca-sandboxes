# Into the sandbox: ACA's Instant Compute for AI Agents and Untrusted Code

Runnable demos for a demo-led talk on **Azure Container Apps Sandboxes** (and **Express**),
aimed at integration and middleware teams. Everything runs from **PowerShell 7 + .NET 10** on
Windows.

The story in one line: first we don't trust a partner's *file*, then we don't even trust the
*code*, because an AI wrote it. Same answer both times: a disposable microVM that can't talk out.

| | Demo | Shows |
|---|---|---|
| 1 | Foundations | The vocabulary: sandbox group, disk, create, exec, files, ports, stop/resume (memory survives) |
| 2 | Hostile partner file | A .NET middleware parses every partner file in its own egress-denied microVM. An XXE payload tries to phone home and is denied; the API stays healthy. A burst of 8 requests shows 8 sandboxes, then auto-suspend |
| 3 | AI mapping agent | A model writes the Python mapping for a new partner format; it only ever runs in a sandbox, a validator loops on errors. A prompt injection in the partner file and a malicious user are both blocked by egress. The mapping then waits for human approval in a *stopped* sandbox and resumes with its process intact |
| 4 | Express | The same middleware image on Express vs. a classic Consumption environment: a cold-start race from zero replicas |

Sandboxes and Express went GA in September 2026. The `aca` CLI is young (tested with
`1.0.0-preview.4`): pin it, and re-test after upgrades.

## Prerequisites

- An Azure subscription where you can create resources (the scripts register `Microsoft.App`)
- [Azure CLI](https://learn.microsoft.com/cli/azure/) with the `containerapp` extension (1.3.0b4+ for Express), signed in with `az login`
- The `aca` CLI (tested with `1.0.0-preview.4`)
- PowerShell 7 and the .NET 10 SDK
- Windows Terminal (Demo 2 opens its API and watcher tabs with `wt`)
- For Demo 3: an OpenAI-compatible model endpoint. Tested with `gpt-5-mini` on Azure AI Foundry; a local model works too (`demos/demo3-ai-agent/setup-local-llm.ps1`), but needs `$env:AGENT_PROMPT = 'full'`

## Configure

`demos/shared/env.ps1` holds the defaults. The names that are yours to choose are set to
`__set_me__`, and the scripts refuse to run until you've set them. Put your values in
**`demos/shared/env.local.ps1`** (git-ignored, loaded automatically):

```powershell
# demos/shared/env.local.ps1 (never commit this file)
$env:ACA_RESOURCE_GROUP = 'rg-sandbox-talk'      # created if it doesn't exist
$env:ACA_SANDBOX_GROUP  = 'sandbox-talk'         # created if it doesn't exist

# Demo 3: the model (any OpenAI-compatible endpoint)
$env:LLM_ENDPOINT = 'https://<your-foundry-resource>.services.ai.azure.com/openai/v1'
$env:LLM_MODEL    = 'gpt-5-mini'                 # your deployment name
$env:LLM_API_KEY  = '<key>'

# Demo 4: Express (all created by demo4-express\prepare.ps1)
$env:ACR_NAME         = 'acrtalk<initials>'      # globally unique; use a throwaway registry
$env:EXPRESS_IDENTITY = 'id-sandbox-talk'
$env:EXPRESS_ENV      = 'cae-express-talk'
$env:EXPRESS_APP      = 'middleware-express'
$env:CLASSIC_ENV      = 'cae-classic-talk'
$env:CLASSIC_APP      = 'middleware-classic'
```

The region defaults to `westeurope`; override `$env:ACA_REGION` if you need another one.

## Set up (once)

```powershell
.\demos\shared\00-setup.ps1                 # resource group, sandbox group, .NET SDK disk (a few minutes)
.\demos\demo2-hostile-file\prepare.ps1      # bakes the 'parser-warm' snapshot
.\demos\demo3-ai-agent\prepare.ps1          # bakes the 'agent-py' snapshot
.\demos\demo4-express\prepare.ps1           # ACR, image, two environments, two apps
```

Run Demo 4's `prepare.ps1` at least 10 minutes before Demo 4, then leave both apps alone: the
race needs both at zero replicas.

## Run

```powershell
.\start-demos.ps1
```

A menu picks a demo (Demo 3: live model or recorded replay). Inside a demo, **Enter** runs the
next step, **s** skips it, **q** stops the demo. When a demo ends its output stays on screen
until you press **m**.

Each demo also runs on its own: `.\demos\demo1-foundations\demo1.ps1` and so on.
`$env:DEMO_AUTO = '1'` runs a demo without waiting for keypresses (rehearsal/smoke test).

## Good to know

- **Demo 3 without a model:** `.\demos\demo3-ai-agent\demo3.ps1 -Replay` plays back recorded
  model responses. Everything on the sandbox side stays live.
- **Check output against the contract** without Azure or a model:
  `dotnet run --project .\demos\demo3-ai-agent\MappingAgent -- --validate <file.json>`
- **Don't run the replay transforms locally.** Outside a sandbox nothing blocks their outbound
  call: they really send the sample's (fictional) order data to httpbin.org.
- **Sandbox transport:** the C# `SandboxClient` calls the data-plane REST API directly with a
  cached token (`SANDBOX_TRANSPORT=rest`, pinned `SANDBOX_API_VERSION`). If that api-version
  ever breaks, set `$env:SANDBOX_TRANSPORT = 'cli'` to go through the `aca` CLI instead (slower).
- **The egress decisions log doesn't list every denied call** (seen with `1.0.0-preview.4`):
  several denied calls in one run can show up as a single row. Every call is still blocked;
  the 403 in the program's stderr is the per-call proof.

## Layout

```
start-demos.ps1               menu to run the demos
demos/
  shared/
    env.ps1                   settings (yours go in env.local.ps1)
    stage.ps1                 Step / Say / Ask helpers and sandbox helpers
    00-setup.ps1              one-time setup
    Sandbox/SandboxClient.cs  thin C# client for sandboxes (REST, CLI fallback)
  demo1-foundations/          demo1.ps1 + hello.cs (a .NET 10 file-based web app)
  demo2-hostile-file/         middleware API, the parser, samples (incl. a defanged XXE file)
  demo3-ai-agent/             the mapping agent, worker.py, replay recordings, samples
  demo4-express/              prepare.ps1 + the cold-start race
```

## Clean up

Sandboxes suspend themselves when idle (5 minutes by default), but they still cost storage.
Remove everything with:

```powershell
az group delete --name $env:ACA_RESOURCE_GROUP --yes
```

This deletes **everything** in that resource group, including anything you put there yourself
(a Foundry resource for Demo 3, for example).
