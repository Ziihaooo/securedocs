# kubectl — diagnostic commands

`-n <ns>` on everything. `-A` for all namespaces.

## State

```bash
kubectl get pods                                   # basic
kubectl get pods -o wide                           # + node, pod IP
kubectl get pods -A                                # every namespace
kubectl get pods -w                                # watch live
kubectl get pods -l app=api                        # by label
kubectl get pods --sort-by=.metadata.creationTimestamp
kubectl get pods --field-selector status.phase=Pending
kubectl get pods --field-selector status.phase!=Running

kubectl get all                                    # pods, svc, deploy, rs, sts
kubectl get all,ingress,pvc,configmap,secret

# custom columns — pick exactly what you want
kubectl get pods -o custom-columns=\
NAME:.metadata.name,\
STATUS:.status.phase,\
READY:.status.containerStatuses[0].ready,\
RESTARTS:.status.containerStatuses[0].restartCount,\
QOS:.status.qosClass,\
NODE:.spec.nodeName
```

## Why — describe and events

```bash
kubectl describe pod <pod>              # Events block at the BOTTOM
kubectl describe deploy <name>
kubectl describe node <node>            # capacity, allocated, pressure conditions

kubectl get events --sort-by=.lastTimestamp
kubectl get events --sort-by=.lastTimestamp | tail -20
kubectl get events --field-selector reason=Unhealthy      # probe failures
kubectl get events --field-selector reason=Failed
kubectl get events --field-selector reason=FailedScheduling
kubectl get events --field-selector type=Warning
kubectl get events --field-selector involvedObject.name=<pod>
kubectl get events -A --sort-by=.lastTimestamp            # cluster-wide
```

## Logs

```bash
kubectl logs <pod>
kubectl logs <pod> --previous                  # the DEAD container after a restart
kubectl logs <pod> -c <container>              # multi-container pod
kubectl logs <pod> -c <initContainer>          # initContainers too
kubectl logs -f <pod>                          # follow
kubectl logs --tail=50 <pod>
kubectl logs --since=10m <pod>
kubectl logs --timestamps <pod>
kubectl logs -l app=api --all-containers       # every pod matching a label
kubectl logs -l app=api --max-log-requests=10
kubectl logs deploy/api                        # via the workload
kubectl logs job/migrator
```

## Death details

```bash
# how it died last time — reason + exit code
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'

# restart count
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].restartCount}'

# every container's current state
kubectl get pod <pod> -o jsonpath='{range .status.containerStatuses[*]}{.name}{": "}{.state}{"\n"}{end}'
```

**Exit codes:** `0` clean · `1` app error · `137` SIGKILL (usually OOM) · `143` SIGTERM (normal shutdown)

## Get inside

```bash
kubectl exec -it <pod> -- sh
kubectl exec -it <pod> -c <container> -- bash
kubectl exec <pod> -- env                       # what env vars it actually got
kubectl exec <pod> -- cat /etc/resolv.conf
kubectl exec <pod> -- ls -la /path
kubectl exec <pod> -- ps aux

# no shell in the image (distroless/chiseled)? attach a debug container
kubectl debug -it <pod> --image=busybox --target=<container>

# a throwaway pod on the cluster network
kubectl run tmp --rm -it --restart=Never --image=busybox:1.36 -- sh
kubectl run tmp --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sv -m 5 http://<svc>/          # -v, or a failure prints NOTHING
```

## Networking

```bash
kubectl get svc
kubectl get endpoints <svc>                     # EMPTY = routes to nothing
kubectl get endpointslice -l kubernetes.io/service-name=<svc>
kubectl get ingress
kubectl describe ingress <name>
kubectl describe svc <name>

kubectl port-forward svc/<svc> 8080:80          # bypass the ingress
kubectl port-forward pod/<pod> 8080:8080        # bypass the Service too

# DNS check from inside the cluster
kubectl run dns --rm -it --restart=Never --image=busybox:1.36 -- nslookup <svc>
```

Narrowing a connectivity problem: port-forward the **pod** (works? app is fine),
then the **Service** (works? Service is fine), then the ingress.

## Resources and scheduling

```bash
kubectl top nodes                              # needs metrics-server
kubectl top pods
kubectl top pods --containers

kubectl describe node <node>                   # Allocated resources, Conditions
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
CPU:.status.capacity.cpu,\
MEM:.status.capacity.memory

kubectl get pod <pod> -o jsonpath='{.spec.containers[0].resources}'
kubectl get pods -o custom-columns=NAME:.metadata.name,QOS:.status.qosClass

# who is Pending and why
kubectl get pods --field-selector status.phase=Pending
kubectl describe pod <pending-pod> | grep -A5 Events
```

## Workloads

```bash
kubectl rollout status deploy/<name>
kubectl rollout history deploy/<name>
kubectl rollout undo deploy/<name>
kubectl rollout undo deploy/<name> --to-revision=2
kubectl rollout restart deploy/<name>           # same spec, fresh pods

kubectl get rs                                  # ReplicaSets — old + new during a rollout
kubectl get deploy -o wide                      # shows the image
kubectl get sts
kubectl get jobs
kubectl get pvc
```

## Config and secrets

```bash
kubectl get configmap
kubectl get cm <name> -o yaml
kubectl get secret
kubectl get secret <name> -o jsonpath='{.data}'                 # base64
kubectl get secret <name> -o jsonpath='{.data.KEY}' | base64 -d # decoded
kubectl exec <pod> -- env | sort                                # what the pod really sees
```

## The object itself

```bash
kubectl get pod <pod> -o yaml
kubectl get deploy <name> -o yaml
kubectl get deploy <name> -o yaml | grep -A10 resources

kubectl diff -f manifest.yaml                   # what WOULD change, without applying
kubectl apply -f manifest.yaml --dry-run=server # validate against the API server
kubectl explain pod.spec.containers.resources   # built-in field docs
```

## Permissions

```bash
kubectl auth whoami
kubectl auth can-i '*' '*' --all-namespaces
kubectl auth can-i delete pods -n production
kubectl auth can-i --list
```

## Cluster

```bash
kubectl cluster-info
kubectl get nodes
kubectl get nodes -o wide
kubectl get componentstatuses
kubectl api-resources                           # every object type available
kubectl get crd                                 # installed extensions
kubectl config get-contexts                     # which cluster/namespace am I in
kubectl config current-context
kubectl config set-context --current --namespace=<ns>
```

## Helm

```bash
helm list -A
helm lint ./charts/securedocs
helm template x ./charts/securedocs -f values-dev.yaml   # render, don't install
helm get manifest <release>
helm history <release>
helm rollback <release> <revision>
```

## ArgoCD (without the CLI)

```bash
kubectl get application -n argocd
kubectl get application <app> -n argocd -o jsonpath='{.status.sync.status}'
kubectl get application <app> -n argocd -o jsonpath='{.status.operationState.message}'
kubectl get application <app> -n argocd \
  -o jsonpath='{range .status.resources[*]}{.kind}/{.name} {.status}{"\n"}{end}'

# force a refresh (check git now)
kubectl patch application <app> -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# force a sync
kubectl patch application <app> -n argocd --type merge \
  -p '{"operation":{"sync":{"revision":"<branch>"}}}'
```

## Most used, in order

```bash
kubectl get pods
kubectl describe pod <pod>
kubectl logs <pod> --previous
kubectl get events --sort-by=.lastTimestamp
kubectl get endpoints <svc>
kubectl exec -it <pod> -- sh
```
