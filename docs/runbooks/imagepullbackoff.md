# Runbook — ImagePullBackOff / ErrImagePull

## Symptom

Pod never starts. STATUS cycles `ErrImagePull` → `ImagePullBackOff`.

```
NAME                          READY   STATUS             RESTARTS   AGE
api-badimage-7d9b5fc-h8vlp    0/1     ImagePullBackOff   0          30s
```

Both names, one cause: `ErrImagePull` is the first failure, `ImagePullBackOff`
is Kubernetes retrying with exponential backoff.

## Diagnosis

**`kubectl logs` returns nothing — and cannot.** No container was created, so
nothing has logged. *No logs at all* is itself the signal: the failure happened
before the application existed.

The answer is always in Events:

```bash
kubectl describe pod <pod> -n <ns>
```

```
Failed to pull image "securedocs-api:v99":
  failed to resolve reference "docker.io/library/securedocs-api:v99":
  pull access denied, repository does not exist or may require authorization
```

## Cause

Read the **fully-qualified name** in the error, not the one in your manifest.
An unqualified image expands to Docker Hub:

```
securedocs-api:v99   →   docker.io/library/securedocs-api:v99
```

Which is rarely what you meant on EKS/AKS.

Five causes, in rough order of frequency:

| Cause | Tell |
|---|---|
| Tag doesn't exist — typo, or CI built a different one | tag differs from what the pipeline pushed |
| Missing registry prefix | error shows `docker.io/library/...` unexpectedly |
| Private registry, no credentials | same message; you know the repo exists |
| Wrong architecture (arm64 image on amd64 node) | `no matching manifest for linux/amd64` |
| Rate limited by Docker Hub | `toomanyrequests` |

**The message cannot distinguish "doesn't exist" from "no permission"** —
registries deliberately conflate them so private repo names can't be enumerated.
You have to know which registry you're addressing.

## Fix

**Wrong tag** — correct it, and verify the tag really exists:

```bash
# what tags exist in ECR
aws ecr describe-images --repository-name securedocs-api \
  --query 'imageDetails[].imageTags' --output text

# locally (kind)
docker exec <node> crictl images | grep securedocs
```

**Private registry** — create and reference a pull secret:

```bash
kubectl create secret docker-registry regcred \
  --docker-server=<registry> --docker-username=<user> --docker-password=<pw>
```

```yaml
spec:
  imagePullSecrets:
    - name: regcred
```

On EKS the better answer is no secret at all: give the **node role** ECR read
permission and pulls authenticate automatically.

**kind (local)** — the image only exists in your laptop's Docker until you
side-load it:

```bash
kind load docker-image securedocs-api:dev --name securedocs
```

## Prevention

- Never `:latest`. It hides which build ran and makes rollback meaningless
- Have CI write the tag it just pushed, rather than a human typing it
- Pin production images by **digest** (`@sha256:...`) — a digest cannot be
  wrong or moved
- Always use fully-qualified names outside local dev
- Alert on pods `Pending`/`ImagePullBackOff` for more than ~2 minutes

## Why this one is easy

It fails loudly, immediately, before anything serves traffic, and the error
names the exact image. Compare the readiness-probe failure, which is silent and
lets a broken deploy report success.

Loud failures are good failures.
