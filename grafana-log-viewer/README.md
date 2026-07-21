# grafana-log-viewer

Cluster-wide log viewing stack for minikube: **Promtail** (DaemonSet) tails
container logs from every pod on every node, ships them to **Loki**
(log storage/index), which **Grafana** queries and visualizes. This chart is
a thin wrapper around the upstream `grafana/loki-stack` chart with values
tuned for a local practice cluster.

## Where this is installed

- **Cluster:** `minikube` profile
- **Namespace:** `log-viewer` (dedicated — kept out of `default` so it can be
  audited/removed as one unit; see
  [`docs/cluster-inventory-and-cleanup.md`](../docs/cluster-inventory-and-cleanup.md)
  for why that matters on this cluster)
- **Release name:** `log-viewer`
- **Method:** local chart wrapping `grafana/loki-stack` (Helm), not raw manifests/kustomize

## Values files

Two settings profiles, kept as separate files rather than one file you edit back and forth:

| File | CPU requests/limits | Use when |
|---|---|---|
| `values.yaml` (default, always loaded) | None — memory-bounded only | This repo's `minikube` profile, or any cluster with little/no free CPU. Default because it's what actually schedules here — see [`docs/incidents.md`](../docs/incidents.md#2026-07-21-grafana-log-viewer-stuck-pending-insufficient-cpu) for what happened when CPU limits were set on this cluster. |
| `values-with-cpu-limits.yaml` (opt-in overlay) | Explicit `requests`/`limits` for loki/promtail/grafana | A cluster with real CPU headroom, where you want the usual scheduling guarantees instead of "whatever's free." |

Layer the overlay on top with `-f` — **don't** edit `values.yaml` to add `limits.cpu` without
also adding `requests.cpu`: a limits-only container gets its request silently defaulted to the
limit by the API server (see [`resource-management.md`](../docs/resource-management.md)), which
is exactly the mistake `values-with-cpu-limits.yaml` avoids by setting both explicitly.

```bash
# memory-only (default, no flag needed):
helm install log-viewer . -n log-viewer --create-namespace

# CPU-bounded, on a cluster that can afford it:
helm install log-viewer . -n log-viewer --create-namespace \
  -f values.yaml -f values-with-cpu-limits.yaml
```

## Install

Run from inside this directory (`grafana-log-viewer/`) — chart path is `.`:

```bash
helm dependency update .
helm install log-viewer . \
  --namespace log-viewer \
  --create-namespace
```

Running from the repo root instead? Point at the directory by name: `helm install log-viewer
grafana-log-viewer ...`. `helm` always needs a literal filesystem path (`.`, `./grafana-log-viewer`,
`../grafana-log-viewer`) or a `repo/chart` reference for a chart added via `helm repo add` — a
bare directory name only resolves if it's actually a subdirectory of your current location,
which is why `helm dependency update grafana-log-viewer` fails with `no such file or directory`
when run from inside `grafana-log-viewer/` itself.

`--create-namespace` makes the install idempotent-safe on a fresh cluster (no separate
`kubectl create namespace` step) but is only applied on `install`, not `upgrade` — the
namespace must already exist by the time you run `helm upgrade`.

## Upgrade

After editing `values.yaml` (or bumping the `loki-stack` dependency version in `Chart.yaml`):

```bash
helm dependency update .   # only needed if Chart.yaml's dependency changed
helm upgrade log-viewer . \
  --namespace log-viewer
```

`helm upgrade --install` combines both — safe to use as the one command for "make it match
what's on disk, whether or not it's already installed":

```bash
helm upgrade --install log-viewer . \
  --namespace log-viewer \
  --create-namespace
```

Check what actually changed before/after:

```bash
helm diff upgrade log-viewer . -n log-viewer                     # if the helm-diff plugin is installed
helm history log-viewer -n log-viewer                            # revision list after the fact
helm get values log-viewer -n log-viewer -a                      # full computed values, current release
```

## Access Grafana

```bash
kubectl get pods -n log-viewer -l app.kubernetes.io/name=grafana
kubectl port-forward -n log-viewer svc/log-viewer-grafana 3000:80
```

Open http://localhost:3000 and log in with:

- user: `admin`
- password: `admin` (set via `values.yaml`, change before using anywhere beyond local practice)

The Loki datasource is auto-provisioned (`grafana.sidecar.datasources.enabled: true`),
so logs are queryable immediately.

## View logs

In Grafana, go to **Explore**, pick the **Loki** datasource, and query by
namespace/pod/container label, e.g.:

```
{namespace="default", app="nginx"}
```

To watch logs from the `sample-nginx` deployment from this repo:

```
{app="nginx"}
```

## Uninstall

```bash
helm uninstall log-viewer -n log-viewer
kubectl delete namespace log-viewer   # helm uninstall does not remove a --create-namespace'd namespace
```
