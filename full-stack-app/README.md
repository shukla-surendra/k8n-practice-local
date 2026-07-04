# full-stack-app — a full-featured Helm chart (multi-tier, local-testable)

A three-tier demo app — **frontend** (nginx) → **backend** (JSON API) →
**database** (postgres) — packaged as a Helm umbrella chart, built to touch
nearly every Kubernetes manifest kind you'll meet in real charts. Everything
here runs on a single-node local cluster (minikube).

## Layout

```
full-stack-app/
├── Chart.yaml                 # umbrella chart metadata
├── values.yaml                 # defaults + cross-cutting toggles
├── values.schema.json          # validates values on install/upgrade/lint
├── templates/                  # cross-cutting, namespace-scoped resources
│   ├── namespace.yaml           # Namespace (optional, see below)
│   ├── ingress.yaml              # Ingress routing / and /api
│   ├── networkpolicy.yaml        # 3x NetworkPolicy (default-deny between tiers)
│   ├── resourcequota.yaml        # ResourceQuota for the whole release
│   ├── limitrange.yaml           # LimitRange (default requests/limits)
│   ├── migration-job.yaml        # Job, run as a post-install/pre-upgrade hook
│   ├── backup-cronjob.yaml       # CronJob (pg_dump on a schedule)
│   ├── tests/test-connection.yaml # Pod, run as a `helm test` hook
│   └── NOTES.txt                 # printed after install/upgrade
└── charts/                     # subcharts — Helm auto-wires "frontend:", "backend:", "database:" values sections to these
    ├── frontend/  Deployment, Service, HPA, PodDisruptionBudget, ServiceAccount, ConfigMap
    ├── backend/   Deployment, Service, HPA, PodDisruptionBudget, ServiceAccount, Role+RoleBinding, ConfigMap, Secret
    └── database/  StatefulSet (+volumeClaimTemplates/PVC), headless Service, ConfigMap, Secret
```

### Manifest kind inventory

| Kind | Where | Purpose |
|---|---|---|
| Namespace | `templates/namespace.yaml` | optional; off by default (see note below) |
| Deployment | frontend, backend | stateless app tiers |
| StatefulSet | database | stable identity + per-pod storage for postgres |
| Service (ClusterIP) | frontend, backend | internal load-balancing |
| Service (headless) | database | stable pod DNS instead of load-balancing |
| Ingress | `templates/ingress.yaml` | routes `/` → frontend, `/api` → backend |
| ConfigMap | all three tiers | static HTML, non-secret env config, DB init SQL |
| Secret | backend, database | API token (random, stable across upgrades), DB password |
| ServiceAccount | all three tiers | identity for RBAC / token mounting control |
| Role + RoleBinding | backend | least-privilege read of ConfigMaps/Secrets |
| HorizontalPodAutoscaler | frontend, backend | CPU-based autoscaling |
| PodDisruptionBudget | frontend, backend | keeps `minAvailable` up during node drains |
| NetworkPolicy | `templates/networkpolicy.yaml` | frontend↔backend↔database default-deny |
| ResourceQuota | `templates/resourcequota.yaml` | caps total CPU/mem/pods for the namespace |
| LimitRange | `templates/limitrange.yaml` | default container requests/limits |
| Job (Helm hook) | `templates/migration-job.yaml` | schema migration, runs on install/upgrade |
| CronJob | `templates/backup-cronjob.yaml` | scheduled `pg_dump` |
| Pod (Helm test hook) | `templates/tests/test-connection.yaml` | `helm test` smoke check |
| PersistentVolumeClaim | via database `volumeClaimTemplates` | postgres data directory |

Deliberately **not** included: cluster-scoped kinds like `StorageClass`,
`PriorityClass`, `ClusterRole`/`ClusterRoleBinding` — those affect the whole
cluster, not just this release, so they're out of scope for something
meant to be installed/uninstalled repeatedly on a shared local cluster.

## Prerequisites

```bash
minikube start --cpus=4 --memory=6g
minikube addons enable ingress          # for the Ingress resource
minikube addons enable metrics-server   # for the HPA to actually see CPU%
```

## Install

```bash
cd full-stack-app
helm lint .
helm template demo . --namespace fullstack   # render only, no cluster calls

helm install demo . \
  --namespace fullstack --create-namespace \
  --wait --timeout 5m
```

`namespace.create` in `values.yaml` is `false` by default because we're
using `--create-namespace` here — turning both on causes Helm to refuse the
install with an ownership-metadata error. Flip it only if you manage the
namespace via `helm install` itself instead of the CLI flag.

## Verify everything came up

```bash
kubectl get all,ingress,configmap,secret,pdb,networkpolicy,resourcequota,limitrange \
  -n fullstack -l app.kubernetes.io/part-of=full-stack-app

helm test demo -n fullstack

kubectl port-forward -n fullstack svc/demo-frontend 8080:80
open http://localhost:8080          # in another terminal
```

Via Ingress instead of port-forward:

```bash
echo "$(minikube ip) fullstack.local" | sudo tee -a /etc/hosts
curl http://fullstack.local/
curl http://fullstack.local/api/
```

## Exercising each feature

**Autoscaling (HPA):**
```bash
kubectl get hpa -n fullstack
kubectl run load --rm -it --image=busybox --restart=Never -n fullstack -- \
  sh -c "while true; do wget -q -O- http://demo-backend:5678/; done"
# in another terminal, watch replicas climb:
kubectl get hpa -n fullstack -w
```

**PodDisruptionBudget:**
```bash
kubectl get pdb -n fullstack
kubectl drain <a-node> --ignore-daemonsets --delete-emptydir-data --dry-run=server
```

**RBAC:** confirm the backend's ServiceAccount really can read ConfigMaps
but nothing cluster-wide:
```bash
kubectl auth can-i get configmaps --as=system:serviceaccount:fullstack:demo-backend -n fullstack   # yes
kubectl auth can-i get pods --as=system:serviceaccount:fullstack:demo-backend -n fullstack          # no
```

**NetworkPolicy** (enforcement needs a CNI that supports it —
`minikube start --cni=calico`; otherwise the objects apply but aren't enforced):
```bash
kubectl get networkpolicy -n fullstack
# from a frontend pod, backend should be reachable, database should NOT be:
kubectl exec -n fullstack deploy/demo-frontend -- wget -qO- http://demo-backend:5678/
```

**Migration Job:** re-run on demand by bumping the revision (any upgrade
re-triggers the `pre-upgrade`/`post-install` hook):
```bash
kubectl get jobs -n fullstack
kubectl logs -n fullstack job/demo-db-migrate-1
```

**Backup CronJob:** trigger it immediately instead of waiting for 02:00:
```bash
kubectl create job --from=cronjob/demo-db-backup manual-backup-1 -n fullstack
kubectl logs -n fullstack job/manual-backup-1
```

## Upgrade / rollback / uninstall

```bash
helm upgrade demo . -n fullstack -f values.yaml   # new revision
helm history demo -n fullstack
helm rollback demo 1 -n fullstack
helm uninstall demo -n fullstack
kubectl delete namespace fullstack   # only if you created it with --create-namespace
```

## Troubleshooting

```bash
kubectl describe pod <pod> -n fullstack
kubectl logs <pod> -n fullstack
helm get values demo -n fullstack
helm get manifest demo -n fullstack
```
