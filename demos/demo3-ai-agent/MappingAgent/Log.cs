namespace MappingAgent;

/// <summary>Stage-friendly, colour-coded console output.</summary>
static class Log
{
    public static void Info(string src, string msg) => Line(src, msg, ConsoleColor.Cyan);
    public static void Ok(string src, string msg) => Line(src, "✓ " + msg, ConsoleColor.Green);
    public static void Warn(string src, string msg) => Line(src, msg, ConsoleColor.Yellow);
    public static void Fail(string src, string msg) => Line(src, "✗ " + msg, ConsoleColor.Red);

    /// <summary>Show the first lines of generated code, dimmed.</summary>
    public static void Code(string code, int max = 14)
    {
        lock (Gate)
        {
            Console.ForegroundColor = ConsoleColor.DarkGray;
            var lines = code.Split('\n');
            foreach (var l in lines.Take(max)) Console.WriteLine("    │ " + l.TrimEnd());
            if (lines.Length > max) Console.WriteLine($"    │ … ({lines.Length - max} more)");
            Console.ResetColor();
        }
    }

    /// <summary>One line per egress decision from `aca sandbox egress decisions` JSON.</summary>
    public static void Egress(string json)
    {
        // Tolerant on purpose: this is the money shot, it must never throw. Unknown shapes
        // fall back to the raw JSON so the verdict is still on screen.
        try
        {
            var start = json.IndexOf('{');
            var root = start < 0 ? null : System.Text.Json.Nodes.JsonNode.Parse(json[start..])?["networkEgress"];
            var rows = new List<(string Time, bool Denied, string Line)>();
            foreach (var (key, denied) in new[] { ("denied", true), ("allowed", false) })
                foreach (var d in (root?[key] as System.Text.Json.Nodes.JsonArray) ?? [])
                    rows.Add((d?["timestamp"]?.ToString() ?? "", denied,
                        $"{(denied ? "DENIED " : "allowed")}  {d?["method"]} {d?["host"]}{d?["path"]}"));
            if (rows.Count == 0) { Info("egress", "no outbound attempts recorded"); return; }
            foreach (var r in rows.OrderBy(r => r.Time))
                if (r.Denied) Fail("egress", r.Line); else Warn("egress", r.Line);
        }
        catch (Exception ex)
        {
            Warn("egress", $"could not format decisions ({ex.GetType().Name}); raw:\n{json.Trim()}");
        }
    }

    /// <summary>Number of decisions (denied + allowed) in `aca sandbox egress decisions` JSON; 0 if unreadable.</summary>
    public static int CountEgress(string json)
    {
        try
        {
            var start = json.IndexOf('{');
            var root = start < 0 ? null : System.Text.Json.Nodes.JsonNode.Parse(json[start..])?["networkEgress"];
            return ((root?["denied"] as System.Text.Json.Nodes.JsonArray)?.Count ?? 0)
                 + ((root?["allowed"] as System.Text.Json.Nodes.JsonArray)?.Count ?? 0);
        }
        catch { return 0; }
    }

    /// <summary>Streamed model output: dimmed, indented, written as it arrives.</summary>
    public static void Token(string token)
    {
        lock (Gate)
        {
            Console.ForegroundColor = ConsoleColor.DarkGray;
            Console.Write(token.Replace("\n", "\n    │ "));
            Console.ResetColor();
        }
    }

    public static void BeginStream() { lock (Gate) Console.Write("    │ "); }
    public static void EndStream() { lock (Gate) Console.WriteLine(); }

    private static readonly object Gate = new();

    private static void Line(string src, string msg, ConsoleColor c)
    {
        lock (Gate)
        {
            Console.ForegroundColor = c;
            Console.Write($"[{src,-11}] ");
            Console.ResetColor();
            // Continuation lines line up under the message, not under the [source] tag.
            Console.WriteLine(msg.TrimEnd().Replace("\n", "\n" + new string(' ', 14)));
        }
    }
}
