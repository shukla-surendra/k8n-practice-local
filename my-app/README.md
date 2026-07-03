# my-app — Helm Chart (Learning Project)

A minimal Helm chart for learning how Helm and Kubernetes work together.
This README explains what's in the chart and walks through the full
**Helm release lifecycle** — the commands you use from first install to
final cleanup.

## What's in this chart

```
my-app/
├── Chart.yaml          # Chart metadata: name, version, appVersion
├── values.yaml          # Default configuration values
├── values-dev.yaml       # Overrides for the "dev" environment
├── values-qa.yaml        # Overrides for the "qa" environment
├── values-stage.yaml     # Overrides for the "stage" environment
├── values-prod.yaml      # Overrides for the "prod" environment
└── templates/
    ├── deployment.yaml  # Defines the Pods that run your app
    ├── service.yaml     # Exposes the Pods on a network address
    ├── hpa.yaml          # HorizontalPodAutoscaler (auto-scaling rules)
    └── _helpers.tpl      # Reusable template snippets (names, labels)
```

**How it fits together:** Helm takes `templates/*.yaml`, fills in the
`{{ .Values.* }}` placeholders using a values file (`values.yaml` plus
whichever `values-<env>.yaml` you pass in), and sends the resulting
Kubernetes YAML to your cluster.

## Concepts you'll see in the commands below

| Term | Meaning |
|---|---|
| **Chart** | The packaged template (this directory) — like a blueprint. |
| **Release** | A specific deployment of a chart into a cluster, given a name (e.g. `my-app-dev`). You can install the same chart multiple times as different releases. |
| **Revision** | Every install/upgrade creates a new numbered revision of a release, so you can roll back. |
| **Namespace** | A virtual cluster-within-a-cluster used to isolate resources (e.g. `dev`, `qa`). |

---

## The Helm Lifecycle

### 1. Validate before you deploy

```bash
# Check the chart for structural/syntax problems
helm lint .

# Render the final Kubernetes YAML locally without installing anything
helm template my-app-dev . -f values-dev.yaml

# Simulate an install against the real cluster (catches API/schema errors)
helm install my-app-dev . -f values-dev.yaml --dry-run --debug
```
`lint` and `template` never touch the cluster — always run these first
while you're learning, so mistakes are cheap.

### 2. Install (create a new release)

```bash
helm install my-app-dev . -f values-dev.yaml --namespace dev --create-namespace
```
- `my-app-dev` — the **release name** you're choosing.
- `.` — path to the chart (current directory).
- `-f values-dev.yaml` — layers the dev overrides on top of `values.yaml`.
- `--create-namespace` — creates the `dev` namespace if it doesn't exist.

This creates **revision 1** of the release.

### 3. Check status

```bash
helm list --namespace dev              # see all releases in a namespace
helm status my-app-dev --namespace dev # details on one release
kubectl get pods,svc -n dev            # see the actual K8s resources created
```

### 4. Upgrade (apply changes)

Whenever you edit `values.yaml`, a `values-<env>.yaml` file, or anything
in `templates/`, push the change with `upgrade`:

```bash
helm upgrade my-app-dev . -f values-dev.yaml --namespace dev
```
This does **not** create a new release — it creates a new **revision**
(revision 2, 3, ...) of the *same* release, and Helm updates only what
changed (e.g. rolling out new Pods if the image tag changed).

Convenience flag — install if missing, upgrade if it exists:
```bash
helm upgrade --install my-app-dev . -f values-dev.yaml --namespace dev
```

### 5. View history & roll back

```bash
helm history my-app-dev --namespace dev
```
Shows every revision with its status and description. If an upgrade
breaks something:

```bash
helm rollback my-app-dev 1 --namespace dev   # go back to revision 1
```
Rollback is itself a new revision — Helm never deletes history, it just
re-applies an older configuration.

### 6. Uninstall (delete a release)

```bash
helm uninstall my-app-dev --namespace dev
```
This deletes the Deployment, Service, and HPA that this release created.
It does **not** delete the namespace itself.

To keep history for a later rollback of an uninstalled release:
```bash
helm uninstall my-app-dev --namespace dev --keep-history
```

---

## Deploying to different environments

This chart uses one base `values.yaml` plus per-environment override
files. Same chart, different config, separate releases:

```bash
helm upgrade --install my-app-dev   . -f values-dev.yaml   --namespace dev   --create-namespace
helm upgrade --install my-app-qa    . -f values-qa.yaml    --namespace qa    --create-namespace
helm upgrade --install my-app-stage . -f values-stage.yaml --namespace stage --create-namespace
helm upgrade --install my-app-prod  . -f values-prod.yaml  --namespace prod  --create-namespace
```

## Quick command cheat-sheet

| Goal | Command |
|---|---|
| Check chart syntax | `helm lint .` |
| Preview generated YAML | `helm template <release> . -f <values-file>` |
| Simulate install | `helm install <release> . -f <values-file> --dry-run --debug` |
| Install | `helm install <release> . -f <values-file> -n <namespace> --create-namespace` |
| Install or update | `helm upgrade --install <release> . -f <values-file> -n <namespace>` |
| Update existing release | `helm upgrade <release> . -f <values-file> -n <namespace>` |
| List releases | `helm list -n <namespace>` |
| Release details | `helm status <release> -n <namespace>` |
| See revision history | `helm history <release> -n <namespace>` |
| Undo last change | `helm rollback <release> <revision> -n <namespace>` |
| Remove a release | `helm uninstall <release> -n <namespace>` |

## Troubleshooting

```bash
kubectl describe pod <pod-name> -n <namespace>   # why is a pod not starting?
kubectl logs <pod-name> -n <namespace>           # app logs
helm get values <release> -n <namespace>         # what values did this release actually use?
helm get manifest <release> -n <namespace>       # what YAML did Helm actually apply?
```
