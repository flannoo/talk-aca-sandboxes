# Build context is demos\ (the project links shared\Sandbox and demo2-hostile-file\parser):
#   az acr build -r <acr> -t middleware:v1 -f demos\demo2-hostile-file\Middleware\Dockerfile demos
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY shared/Sandbox/ shared/Sandbox/
COPY demo2-hostile-file/parser/ demo2-hostile-file/parser/
COPY demo2-hostile-file/Middleware/ demo2-hostile-file/Middleware/
RUN dotnet publish demo2-hostile-file/Middleware -c Release -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app .
ENV MIDDLEWARE_URL=http://+:8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "Middleware.dll"]
