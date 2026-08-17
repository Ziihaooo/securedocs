# Multi-stage build: compile with the SDK (~800MB), ship with the runtime (~220MB).
# The SDK never reaches the final image — smaller pulls, and no compiler for an
# attacker who gets a shell.
#
# TODO (Phase 3): pin both base images by DIGEST, not tag.
#   FROM mcr.microsoft.com/dotnet/aspnet:9.0@sha256:<digest>
# A tag is mutable — ":9.0" points at a different image next month, so the same
# commit produces a different binary. Digests are what make a build reproducible
# and what cosign attestations actually attest to.

FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /src

# Restore before copying source, so editing Program.cs doesn't invalidate the
# NuGet layer and re-download every package.
COPY Api.csproj .
RUN dotnet restore

COPY . .
RUN dotnet publish -c Release -o /app --no-restore \
    # Drops ICU (~28MB) — safe because this API doesn't do culture-aware
    # formatting or comparison. Revisit if you add localisation.
    -p:InvariantGlobalization=true

# ── Runtime image ───────────────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/aspnet:9.0
WORKDIR /app

# Copy as root, run as non-root: the app owns nothing it executes, so a
# compromised process cannot rewrite its own binaries.
COPY --from=build /app .

# .NET 8+ listens on 8080 by default. Ports below 1024 would require root.
EXPOSE 8080

# Removes the diagnostic IPC socket — an in-container debug channel with no
# production use and a privilege-escalation path if abused.
ENV DOTNET_EnableDiagnostics=0

# NOT set: ASPNETCORE_FORWARDEDHEADERS_ENABLED. It would make the host insert
# ForwardedHeaders middleware automatically, and Program.cs already calls
# UseForwardedHeaders() explicitly. The middleware CONSUMES one entry from
# X-Forwarded-For each time it runs, so running it twice pops two entries and
# reports the wrong client IP. Configure it in code, where the options
# (KnownProxies, ForwardLimit) live — not here.

# APP_UID (1654) is baked into the Microsoft base image. Non-root is required by
# the Pod Security Standard "restricted" profile enforced in Phase 4 — set it now
# so the image doesn't have to change later.
USER $APP_UID

ENTRYPOINT ["dotnet", "Api.dll"]
