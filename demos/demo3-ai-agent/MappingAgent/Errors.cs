namespace MappingAgent;

static class Errors
{
    /// <summary>
    /// The useful part of stderr, for the screen and for the repair prompt. Python puts the
    /// exception on the LAST line of a traceback (the first line is just "Traceback …"), so
    /// tracebacks keep their tail; everything else keeps its head.
    /// </summary>
    public static (string Shown, string Headline) Summarize(string stderr, int maxLines = 4)
    {
        var lines = stderr.Trim().Split('\n', StringSplitOptions.RemoveEmptyEntries);
        if (lines.Length == 0) return ("", "");

        if (lines.Any(l => l.StartsWith("Traceback")))
        {
            var tail = lines.TakeLast(maxLines).ToArray();
            return (string.Join('\n', tail), lines[^1].Trim());
        }

        var head = lines.Take(maxLines).ToList();
        if (lines.Length > maxLines) head.Add($"… ({lines.Length - maxLines} more)");
        return (string.Join('\n', head), lines[0].Trim());
    }
}
