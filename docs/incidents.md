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

### First resolution — walk away

Given the choice between (a) fixing the chart to be truly CPU-request-free and reinstalling,
or (b) deleting and recreating the whole cluster for more headroom, or (c) walking away from
the log viewer for now — chose **(c)**: `helm uninstall log-viewer`. The chart itself
(`grafana-log-viewer/`) was left untouched in the repo, installable later.

### Revisited — a real fix, as two values files

Reinstalled later, this time actually applying (a). Rather than edit `values.yaml` in place
again, split it into two files so the CPU-bound/CPU-free choice is explicit and reusable
instead of something to remember to redo by hand:

- `grafana-log-viewer/values.yaml` (default) — memory-only bounds, `cpu` absent from both
  `requests` and `limits` on loki/promtail/grafana. This is what schedules on `minikube`.
- `grafana-log-viewer/values-with-cpu-limits.yaml` (opt-in overlay, `-f` on top of the
  default) — explicit `requests`+`limits` CPU, for a cluster with real headroom. Sets *both*,
  not just `limits`, specifically to avoid repeating root cause #2.

`helm upgrade log-viewer .` onto the still-installed (still-`Pending`) release — pods didn't
come up immediately; two more, unrelated issues surfaced:

### New issue — Loki `StatefulSet` stuck on its old `ControllerRevision`

After the upgrade, `log-viewer-grafana` and `log-viewer-promtail` (both Deployment/DaemonSet)
scheduled and went `Running` right away. `log-viewer-loki-0` stayed `Pending` with the same
`Insufficient cpu` error as before — even though the StatefulSet's pod *template* now had no
`cpu` at all:

```
$ kubectl get statefulset log-viewer-loki -o jsonpath='{.spec.template.spec.containers[0].resources}'
{"limits":{"memory":"256Mi"},"requests":{"memory":"128Mi"}}          # template: fixed

$ kubectl get pod log-viewer-loki-0 -o jsonpath='{.spec.containers[0].resources}'
{"limits":{"cpu":"200m","memory":"256Mi"},"requests":{"cpu":"200m","memory":"128Mi"}}  # pod: still old
```

The pod's `controller-revision-hash` label confirmed it: still pinned to the pre-upgrade
`ControllerRevision`, while `.status.updateRevision` on the StatefulSet already pointed at the
new one. `kubectl delete pod log-viewer-loki-0` (the usual "force a respin" move) didn't help
either — the replacement pod came back on the **same old revision**. Root cause: a `Pending`
pod that never became `Ready` appears to leave the `RollingUpdate` controller's per-ordinal
update logic wedged — normal for `StatefulSet`s is to roll pods automatically without any
manual delete needed, and deleting one that's actually `Running` does pick up the latest
revision; a pod that's been stuck `Pending` since before the update apparently doesn't count
as "updated" through either path. Fix: force a full teardown/recreate instead of a same-pod
delete —

```bash
kubectl scale statefulset log-viewer-loki -n log-viewer --replicas=0
kubectl scale statefulset log-viewer-loki -n log-viewer --replicas=1
```

— which came back on the current revision (`log-viewer-loki-57b458f57`), memory-only
resources, and got scheduled immediately.

### New issue — Loki `503` on its readiness probe right after starting

Scheduled and `Running`, but `0/1 Ready` for several minutes, readiness/liveness probes
returning `503`. Logs showed Loki's single-replica gossip ring (`memberlist`) failing to find
itself healthy:

```
Failed to resolve log-viewer-loki-memberlist: lookup log-viewer-loki-memberlist on 10.96.0.10:53: no such host
...
error asking ring for who should run the compactor ... unhealthy instances: 10.244.0.129:9095
auto-forgetting instance from the ring because it is unhealthy for a long time
```

A cold-start timing issue, not a config problem: Loki tries to resolve its own headless
`memberlist` Service before that Service's DNS record/endpoint is fully populated, marks
itself unhealthy in its own gossip ring as a result, then self-corrects once DNS catches up
and it successfully rejoins. No intervention needed — it flipped to `1/1 Running` on its own
a few minutes later. Worth knowing as "give it a few minutes before treating a fresh Loki pod's
`503`s as a real problem," not chasing config changes for it.

All three pods `Running`/`Ready`:

```
$ kubectl get pods -n log-viewer
log-viewer-grafana-6655bb9fdf-4sdsr   2/2   Running
log-viewer-loki-0                     1/1   Running
log-viewer-promtail-kg849             1/1   Running
```

Access, and login `admin`/`admin` (from `values.yaml`'s `grafana.adminPassword`):

```bash
kubectl port-forward -n log-viewer svc/log-viewer-grafana 3000:80
```

Healthy pods, but Grafana's **Explore** → Loki showed **no log results for any query** —
one more issue, below.

### New issue — every pod healthy, but zero logs actually reach Loki

`{app="nginx"}`, `{namespace="kube-system"}`, anything — Explore returned nothing, for any
label, any time range. Checking Loki directly (not through Grafana, to rule out a Grafana-side
problem) confirmed Loki itself had never received a single log line:

```
$ kubectl exec -n log-viewer log-viewer-loki-0 -- wget -qO- 'http://localhost:3100/loki/api/v1/label'
{"status":"success"}          # no "data" key at all — zero labels, zero streams, ever
```

So the problem was upstream of Loki — Promtail. Its own logs told the story immediately:

```
$ kubectl logs -n log-viewer -l app.kubernetes.io/name=promtail
level=warn ... msg="error sending batch, will retry" status=-1 tenant=
  error="Post \"http://log-viewer:3100/loki/api/v1/push\": dial tcp: lookup log-viewer on 10.96.0.10:53: no such host"
```

Promtail had been trying to push to a Service called `log-viewer` since the moment it started
— which doesn't exist:

```
$ kubectl get svc -n log-viewer
log-viewer-grafana           NodePort
log-viewer-loki              ClusterIP   3100/TCP   # <- the real one
log-viewer-loki-headless     ClusterIP
log-viewer-loki-memberlist   ClusterIP
```

### Root cause #3 — `loki-stack`'s default Promtail URL assumes the release is named `loki`

Decoding Promtail's actual rendered config confirmed the exact broken value:

```
$ kubectl get secret -n log-viewer log-viewer-promtail -o jsonpath='{.data.promtail\.yaml}' | base64 -d
clients:
  - url: http://log-viewer:3100/loki/api/v1/push
```

`grafana/loki-stack`'s chart default for this field is the Go template string
`http://{{ .Release.Name }}:3100/loki/api/v1/push` — it assumes the Loki **Service** name
equals the **release** name. That's only true if you name the release `loki`; the chart
actually creates the Service as `<release>-loki`. This repo's [`grafana-log-viewer/`](../grafana-log-viewer)
install docs deliberately name the release `log-viewer` (so it reads clearly, matching the
namespace) — which is exactly the case this default breaks.
Every log line Promtail ever tailed was tried, failed to send, and retried into the void from
the moment of the very first install, hours before this was noticed — the CPU-scheduling saga
above meant nobody looked at whether logs were actually arriving until pods were finally
healthy enough to check.

Fixed by pinning the URL explicitly in `grafana-log-viewer/values.yaml`:

```yaml
promtail:
  config:
    clients:
      - url: http://log-viewer-loki:3100/loki/api/v1/push
```

`helm upgrade` picked it up immediately — the chart annotates Promtail's pod template with a
checksum of its config Secret, so the `DaemonSet` restarted its pod on its own, no manual
`kubectl delete pod` needed this time (unlike the `StatefulSet` issue above).

### Verifying it, with a real application

Deployed [`sample-nginx`](../sample-nginx) (already in this repo, `app: nginx` label) purely
to have something with its own log stream to check end-to-end, rather than trusting platform
noise:

```bash
kubectl apply -f sample-nginx/nginx-deployment.yaml
```

Queried Loki directly (bypassing Grafana, same principle as before — confirm the data layer
before trusting the UI):

```
$ kubectl exec -n log-viewer log-viewer-loki-0 -- wget -qO- \
    'http://localhost:3100/loki/api/v1/query_range?query=%7Bapp%3D%22nginx%22%7D&limit=10'
{"status":"success","data":{"resultType":"streams","result":[{"stream":{"app":"nginx", ...},
  "values":[["...", "{\"log\":\"2026/07/21 06:36:13 [notice] 1#1: nginx/1.31.3\\n\", ...}"], ...
```

Real nginx startup logs, labeled and queryable. The same `{app="nginx"}` query works in
Grafana's Explore.

### New issue — "still don't see anything" turned out to be the Dashboards page, not Explore

Even with logs confirmed flowing, nothing showed up in Grafana — because the page being
checked was Grafana's **Dashboards** list, which this chart never populated (no dashboard was
provisioned, only the Loki datasource). Logs are visible under **Explore**, a separate page,
not on a dashboard by default. Since a saved dashboard is genuinely more convenient than
re-running an Explore query every visit, added one: `grafana.sidecar.dashboards.enabled: true`
plus `templates/dashboard-nginx-logs.yaml` — a `ConfigMap` labeled `grafana_dashboard: "1"`
containing a dashboard JSON model with a single Logs panel pinned to `{app="nginx"}`. Grafana's
sidecar container watches the namespace for that label and auto-loads any match, so the
dashboard reappears automatically on every future install/upgrade — confirmed present via
`GET /api/search`, no manual "import dashboard" step.

### Final resolution

- Pods healthy (see above)
- Promtail actually shipping logs, Loki actually storing them, confirmed via direct API query
  before trusting the Grafana UI
- `sample-nginx` deployed as a live, known-good log source to validate against; its logs are
  visible via `{app="nginx"}` in Grafana Explore right now
- A dashboard (**App Logs (sample-nginx)**) auto-provisioned so viewing those logs doesn't
  require re-running an Explore query each time

### Lessons

- `kubectl describe node <name>` → `Allocated resources` is the first thing to check on any
  `Insufficient cpu`/`Insufficient memory` scheduling failure — it tells you whether there's
  headroom at all before looking at the new workload's own numbers.
- A `limits.cpu` with no `requests.cpu` is not "unbounded below" — it's a request pinned to
  the limit. To actually leave CPU unrequested, omit it from both. If you want CPU bounds at
  all, set requests and limits explicitly rather than relying on the default — that's why
  `values-with-cpu-limits.yaml` sets both.
- Local VM-based clusters (minikube, and similarly `kind`/Docker Desktop node containers) have
  their own resource ceiling, independent of the host. Free host capacity is not evidence a
  pod should be schedulable.
- VM-level sizing (CPU/memory given to the node at creation) is generally not resizable
  in place — changing it means destroying and recreating the node, which is a different
  (and far more disruptive) class of change than anything expressible via `kubectl`/`helm`.
  Worth checking whether that trade is acceptable *before* attempting it, not after.
- A `helm upgrade` that changes a `StatefulSet`'s pod template doesn't guarantee the pods
  actually update, if one has been stuck `Pending` since before the change — `kubectl delete
  pod` on it isn't sufficient either. `scale --replicas=0` then back up forces a real
  recreate onto the current revision when that happens.
- A single-replica Loki (or anything using `memberlist` gossip) can throw real-looking `503`s
  and "unhealthy instance" log lines for the first few minutes after starting, purely from
  DNS/ring self-discovery timing — worth waiting before debugging it as a config issue.
- "All pods `Running`/`Ready`" is not the same claim as "the pipeline works." Nothing about
  Promtail's `Running` status reflected that it had been failing to push every single batch
  since install — its container was healthy the whole time, only its outbound requests were
  failing. Check the data actually arrived (`loki/api/v1/label` returning real labels, not an
  empty `{"status":"success"}`) before trusting pod status as "it's working."
- A chart default that interpolates `{{ .Release.Name }}` into another resource's expected
  name (here, assuming the Loki Service is named after the release) is a landmine for anyone
  who doesn't happen to pick that exact release name. Worth grepping a new chart's default
  `values.yaml` for `{{ .Release.Name }}` outside of label/annotation contexts before trusting
  its cross-component defaults, especially wherever a release name choice feels arbitrary.
