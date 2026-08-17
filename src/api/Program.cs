// SecureDocs API — Day 1.
//
// Uses the framework's built-in health check system rather than hand-rolled
// endpoints, because on Day 3 adding "is Postgres reachable?" becomes one line
// with a tag, instead of another endpoint to write and keep consistent.

using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Extensions.Diagnostics.HealthChecks;

var builder = WebApplication.CreateBuilder(args);

// ── Logging ─────────────────────────────────────────────────────────────────
// JSON to stdout. In Kubernetes you never read a log file — the container writes
// to stdout, the kubelet captures it, and a collector (Loki, CloudWatch) ships
// it. Plain text forces the collector to regex your lines; JSON gives it real
// fields, so "show me every 500 for user X" becomes a query instead of a grep.
builder.Logging.ClearProviders();
builder.Logging.AddJsonConsole(o =>
{
    o.IncludeScopes = true;
    o.TimestampFormat = "yyyy-MM-ddTHH:mm:ss.fffZ";
    o.UseUtcTimestamp = true;
});

// ── Behind a proxy ──────────────────────────────────────────────────────────
// Every request arrives via ingress-nginx, so without this the app thinks the
// client IP is the ingress controller's pod IP and that every request is HTTP.
// That breaks audit logging (item 10 in PROJECT-DESIGN) and redirect URLs.
builder.Services.Configure<ForwardedHeadersOptions>(o =>
{
    o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    // Inside the cluster the proxy is trusted, and its IP changes on every
    // redeploy, so clearing these accepts the headers from in-cluster callers.
    o.KnownNetworks.Clear();
    o.KnownProxies.Clear();
});

// ── Graceful shutdown ───────────────────────────────────────────────────────
// Kubernetes sends SIGTERM, waits, then SIGKILLs. This is the window to finish
// in-flight requests. Must stay BELOW the pod's terminationGracePeriodSeconds
// (default 30s) or the kernel kills you mid-request. Day 18, zero-downtime.
builder.Services.Configure<HostOptions>(o =>
    o.ShutdownTimeout = TimeSpan.FromSeconds(15));

// ── Health checks ───────────────────────────────────────────────────────────
// One registry, three views. Tags decide which check answers which probe.
//
//   startup   has the app finished booting?        -> startupProbe
//   live      is the process wedged? restart me    -> livenessProbe
//   ready     can I serve traffic right now?       -> readinessProbe
//
// The classic outage: pointing all three at one endpoint that checks the
// database. A DB blip fails readiness (correct: stop traffic) AND liveness
// (wrong: restart), so every pod restarts at once while the DB is already
// struggling. Dependencies belong in "ready" only — never in "live".
var connectionString = builder.Configuration.GetConnectionString("Default")
    ?? throw new InvalidOperationException(
        "ConnectionStrings__Default is not set. It is injected from the " +
        "postgres-credentials Secret by k8s/api-deployment.yaml.");

builder.Services.AddHealthChecks()
    .AddCheck<StartupHealthCheck>("startup", tags: ["startup", "ready"])
    .AddCheck("self", () => HealthCheckResult.Healthy(), tags: ["live"])
    // Tagged "ready" ONLY. If Postgres goes down this pod leaves the Service
    // and stops receiving traffic — but is never restarted, because restarting
    // would not bring the database back.
    .AddNpgSql(connectionString, name: "postgres", tags: ["ready"]);

builder.Services.AddSingleton<StartupHealthCheck>();

var app = builder.Build();

app.UseForwardedHeaders();

app.MapGet("/", () => Results.Ok(new ServiceInfo(
    Service: "securedocs-api",
    Version: "0.1.0",
    Environment: app.Environment.EnvironmentName)));

// Each probe endpoint filters the same registry by tag.
app.MapHealthChecks("/healthz/startup", new HealthCheckOptions
{
    Predicate = c => c.Tags.Contains("startup")
});

app.MapHealthChecks("/healthz/live", new HealthCheckOptions
{
    Predicate = c => c.Tags.Contains("live")
});

app.MapHealthChecks("/healthz/ready", new HealthCheckOptions
{
    Predicate = c => c.Tags.Contains("ready")
});

app.Run();

// ── Types ───────────────────────────────────────────────────────────────────

internal record ServiceInfo(string Service, string Version, string Environment);

/// <summary>
/// Stands in for real startup work — config load, cache warm, connection pool.
/// .NET cold start is genuinely slow (item 13 in PROJECT-DESIGN), which is the
/// reason startupProbe exists: it holds off the liveness probe until boot
/// finishes, so a slow start isn't mistaken for a hang and restarted forever.
/// </summary>
internal sealed class StartupHealthCheck : IHealthCheck
{
    private readonly DateTimeOffset _startedAt = DateTimeOffset.UtcNow;
    private readonly TimeSpan _delay;

    public StartupHealthCheck(IConfiguration config) =>
        _delay = TimeSpan.FromSeconds(config.GetValue("STARTUP_DELAY_SECONDS", 5));

    public Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        var elapsed = DateTimeOffset.UtcNow - _startedAt;
        return Task.FromResult(elapsed >= _delay
            ? HealthCheckResult.Healthy("startup complete")
            : HealthCheckResult.Unhealthy($"starting ({elapsed.TotalSeconds:F1}s of {_delay.TotalSeconds:F0}s)"));
    }
}
