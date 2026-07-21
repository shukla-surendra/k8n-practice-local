# Incident log

Real problems hit while working in this repo's clusters, kept as a record of what actually
happened rather than the cleaned-up theory. Each entry: symptom, investigation, root cause,
resolution.

## 2026-07-21 — `grafana-log-viewer` stuck `Pending`: "Insufficient cpu"

### Symptom

Installed the [`grafana-log-viewer`](../grafana-log-viewer) chart (Loki + Promtail + Grafana)
onto the `minikube` cluster. All three pods sat in `Pending` indefinitely:

```
$ kubectl get pods
log-viewer-grafana-...    0/2   Pending
log-viewer-loki-0         0/1   Pending
log-viewer-promtail-...   0/1   Pending

$ kubectl describe pod log-viewer-loki-0
Warning  FailedScheduling  default-scheduler
  0/1 nodes are available: 1 Insufficient cpu. no new claims to deallocate,
  preemption: 0/1 nodes are available: 1 No preemption victims found for incoming pod.
```

### Investigation

`kubectl describe node minikube` showed CPU requests already at **2 (100%)** — fully
committed before the new chart was even installed:

```
Allocated resources:
  Resource  Requests      Limits
  cpu       2 (100%)      11700m (585%)
  memory    3770Mi (64%)  7014Mi (119%)
```

Breaking down what was actually holding that 2 CPU: not app workloads, but the platform
stack already resident on this cluster — `kube-system` control plane pods (~650m: etcd,
apiserver, scheduler, controller-manager, coredns, kube-proxy), Istio (~700m: istiod,
ingressgateway, cluster-local-gateway), Knative webhooks (~120m), and Kubeflow controllers
(~200m). None of it was the new chart — the node simply had **zero CPU headroom** for
anything new, full stop.

### Root cause #1 — the node's CPU budget is much smaller than the host's

`minikube` doesn't run Kubernetes on the Mac directly — it provisions a `vfkit` VM and gives
it a **fixed CPU allocation at creation time**. That allocation, not the host's core count, is
what `kube-scheduler` sees as `allocatable`:

```
$ sysctl -n hw.ncpu                                    # host: 12 cores, mostly idle
12
$ kubectl get node minikube -o jsonpath='{.status.allocatable.cpu}'   # VM: 2
2
```

"Insufficient cpu" was never about the Mac running out of anything — it was a 2-CPU ceiling
the VM was given once, at `minikube start` time, months ago, that the scheduler now treats as
a hard wall, same as it would on any 2-vCPU cloud instance.

### First fix attempt — remove `cpu` from `requests` — didn't work

Edited `grafana-log-viewer/values.yaml` to drop the `requests.cpu` line for loki/promtail/
grafana, keeping `limits.cpu`, and ran `helm upgrade`. Pods stayed `Pending` with the exact
same error. Comparing the Deployment's pod template against the actual running Pod's spec
showed why:

```
$ kubectl get deployment log-viewer-grafana \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="grafana")].resources}'
{"limits":{"cpu":"200m","memory":"256Mi"},"requests":{"memory":"128Mi"}}   # no cpu request — as edited

$ kubectl get pod log-viewer-grafana-... \
    -o jsonpath='{.spec.containers[?(@.name=="grafana")].resources}'
{"limits":{"cpu":"200m","memory":"256Mi"},"requests":{"cpu":"200m","memory":"128Mi"}}  # cpu request = 200m anyway
```

### Root cause #2 — Kubernetes defaults an unset request to the limit

When a container specifies `limits.cpu` but omits `requests.cpu`, the API server does **not**
leave the request unset — it defaults `requests.cpu` to equal `limits.cpu`. Removing only the
`requests` line while leaving `limits: {cpu: 200m}` in place changed nothing: the effective
request was still 200m. (See [`resource-management.md`](./resource-management.md) for the
general requests/limits model — this defaulting behavior is the sharp edge that model doesn't
call out.) To genuinely get a CPU-request-free container, `cpu` has to be absent from **both**
`requests` and `limits`.

### Second attempt — resize the VM instead

Tried giving `minikube` more of the host's 12 cores rather than fight the chart's resource
shape:

```
$ minikube stop
$ minikube start --cpus=6
! You cannot change the CPUs for an existing minikube cluster. Please first delete the cluster.
```

`vfkit` VM sizing is fixed at creation and can't be changed in place — only
`minikube delete -p minikube && minikube start --cpus=6` actually applies a new CPU count,
and `delete` wipes the VM's disk, i.e. the entire cluster's etcd state. On this profile that
meant the ~205-day-old Kubeflow/Istio/Knative/KServe install, not just the stuck chart.

### Resolution

Given the choice between (a) fixing the chart to be truly CPU-request-free and reinstalling,
or (b) deleting and recreating the whole cluster for more headroom, or (c) walking away from
the log viewer for now — chose **(c)**: `helm uninstall log-viewer`. The chart itself
(`grafana-log-viewer/`) is untouched in the repo and installable later, either after trimming
its `limits.cpu` too, or after a deliberate, planned cluster recreation with more CPUs (not an
in-place resize, since one isn't possible).

### Lessons

- `kubectl describe node <name>` → `Allocated resources` is the first thing to check on any
  `Insufficient cpu`/`Insufficient memory` scheduling failure — it tells you whether there's
  headroom at all before looking at the new workload's own numbers.
- A `limits.cpu` with no `requests.cpu` is not "unbounded below" — it's a request pinned to
  the limit. To actually leave CPU unrequested, omit it from both.
- Local VM-based clusters (minikube, and similarly `kind`/Docker Desktop node containers) have
  their own resource ceiling, independent of the host. Free host capacity is not evidence a
  pod should be schedulable.
- VM-level sizing (CPU/memory given to the node at creation) is generally not resizable
  in place — changing it means destroying and recreating the node, which is a different
  (and far more disruptive) class of change than anything expressible via `kubectl`/`helm`.
  Worth checking whether that trade is acceptable *before* attempting it, not after.
