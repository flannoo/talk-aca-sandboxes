using System.Net.Http.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace MappingAgent;

/// <summary>
/// Minimal client for any OpenAI-compatible /chat/completions endpoint: Azure AI Foundry /
/// Azure OpenAI (v1 endpoint), Ollama, Foundry Local, LM Studio. No SDK needed.
///
/// Azure endpoints get the `api-key` header and no `temperature` (gpt-5 family reasoning
/// models reject it); they get `reasoning_effort` instead (LLM_REASONING_EFFORT, default low:
/// fast enough for a stage). Local runtimes get a Bearer header and a temperature.
/// </summary>
public sealed class LlmClient(string endpoint, string model, string apiKey)
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromMinutes(5) };
    private readonly bool _azure = Regex.IsMatch(endpoint, @"\.(openai\.azure\.com|services\.ai\.azure\.com|cognitiveservices\.azure\.com)", RegexOptions.IgnoreCase);

    public string Model => model;

    /// <summary>How the model is tuned, for the log line: temperature (local) or reasoning effort (Azure).</summary>
    public string Tuning(double temperature) => _azure ? $"reasoning {Effort}" : $"temperature {temperature:N1}";

    private static string Effort => Environment.GetEnvironmentVariable("LLM_REASONING_EFFORT") is { Length: > 0 } e ? e : "low";

    /// <summary>Tokens used so far (prompt, completion), for the cost line at the end of a run.</summary>
    public (int In, int Out, int Calls) Usage { get; private set; }

    /// <summary>
    /// One chat turn with tools. Returns the assistant message as-is (content and/or
    /// tool_calls), detached so the caller can append it to the conversation.
    /// </summary>
    public async Task<JsonObject> ChatAsync(JsonArray messages, JsonArray? tools = null)
    {
        var body = Body(messages, temperature: 0.2);
        if (tools is not null) body["tools"] = tools.DeepClone();
        var json = await PostAsync(body);
        return (JsonObject)json["choices"]![0]!["message"]!.DeepClone();
    }

    public async Task<string> CompleteAsync(IEnumerable<(string Role, string Content)> messages, double temperature)
    {
        var json = await PostAsync(Body(ToJson(messages), temperature));
        return json["choices"]![0]!["message"]!["content"]!.GetValue<string>();
    }

    /// <summary>
    /// Same call, streamed (server-sent events): each token is handed to <paramref name="onToken"/>
    /// as it arrives, so the audience watches the model write instead of waiting on a spinner.
    /// </summary>
    public async Task<string> StreamAsync(IEnumerable<(string Role, string Content)> messages, double temperature, Action<string> onToken)
    {
        var body = Body(ToJson(messages), temperature);
        body["stream"] = true;
        using var req = Request(body);
        using var res = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead);
        await EnsureOk(res);
        using var reader = new StreamReader(await res.Content.ReadAsStreamAsync());
        var all = new System.Text.StringBuilder();
        while (await reader.ReadLineAsync() is { } line)
        {
            if (!line.StartsWith("data:")) continue;
            var data = line[5..].Trim();
            if (data == "[DONE]") break;
            // Azure's first chunk(s) carry content-filter results and an EMPTY choices array.
            if (JsonNode.Parse(data)?["choices"] is not JsonArray { Count: > 0 } choices) continue;
            var token = choices[0]?["delta"]?["content"]?.GetValue<string>();
            if (string.IsNullOrEmpty(token)) continue;
            all.Append(token);
            onToken(token);
        }
        return all.ToString();
    }

    /// <summary>Pull the program out of a markdown reply (falls back to the whole reply).</summary>
    public static string ExtractCode(string reply)
    {
        var m = Regex.Match(reply, @"```(?:python|py)?\s*\n(.*?)```", RegexOptions.Singleline);
        return (m.Success ? m.Groups[1].Value : reply).Trim() + "\n";
    }

    private JsonObject Body(JsonArray messages, double temperature)
    {
        var body = new JsonObject { ["model"] = model, ["messages"] = messages.DeepClone() };
        if (_azure)
            body["reasoning_effort"] = Effort;
        else
            body["temperature"] = temperature;
        return body;
    }

    private static JsonArray ToJson(IEnumerable<(string Role, string Content)> messages) =>
        new(messages.Select(m => (JsonNode)new JsonObject { ["role"] = m.Role, ["content"] = m.Content }).ToArray());

    private HttpRequestMessage Request(JsonObject body)
    {
        var req = new HttpRequestMessage(HttpMethod.Post, endpoint.TrimEnd('/') + "/chat/completions")
        {
            Content = JsonContent.Create(body),
        };
        if (_azure) req.Headers.Add("api-key", apiKey);
        else req.Headers.Add("Authorization", $"Bearer {apiKey}");
        return req;
    }

    private async Task<JsonObject> PostAsync(JsonObject body)
    {
        using var req = Request(body);
        using var res = await _http.SendAsync(req);
        await EnsureOk(res);
        var json = (await res.Content.ReadFromJsonAsync<JsonObject>())!;
        Usage = (Usage.In + ((int?)json["usage"]?["prompt_tokens"] ?? 0),
                 Usage.Out + ((int?)json["usage"]?["completion_tokens"] ?? 0), Usage.Calls + 1);
        return json;
    }

    // The service's error body says what is wrong (quota, unsupported parameter, content
    // filter); EnsureSuccessStatusCode alone would only say "400".
    private static async Task EnsureOk(HttpResponseMessage res)
    {
        if (res.IsSuccessStatusCode) return;
        var text = await res.Content.ReadAsStringAsync();
        throw new HttpRequestException($"LLM call failed: {(int)res.StatusCode} {res.ReasonPhrase}: {(text.Length > 500 ? text[..500] : text)}");
    }
}
