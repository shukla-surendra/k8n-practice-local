# Probes: liveness, readiness, startup

Three probe types, three different questions, three different consequences when they fail.
Grounded in `full-stack-app`'s backend Deployment and database StatefulSet, which use two
different probe mechanisms.

## The three types

| Probe | Question it answers | On failure |
|---|---|---|
| `readinessProbe` | "Can this Pod serve traffic *right now*?" | Pod is pulled out of the Service's endpoints (kube-proxy stops routing to it) — **not** restarted. Traffic just stops arriving until it passes again. |
| `livenessProbe` | "Is this Pod's process healthy, or wedged?" | kubelet **kills and restarts** the container. Only use this for "the only fix is a restart" conditions — a wrong liveness probe (or one that's slower than the app under load) causes restart loops that make things worse. |
| `startupProbe` | "Has this slow-starting app finished booting yet?" | Suppresses liveness/readiness checks until it passes, so a legitimately slow startup doesn't get killed by an impatient liveness probe. Not used in this repo's examples (both apps start fast), but the right tool once boot time gets long/variable (JVM apps, large model loads). |

## HTTP probe — the backend

```yaml
# full-stack-app/charts/backend/templates/deployment.yaml
readinessProbe:
  httpGet:
    path: /
    port: http
  initialDelaySeconds: 2
  periodSeconds: 5
livenessProbe:
  httpGet:
    path: /
    port: http
  initialDelaySeconds: 5
  periodSeconds: 10
```

Readiness checks sooner and more often (`initialDelaySeconds: 2`, every 5s) than liveness
(`5s`, every 10s) — readiness failures are cheap (just stop routing traffic) so checking
aggressively is fine; liveness failures are expensive (a full container restart) so it's checked
more conservatively, on a longer cadence, giving transient blips less chance to trigger a
restart.

## Exec probe — the database

Postgres has no HTTP endpoint, so the StatefulSet uses a command instead:

```yaml
# full-stack-app/charts/database/templates/statefulset.yaml
readinessProbe:
  exec:
    command: ["pg_isready", "-U", "..."]
  initialDelaySeconds: 5
  periodSeconds: 5
livenessProbe:
  exec:
    command: ["pg_isready", "-U", "..."]
  initialDelaySeconds: 15
  periodSeconds: 10
```

`exec` runs the command inside the container; exit code `0` = success. (The fourth type,
`tcpSocket`, just checks whether a port accepts a connection — weaker than either, useful when
there's no meaningful health command or endpoint at all.)

Note the longer `initialDelaySeconds` for liveness here (15s vs. readiness's 5s) — same
principle as the backend: give the database more runway before the expensive check (restart)
kicks in, since Postgres takes a moment longer to be trustworthy than to merely start accepting
TCP connections.

## Why this matters for rollouts

A Deployment's rolling update waits for the **readiness** probe on new Pods before considering
them "up" and proceeding to terminate old ones (`kubectl rollout status` blocks on this). A
missing or wrong readiness probe means Kubernetes considers a Pod ready the instant its
container starts — traffic gets routed to it before the app inside is actually able to handle
requests, causing a burst of errors during every rollout. This is the single most common
production Kubernetes mistake that doesn't show up in local testing (where you're not usually
watching mid-rollout traffic).

## Quick reference

```bash
kubectl describe pod <name>          # shows probe config + recent failure events
kubectl get events --field-selector involvedObject.name=<pod-name>
```
