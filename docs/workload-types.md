# Workload types: Deployment, StatefulSet, DaemonSet, Job, CronJob

All five ultimately create Pods; the difference is the *identity and lifecycle guarantee* each
one gives those Pods. Grounded in real workloads already in this repo.

## Deployment — identical, interchangeable replicas

Covered in depth in [`kubernetes-fundamentals.md`](./kubernetes-fundamentals.md). The default
choice: any replica can be replaced by a fresh one with a new name/IP and nothing downstream
cares (`full-stack-app`'s frontend and backend are both Deployments).

## StatefulSet — replicas with stable identity

```yaml
# full-stack-app/charts/database/templates/statefulset.yaml
spec:
  serviceName: {{ include "database.fullname" . }}
  replicas: 1
  volumeClaimTemplates:
    - metadata: {name: data}
      spec: {accessModes: ["ReadWriteOnce"], resources: {requests: {storage: ...}}}
```

Used for the Postgres database. What a StatefulSet guarantees that a Deployment doesn't:

- **Stable, predictable Pod names**: `<name>-0`, `<name>-1`, ... (not a random suffix) — and
  each keeps that name across restarts/rescheduling.
- **A PVC per replica** (via `volumeClaimTemplates`, see
  [`storage-and-persistence.md`](./storage-and-persistence.md)) that follows that specific
  ordinal, not a shared volume — replica `-0` always reattaches to the same disk.
  A Deployment has no such concept; if you gave multiple Deployment replicas a shared PVC, they'd
  all be fighting over the same disk (and it'd need to be RWX, which most cloud block storage
  isn't).
- **Ordered, sequential rollout/scaling** by default (`0` before `1` before `2`, and scale-down
  in reverse) — relevant for things like a replicated database where node `0` needs to be up
  before `1` joins.
- A **headless Service** (`clusterIP: None`, set via `serviceName`) gives each replica its own
  stable DNS name (`<pod>.<service>.<namespace>.svc.cluster.local`), so clients can address a
  *specific* replica instead of "any of them" — meaningless for a stateless web server, essential
  for e.g. talking to a database's primary specifically.

This repo's Postgres uses `replicas: 1`, so a lot of that (ordered rollout, per-replica DNS)
isn't really exercised — the reason it's still a StatefulSet and not a Deployment is the
per-replica PVC guarantee: even at one replica, that guarantee is what makes the data volume
Postgres owns be *the same* volume across every restart.

## DaemonSet — exactly one Pod per node

Not present in this repo's own charts, but this cluster runs some (`kube-proxy`, and typically
the CNI's node agent) — visible via `kubectl get daemonset -A`. Used for node-level agents: log
shippers, metrics collectors, CNI plugins — anything that needs to run on *every* node,
automatically added/removed as nodes join/leave, rather than a chosen replica count.

## Job — run to completion, once

```yaml
# full-stack-app/templates/migration-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  annotations:
    helm.sh/hook: post-install,pre-upgrade
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          command: ["sh", "-c", "... psql ... INSERT INTO demo_items ..."]
```

Runs the DB schema/seed migration exactly once per install/upgrade (note `restartPolicy: Never`
— a Job's Pod isn't restarted in place on failure, the **Job controller** creates a new Pod, up
to `backoffLimit` attempts). The `helm.sh/hook` annotations aren't a Kubernetes concept — they're
Helm's mechanism for running this Job at a specific point in the install/upgrade lifecycle
(after install, before upgrade) rather than as a normal templated resource.

## CronJob — a Job, on a schedule

```yaml
# full-stack-app/templates/backup-cronjob.yaml
spec:
  schedule: "0 2 * * *"          # standard cron syntax
  concurrencyPolicy: Forbid       # don't start a new run if the previous is still going
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec: { ... same shape as a Job ... }
```

The CronJob controller creates a new `Job` object (which then creates Pods, same as any Job) at
each scheduled tick. `concurrencyPolicy: Forbid` matters here specifically because it's a
database backup — two overlapping `pg_dump` runs racing against each other is worse than a
missed run. Trigger one on demand for testing without waiting for the schedule:

```bash
kubectl create job --from=cronjob/<release>-db-backup manual-backup-1 -n <namespace>
```

## Choosing between them

| Need | Use |
|---|---|
| Stateless, interchangeable replicas | Deployment |
| Stable identity / one-volume-per-replica (databases, brokers) | StatefulSet |
| One Pod per node (agents, log/metrics shippers) | DaemonSet |
| Run once, to completion (migrations, batch processing) | Job |
| Run on a schedule | CronJob |

## Quick reference

```bash
kubectl get deploy,sts,ds,job,cronjob -n <namespace>
kubectl rollout status deployment/<name>
kubectl rollout status statefulset/<name>
kubectl logs job/<name>
```
