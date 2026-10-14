#:sdk Microsoft.NET.Sdk.Web
#:property PublishAot=false
// .NET 10 file-based app: a whole web API in one file, no .csproj.
// Run inside the sandbox with: dotnet run hello.cs
// (File-based apps default to PublishAot=true, which turns off reflection-based JSON;
//  returning an anonymous object below needs it back on.)

var app = WebApplication.CreateBuilder(args).Build();

app.MapGet("/", () => new
{
    message = "hello from a microVM",
    host = Environment.MachineName,
    os = System.Runtime.InteropServices.RuntimeInformation.OSDescription,
    dotnet = Environment.Version.ToString(),
});

app.Run("http://0.0.0.0:8080");
