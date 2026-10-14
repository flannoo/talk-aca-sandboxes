namespace MappingAgent;

/// <summary>
/// What the model writes, and how the sandbox runs it: Python, standard library only.
/// Easy to read on a slide, no compile step, and a network library one import away.
/// </summary>
sealed record Language(
    string Name,
    string Fence,            // markdown code-fence tag the model is asked to use
    string Ext,
    string Snapshot,         // warm snapshot the agent forks from
    string SystemPrompt,
    string RunCommand)
{
    public static readonly Language Python = new(
        "Python", "python", "py",
        Environment.GetEnvironmentVariable("AGENT_SNAPSHOT_PY") is { Length: > 0 } s ? s : "agent-py",
        Environment.GetEnvironmentVariable("AGENT_PROMPT") == "full" ? Prompts.SystemPythonFull : Prompts.SystemPython,
        RunCommand: "python3 transform.py /work/input.csv");
}
