# Installing KServe — what we hit locally, and how EKS differs

This chart (`kserve-inference`) only creates an `InferenceService` object — it needs KServe's
control plane already running in the cluster. This doc covers how we installed that control
plane locally, the problems we ran into along the way, and what changes for a real EKS cluster.

## Troubleshooting log (local minikube)

### 1. `cluster reachability check failed` on `helm install`

```
Error: INSTALLATION FAILED: cluster reachability check failed: kubernetes cluster unreachable:
Get "https://127.0.0.1:53431/version": dial tcp 127.0.0.1:53431: connect: connection refused
```

**Why:** `kubectl config current-context` was `fullstack`, a minikube profile using the `docker`
driver. `minikube profile list` showed it as `Stopped` — the container backing the API server
wasn't running, so nothing was listening on that local port.

**Fix:** `minikube start -p fullstack`.

### 2. KServe CRDs missing

```
kubectl get crd inferenceservices.serving.kserve.io
Error from server (NotFound)
```

**Why:** starting the cluster only brings up Kubernetes itself. KServe is a separate operator
(CRDs + controller) that has to be installed on top — it was never installed on this cluster.

**Fix:** run KServe's official installer (see below).

### 3. `hack/quick_install.sh` returned 404

**Why:** that script was renamed upstream. The current entrypoint in the KServe repo is
`hack/kserve-install.sh`. Always check the repo's current `hack/` directory rather than trusting
a remembered path/URL, since installer scripts move between releases.

### 4. `readarray: command not found`

**Why:** `hack/kserve-install.sh` (and the scripts it calls) use `readarray`, a bash 4+ builtin.
macOS ships bash 3.2 as `/bin/bash` for licensing reasons (Apple never moved past the last
GPLv2 bash release), and never updates it.

**Fix:** `brew install bash` (installs bash 5.3 at `/opt/homebrew/bin/bash`, alongside the
system one — doesn't touch `/bin/bash`).

### 5. Installing the new bash didn't fix it on its own

**Why:** each script starts with `#!/bin/bash` — an absolute path baked into the shebang line.
Shebangs are not resolved through `$PATH`, so having `/opt/homebrew/bin/bash` earlier in `PATH`
made no difference. And `/bin/bash` itself can't be overwritten or replaced due to macOS SIP
(System Integrity Protection).

**Fix:** since we had a disposable local clone of the `kserve/kserve` repo (not a system file),
we rewrote the shebang lines in `hack/**/*.sh` from `#!/bin/bash` to `#!/opt/homebrew/bin/bash`,
then reran the installer. This is a local-clone-only workaround — never needed again once done
for that checkout, and irrelevant on Linux CI runners or EKS nodes, which ship a modern bash.

## Where KServe ended up installed (local)

- **Cluster:** `fullstack` minikube profile (docker driver, 2 CPU / 3GB), context name `fullstack`
- **Mode:** Standard/raw (no Istio, no Knative) — chosen because the node's resource cap was too
  small to comfortably run Istio + Knative alongside everything else already on the box
- **Method:** official `kserve/kserve` repo at tag `v0.19.0`, `hack/kserve-install.sh --raw --helm`,
  cloned into the session scratchpad (not part of this repo)
- **What got deployed to the cluster:**
  - `cert-manager` (namespace `cert-manager`) — Helm release `cert-manager`
  - KServe CRDs — Helm release `kserve-crd` (namespace `kserve`)
  - KServe controller — Helm release `kserve-resources` (namespace `kserve`,
    Deployment `kserve-controller-manager`)
  - Default `ClusterServingRuntime`s (sklearn, xgboost, tensorflow, pytorch, huggingface, etc.) —
    Helm release `kserve-runtime-configs`

This is a durable, cluster-scoped install — it persists on the `fullstack` minikube cluster
across sessions until uninstalled, unlike the scratchpad clone used to install it.

## Where you'd install it on EKS

The KServe pieces themselves are the same Helm charts (`ghcr.io/kserve/charts/kserve-crd`,
`kserve-resources`, `kserve-runtime-configs`) — what changes on EKS is the surrounding
infrastructure and how you drive the install:

| Concern | Local (minikube) | EKS |
|---|---|---|
| Control plane namespace | `kserve` | Same — `kserve` (convention, not required) |
| Deployment mode | Standard/raw (resource-constrained) | Usually **Serverless** (Istio + Knative) for real scale-to-zero traffic-based autoscaling — EKS nodes can absorb it. Raw mode is still valid if you'd rather rely on the AWS Load Balancer Controller + HPA instead of Istio/Knative. |
| Ingress | none (cluster-local URL, port-forward to test) | AWS Load Balancer Controller (ALB/NLB) in front of Istio ingress gateway (serverless) or directly in front of the predictor Service (raw) |
| Model storage (`storageUri`) | `gs://kfserving-examples/...` (public GCS) | `s3://your-bucket/...` — needs an IAM Role for Service Accounts (**IRSA**) bound to the predictor's `serviceAccountName` so pods can read from S3 without static credentials |
| cert-manager | installed fresh via the script | Usually already present cluster-wide (shared by ALB controller, Istio, etc.) — check before reinstalling |
| GPU inference | not applicable | GPU node group (e.g. `g5`/`g6` instance types) + NVIDIA device plugin, referenced via `resources.limits."nvidia.com/gpu"` in `values.yaml` |
| Install method | one-off shell script from a scratch clone | Same Helm charts, but driven from CI/CD or GitOps (ArgoCD/Flux) pointed at the OCI charts, so the install is reproducible and reviewable instead of an ad-hoc local run |
| Bash version issue | hit it (macOS bash 3.2) | won't happen — CI runners and EKS-adjacent tooling (e.g. a bastion, CodeBuild image, GitHub Actions runner) ship modern bash by default |

### Practical EKS install sketch

```bash
# same charts we used locally, pulled straight from OCI — no repo clone needed
helm upgrade --install kserve-crd oci://ghcr.io/kserve/charts/kserve-crd \
  --version v0.19.0 -n kserve --create-namespace

helm upgrade --install kserve-resources oci://ghcr.io/kserve/charts/kserve-resources \
  --version v0.19.0 -n kserve \
  --set kserve.controller.deploymentMode=Serverless   # or Standard for raw mode

helm upgrade --install kserve-runtime-configs oci://ghcr.io/kserve/charts/kserve-runtime-configs \
  --version v0.19.0 -n kserve
```

Prerequisites on EKS before the above: cert-manager, and — only for Serverless mode —
Istio and Knative Serving installed first (the same dependency scripts in `hack/setup/quick-install/`
in the KServe repo handle this, or your platform team's standard Istio/Knative install).

Then this repo's `kserve-inference` chart deploys unchanged on top — just point
`predictor.model.storageUri` at an `s3://` URI and set `predictor.serviceAccountName` to an
IRSA-bound ServiceAccount.
