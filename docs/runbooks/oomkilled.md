# Runbook — Pod OOMKilled

## Symptom

Pod restarts repeatedly. `STATUS` shows `OOMKilled` or `CrashLoopBackOff`, and the
restart count climbs. Application logs end mid-operation with no error and no
shutdown message.

```
NAME                       READY   STATUS      RESTARTS      AGE
api-oom-5f97955878-5plhk   0/1     OOMKilled   3 (35s ago)   66s
```

## Diagnosis

The logs will not tell you. The process is SIGKILLed by the kernel and gets no
chance to write anything. The evidence lives in one place:

```bash
kubectl describe pod <pod> -n <ns>
```

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

Or directly:

```bash
kubectl get pod <pod> -n <ns> \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'
```

`137` = 128 + 9 (SIGKILL). Seeing 137 anywhere means "killed by the kernel",
and in Kubernetes that is almost always memory.

Then compare the limit against what it was actually using:

```bash
kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.containers[0].resources}'
kubectl top pod <pod> -n <ns>          # needs metrics-server
```

## Cause

The container's working set exceeded `resources.limits.memory`. The kernel's
cgroup OOM killer terminated it immediately — no grace period, no SIGTERM.

**Do not assume the limit is simply too low.** Modern runtimes (.NET, JVM, Go,
Node) read the cgroup limit and size their heaps to fit, so a small-but-adequate
limit is usually survivable. A real OOMKill therefore usually means either:

- a genuine memory leak, or
- a legitimate spike the limit never accounted for (large file upload, big query
  result, an unbounded in-memory cache)

## Fix

**Immediate** — raise the limit to restore service:

```yaml
resources:
  limits:
    memory: 512Mi      # was 256Mi
```

**Then find out why.** Raising the limit on a leak only changes how long it takes
to die. Look for: unbounded caches or collections, whole files read into memory,
queries without `LIMIT`, connection pools sized per-request.

## Prevention

- Set `requests` from observed usage, `limits` at peak plus headroom — do not
  guess twice
- Stream large payloads instead of buffering them (relevant here: document
  upload is the obvious future cause)
- Alert on **container_memory_working_set_bytes / limit > 80%** so you find out
  before the kill, not after
- For anything that must not be evicted, set `requests == limits` for **both**
  cpu and memory to get QoS `Guaranteed`

## Notes from causing it deliberately

Three attempts failed before one worked, and each failure taught something:

| Attempt | Result | Lesson |
|---|---|---|
| .NET app, 20Mi limit | survived | .NET sizes its GC heap to the cgroup limit |
| 64Mi limit | died in container *init* | runc says "memory limit too low?" — an obvious message you will rarely see in production |
| `dd` into `/dev/shm` | never OOMed | `/dev/shm` defaults to **64Mi** regardless of the memory limit; `2>/dev/null` hid the "no space left" error |
| `tail /dev/zero` | **OOMKilled** | allocates in the process heap, which counts directly |

Also: QoS was `Burstable` despite memory requests == limits, because **cpu**
differed. Guaranteed requires every resource to match.
