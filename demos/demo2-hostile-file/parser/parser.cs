#:property PublishAot=false
// Demo 2 parser — stands in for "our own transformation code".
// .NET 10 file-based app. Inside the sandbox: dotnet run /app/parser.cs -- <file>
//
// The point is NOT that this parser is bulletproof — the opposite. It carries a
// real, common misconfiguration: DTD processing on, with a URL resolver, the kind of
// thing copied from an old forum answer to "make entities work". Hand it a file with
// external entities and it will genuinely try to fetch them. The sandbox's
// deny-default egress is what makes that harmless, not this code.
using System.Xml;

if (args is ["--warmup"]) { Console.WriteLine("[parser] warm"); return 0; }
if (args.Length != 1) { Console.Error.WriteLine("usage: parser.cs <file>"); return 2; }

Console.WriteLine($"[parser] processing {args[0]}");
try
{
    var settings = new XmlReaderSettings
    {
        DtdProcessing = DtdProcessing.Parse,   // <- the misconfiguration
        XmlResolver = new XmlUrlResolver(),    // <- resolves file:// and http:// entities
    };
    var doc = new XmlDocument { XmlResolver = new XmlUrlResolver() };
    using (var reader = XmlReader.Create(args[0], settings)) doc.Load(reader);

    var order = doc.DocumentElement!;
    var lines = order.SelectNodes("lines/line")!;
    Console.WriteLine($"  order id : {order["id"]?.InnerText}");
    Console.WriteLine($"  customer : {Trunc(order["customer"]?.InnerText)}");
    Console.WriteLine($"  lines    : {lines.Count}");
    foreach (XmlNode l in lines)
        Console.WriteLine($"    - {l["sku"]?.InnerText} x{l["qty"]?.InnerText}");
    Console.WriteLine("[parser] done");
    return 0;
}
catch (Exception ex)
{
    // One clean line for the stage, no stack trace.
    var root = ex.GetBaseException();
    Console.WriteLine($"[parser] FAILED: {root.GetType().Name}: {root.Message}");
    return 1;
}

static string Trunc(string? s) =>
    s is null ? "<none>" : s.Length <= 60 ? s : s[..60].ReplaceLineEndings(" ") + " …";
