# Pod triage — the sequence

Run these in order for **any** pod problem. Stop when you have the answer.

```bash
# 1. What state is it in?
kubectl get pods -n <ns>

# 2. Why? (Events at the bottom, Last State near the middle)
kubectl describe pod <pod> -n <ns>

# 3. What did the app itself say?
kubectl logs <pod> -n <ns>
kubectl logs <pod> -n <ns> --previous     # the DEAD container, after a restart

# 4. Anything cluster-level?
kubectl get events -n <ns> --sort-by=.lastTimestamp | tail -20

# 5. Only for "it runs but no traffic":
kubectl get endpoints <svc> -n <ns>       # empty = Service routes to nothing
```

Step 2 answers most incidents. `describe` is the one to reach for by reflex —
the **Events** block at the bottom is where Kubernetes explains itself.

---

## Reading the columns

```
NAME       READY   STATUS             RESTARTS
web-abc    0/1     Running            0
           ^^^     ^^^^^^^
           can it  is the process
           serve?  alive?
```

Those are **different questions**. `Running` + `0/1` means alive but not serving,
and that combination is the quietest failure in Kubernetes.

---

## Symptom → cause

| STATUS / READY | Means | Go to |
|---|---|---|
| `Running` **1/1** | healthy | — |
| `Running` **0/1** | alive, failing readiness | step 5, then `--field-selector reason=Unhealthy` |
| `CrashLoopBackOff` | starts, exits, repeat | step 3 with `--previous` |
| `OOMKilled` / exit 137 | exceeded memory limit | [oomkilled.md](oomkilled.md) |
| `ImagePullBackOff` / `ErrImagePull` | can't fetch the image | step 2, Events |
| `Pending` | nothing will schedule it | step 2, Events — usually resources or taints |
| `Init:0/1` | initContainer hasn't finished | `logs <pod> -c <initContainer>` |
| `ContainerCreating` (stuck) | volume or Secret missing | step 2, Events |
| `Terminating` (stuck) | finalizer, or a slow graceful shutdown | `describe`, check finalizers |

---

## The three commands that answer "why" most often

```bash
# every event in the namespace, newest last
kubectl get events -n <ns> --sort-by=.lastTimestamp

# only probe failures
kubectl get events -n <ns> --field-selector reason=Unhealthy

# how a container died last time (reason + exit code)
kubectl get pod <pod> -n <ns> \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'
```

## Exit codes worth recognising

```
0     clean exit
1     application error — check the logs
137   SIGKILL   -> almost always OOMKilled
143   SIGTERM   -> shut down normally (a deploy, a scale-down)
```

## Testing connectivity from inside the cluster

`curl` from your laptop only tests the ingress path. To test a Service directly:

```bash
kubectl run curltest -n <ns> --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sv -m 5 http://<svc>/
```

Use **`-sv`**, not `-s`. With `-s` alone a failed connection prints nothing at
all and the pod just exits — which tells you nothing. `-v` shows the connection
attempt and the error.

## Runbooks

- [OOMKilled](oomkilled.md)
- [Readiness probe failing](readiness-probe-failing.md)
