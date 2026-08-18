# Runbook — Pod Running but receiving no traffic (readiness failing)

## Symptom

Requests to the Service fail — connection refused, or 503 from the ingress —
but nothing appears broken. No crashes, no restarts, no errors in the logs.

The tell is the **READY** column, not STATUS:

```
NAME                            READY   STATUS    RESTARTS   AGE
web-notready-69b8944cf4-nvtx8   0/1     Running   0          82s
                                ^^^
```

`Running` means the container process is alive. `0/1` means Kubernetes will not
send it traffic. Those are different questions, and only one of them is in the
STATUS column.

## Diagnosis

**1. Confirm the Service has nothing behind it** — this is the proof:

```bash
kubectl get endpointslice -n <ns> -l kubernetes.io/service-name=<svc>
```

Empty endpoints means the Service is routing to nothing. Every request fails,
and the Service itself looks perfectly healthy in `kubectl get svc`.

**2. Find out why the pods were excluded:**

```bash
kubectl get events -n <ns> --field-selector reason=Unhealthy
```

```
Warning  Unhealthy  Readiness probe failed: HTTP probe failed with statuscode: 404
```

**3. Test the endpoint from inside the pod** — this separates "app broken" from
"probe wrong":

```bash
kubectl exec -n <ns> <pod> -- curl -s -o /dev/null -w '%{http_code}\n' localhost/healthz
```

If the app answers correctly on its real path but the probe path 404s, the app
was never the problem.

## Cause

The readiness probe is asking for something the application does not serve.
Common origins:

- typo in the path (`/healthz` vs `/health`)
- endpoint renamed in code, manifest not updated
- probe port doesn't match the container port
- probe added before the health endpoint was implemented
- a real dependency failure — readiness is *supposed* to fail when the database
  is unreachable

The last one matters: **a failing readiness probe is often correct.** Confirm the
probe is wrong before "fixing" it.

## Fix

Point the probe at a path the app actually serves:

```yaml
readinessProbe:
  httpGet:
    path: /            # was /healthz
    port: http
```

If the dependency genuinely is down, fix the dependency — do not relax the probe
to make the symptom disappear. That just sends traffic to pods that cannot
serve it.

## Prevention

- Use **named ports** (`port: http`) so probe and container can't drift apart
- Keep health paths in one place — a Helm value, not repeated per manifest
- Verify after deploy: `kubectl get endpointslice` should be non-empty
- Alert on a Service having **zero ready endpoints**. That single alert catches
  this entire class of failure, and it stays silent during normal rollouts

## Why this one is dangerous

It is completely silent. Nothing crashes, nothing restarts, `kubectl logs` is
clean, and `kubectl get pods` says `Running`. A deploy pipeline that only checks
"did the pods start?" reports success while the service is entirely down.

Contrast with liveness: had the *liveness* probe pointed at the same bad path,
the pods would restart-loop — loud, obvious, and found in seconds.
