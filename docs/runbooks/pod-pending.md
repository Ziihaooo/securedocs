# Runbook — Pod stuck in Pending

## Symptom

Pod is created but never runs. No container, no restarts, no logs — and it stays
that way indefinitely. Kubernetes will hold an unschedulable pod forever.

```
NAME                READY   STATUS    RESTARTS   AGE   NODE
api-pending-xxxxx   0/1     Pending   0          10m   <none>
                                                       ^^^^^^
```

`NODE: <none>` is the signature: no node was ever selected. Nothing failed —
nothing was attempted.

## Diagnosis

`kubectl logs` is useless here. There is no container.

```bash
kubectl describe pod <pod> -n <ns>
```

The scheduler explains itself in the Events block, and it is unusually specific:

```
0/3 nodes are available:
  1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane},
  2 Insufficient cpu.
```

Read it as a tally — how many nodes were rejected, and for which reason. Multiple
reasons at once is normal.

```bash
kubectl get events -n <ns> --field-selector reason=FailedScheduling
```

## Message → cause

| Scheduler says | Cause | Fix |
|---|---|---|
| `Insufficient cpu` / `Insufficient memory` | request exceeds any node's free capacity | lower the request, or add/enlarge nodes |
| `had untolerated taint` | node is fenced off | add a matching `toleration`, or target a different node |
| `didn't match Pod's node affinity/selector` | `nodeSelector` matches no node | fix the selector, or label a node |
| `pod has unbound immediate PersistentVolumeClaims` | PVC cannot bind | check the StorageClass exists and can provision |
| `had volume node affinity conflict` | volume is in a different AZ to the node | schedule into the volume's AZ |
| `Too many pods` | node hit its pod limit (110 default; lower on small EC2) | more nodes |

## Checking capacity properly

```bash
kubectl describe node <node> | grep -A6 -E "^Capacity:|^Allocatable:|^Allocated resources:"
```

```
Capacity:      cpu: 22        the hardware
Allocatable:   cpu: 22        capacity minus kubelet reservations
Allocated:     cpu: 100m (0%) already claimed by scheduled pods
```

The scheduler's test is `Allocatable − Allocated ≥ request`.

**A pod must fit on ONE node.** Three nodes with 22 CPU each is not 66 CPU
available to a single pod.

**A node can be 99% idle and still reject you** — if the pod is simply bigger
than the machine.

## Common real cause

Unit confusion:

```yaml
cpu: "64"     # 64 whole cores
cpu: "64m"    # 0.064 of a core
```

A factor of 1000. `64` instead of `64m` is one of the most frequent causes of a
mysteriously unschedulable pod.

## Prevention

- Set requests from measured usage, not guesses
- Cluster autoscaler / Karpenter so capacity shortfalls resolve themselves
- Alert on any pod `Pending` for more than ~5 minutes. It never self-resolves
  without either a change or new capacity
- `ResourceQuota` per namespace so one team can't book the whole cluster

## Note on taints

The control-plane node is tainted by default:

```
node-role.kubernetes.io/control-plane:NoSchedule
```

It runs etcd, the API server and the scheduler — an app pod starving it would
take out the cluster, not just the app. Only pods with an explicit toleration go
there. `ingress-nginx` in this project has one, because it must run on the node
whose port 80 is mapped to the host.

```
taint       node repels pods
toleration  pod is exempt

NoSchedule        no new pods
PreferNoSchedule  avoid if possible
NoExecute         no new pods AND evict existing ones (used by node drain)
```
