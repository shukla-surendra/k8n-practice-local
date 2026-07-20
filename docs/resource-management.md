# Resource management: requests/limits, LimitRange, ResourceQuota, HPA, PDB

Five related-but-distinct mechanisms, all grounded in `full-stack-app`'s templates.

## Requests and limits (per container)

```yaml
# full-stack-app/charts/backend — spec.containers[].resources
resources:
  requests:
    cpu: 25m
    memory: 32Mi
  limits:
    cpu: 100m
    memory: 64Mi
```

- **`requests`** is what the scheduler uses to place the Pod — it only schedules onto a Node
  that has at least this much *unreserved* capacity. It's also what "how much of the node is
  this Pod using" accounting is based on.
- **`limits`** is the hard ceiling enforced by the kernel/runtime at runtime: CPU gets throttled
  past its limit (the process keeps running, just slower); memory past its limit gets the
  container **OOMKilled** (`kubectl describe pod` shows `Reason: OOMKilled` — a hard kill, not a
  graceful one).
- No `requests`/`limits` at all means "unbounded" — the Pod can be scheduled anywhere and use as
  much as the node has free, which is how one runaway Pod starves its neighbors. This is
  precisely the gap `LimitRange` closes.

## LimitRange — namespace-wide defaults

```yaml
# full-stack-app/templates/limitrange.yaml
spec:
  limits:
    - type: Container
      defaultRequest: {cpu: 25m, memory: 32Mi}   # applied if a container sets no request
      default: {cpu: 250m, memory: 256Mi}        # applied if a container sets no limit
      max: {cpu: 1, memory: 512Mi}               # hard ceiling — containers can't request more
      min: {cpu: 10m, memory: 16Mi}              # hard floor
```

A safety net for the namespace, not something well-behaved workloads should rely on — this
repo's own Deployments all set explicit `resources` (see above) and never hit the defaults. It
exists to stop an *unconfigured* container (someone's one-off Pod, a Job someone forgot to set
limits on) from being scheduled with no bound at all.

## ResourceQuota — namespace-wide ceiling

```yaml
# full-stack-app/templates/resourcequota.yaml
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    pods: "20"
```

Where `LimitRange` fills in gaps per-container, `ResourceQuota` caps the **sum** across the
whole namespace — the total of every Pod's requests/limits, and a hard count on the number of
Pods, can't exceed this. Once hit, new Pod creation in that namespace is rejected by the API
server (not silently queued) until something is freed up. On a shared local cluster (or a
shared EKS namespace) this is what stops one team/app from starving everyone else's namespace —
`LimitRange` bounds one container, `ResourceQuota` bounds the whole tenant.

Practical implication: once a `ResourceQuota` exists in a namespace, **every** Pod submitted to
it must have explicit `requests`/`limits` (the API server can't compute usage against the quota
otherwise) — this is usually the actual reason `LimitRange` and `ResourceQuota` are deployed
together, as they are here.

## HorizontalPodAutoscaler — reacting to load

```yaml
# full-stack-app/charts/backend/templates/hpa.yaml
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: ...}
  minReplicas: 2
  maxReplicas: 4
  metrics:
    - type: Resource
      resource: {name: cpu, target: {type: Utilization, averageUtilization: 70}}
```

Polls `metrics-server` (see [`cluster-architecture.md`](./cluster-architecture.md)) for actual
CPU usage against each Pod's **requested** CPU — this is why requests need to be set
realistically: HPA's utilization percentage is relative to `requests.cpu`, not to node capacity
or to `limits.cpu`. Scales the target Deployment's `replicas` up/down between `minReplicas` and
`maxReplicas` to hold roughly the target utilization.

## PodDisruptionBudget — protecting availability during *voluntary* disruption

```yaml
# full-stack-app/charts/backend/templates/pdb.yaml
spec:
  minAvailable: 1
  selector: {matchLabels: {app.kubernetes.io/name: backend, ...}}
```

Constrains **voluntary** disruptions only — node drains (`kubectl drain`), cluster autoscaler
scale-downs, rolling node upgrades. It has no effect on involuntary disruption (a node crashing,
OOMKill, a bad rollout). With `minAvailable: 1`, a `kubectl drain` on a node running one of two
backend replicas will wait/block rather than evict a Pod that would drop availability below 1 —
this is what makes node maintenance on a live EKS cluster safe to automate instead of a manual,
coordinated affair.

## How these interact, end to end

```
ResourceQuota (namespace ceiling)
        |
LimitRange fills in missing per-container requests/limits, still within Quota
        |
Scheduler places Pods using requests, respecting node capacity
        |
HPA watches actual usage vs. requests, adjusts replica count
        |
PDB constrains how many replicas can be voluntarily taken down at once
```

## Quick reference

```bash
kubectl describe limitrange -n <namespace>
kubectl describe resourcequota -n <namespace>
kubectl top pods -n <namespace>                 # needs metrics-server
kubectl get hpa -n <namespace>
kubectl get pdb -n <namespace>
kubectl describe pod <name> | grep -A3 "Limits\|Requests"
```
