using System.Globalization;
using System.Text.Json;

namespace MappingAgent;

/// <summary>
/// Checks the transform's stdout against the target contract AND against the partner file
/// itself. The second part catches silent bugs a format check can't: a price parsed as 1250
/// instead of 12,50 gives a self-consistent lineTotal, and 03.09.2026 read as 9 March is a
/// perfectly valid yyyy-MM-dd. Neither is what the partner sent.
/// </summary>
public static class ContractValidator
{
    public sealed record SourceRow(string OrderId, string Customer, DateOnly OrderDate, string Sku, int Quantity, decimal UnitPrice);

    /// <summary>Data rows of the partner file (semicolon-separated, decimal comma, dd.MM.yyyy).</summary>
    public static List<SourceRow> ReadSource(string partnerFile)
    {
        var de = CultureInfo.GetCultureInfo("de-DE");
        return partnerFile.Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.Length > 0 && char.IsDigit(l[0]))
            .Select(l => l.Split(';'))
            .Select(f => new SourceRow(f[0], f[1], DateOnly.ParseExact(f[2], "dd.MM.yyyy", CultureInfo.InvariantCulture),
                f[3], int.Parse(f[4]), decimal.Parse(f[5], de)))
            .ToList();
    }

    public static List<string> Validate(string stdout, List<SourceRow> source)
    {
        JsonDocument doc;
        try { doc = JsonDocument.Parse(stdout); }
        catch (JsonException ex) { return [$"stdout is not valid JSON: {ex.Message}"]; }

        using (doc)
        {
            if (doc.RootElement.ValueKind != JsonValueKind.Array)
                return ["root must be a JSON array with one object per data row"];

            var rows = doc.RootElement.EnumerateArray().ToList();
            var errors = new List<string>();
            if (rows.Count != source.Count)
                errors.Add($"expected {source.Count} rows (one per data row), got {rows.Count}");

            for (var i = 0; i < Math.Min(rows.Count, source.Count); i++)
            {
                var r = rows[i];
                var s = source[i];
                var id = $"row {i + 1} ({s.OrderId}/{s.Sku})";

                if (Str(r, "orderId") != s.OrderId) errors.Add($"{id}: orderId should be \"{s.OrderId}\"");
                var customer = Str(r, "customer");
                if (customer is not { Length: > 0 }) errors.Add($"{id}: customer missing");
                else if (customer != s.Customer) errors.Add($"{id}: customer is \"{customer}\", partner file says \"{s.Customer}\"");
                if (Str(r, "sku") != s.Sku) errors.Add($"{id}: sku should be \"{s.Sku}\"");

                var date = Str(r, "orderDate");
                if (!DateOnly.TryParseExact(date, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed))
                    errors.Add($"{id}: orderDate '{date}' is not yyyy-MM-dd");
                else if (parsed != s.OrderDate)
                    errors.Add($"{id}: orderDate is {date}, partner file says {s.OrderDate:yyyy-MM-dd} (check day/month order)");

                if (!r.TryGetProperty("quantity", out var q) || q.ValueKind != JsonValueKind.Number || !q.TryGetInt32(out var qty))
                    errors.Add($"{id}: quantity must be an integer");
                else if (qty != s.Quantity)
                    errors.Add($"{id}: quantity is {qty}, partner file says {s.Quantity}");

                if (Num(r, "unitPrice") is not { } price)
                    errors.Add($"{id}: unitPrice must be a number");
                else if (price != s.UnitPrice)
                    errors.Add($"{id}: unitPrice is {Fmt(price)}, partner file says {Fmt(s.UnitPrice)} (check decimal parsing)");

                if (Num(r, "lineTotal") is not { } total)
                    errors.Add($"{id}: lineTotal must be a number");
                else if (Math.Abs(total - s.Quantity * s.UnitPrice) > 0.005m)
                    errors.Add($"{id}: lineTotal is {Fmt(total)}, should be {Fmt(s.Quantity * s.UnitPrice)}");
            }
            return errors;
        }
    }

    private static string Fmt(decimal d) => d.ToString(CultureInfo.InvariantCulture);

    private static string? Str(JsonElement e, string n) =>
        e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static decimal? Num(JsonElement e, string n) =>
        e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDecimal() : null;
}
