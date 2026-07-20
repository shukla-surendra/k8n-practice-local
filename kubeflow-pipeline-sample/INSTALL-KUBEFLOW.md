# Installing Kubeflow Pipelines — what we hit locally

There is no Helm chart here (unlike `kserve-inference` or `my-app`) because upstream doesn't
ship one — Kubeflow Pipelines (KFP) is installed straight from its official Kustomize
manifests in `github.com/kubeflow/pipelines`, the same pattern `kargo/INSTALL-KARGO.md` uses
for Kargo's control plane.

This installs **standalone Kubeflow Pipelines** only — not the full Kubeflow platform
(no Notebooks, Katib, Training Operator, central dashboard, or Dex auth). Full Kubeflow is
much heavier and generally wants more than a single-node minikube VM.

## Where it's installed

- **Cluster:** `fullstack` minikube profile (`docker` driver, node arch `arm64` — Apple
  Silicon), same cluster KServe and Kargo are on
- **Namespace:** `kubeflow`
- **Version:** KFP `2.17.0` (latest stable at install time)
- **Manifests:** `github.com/kubeflow/pipelines/manifests/kustomize`, overlay
  `env/platform-agnostic` — single-user, no auth, no cloud-provider integration
- **Components deployed:** `ml-pipeline` (API server), `ml-pipeline-ui`,
  `ml-pipeline-persistenceagent`, `ml-pipeline-scheduledworkflow`, `ml-pipeline-viewer-crd`,
  `ml-pipeline-visualizationserver`, `metadata-grpc`/`metadata-envoy`/`metadata-writer`
  (ML Metadata / lineage), `cache-server`/`cache-deployer` (step output caching), `mysql`
  (pipeline + metadata store), `seaweedfs` (S3-compatible artifact storage, this overlay's
  replacement for MinIO), `workflow-controller` (Argo Workflows — executes pipeline runs)

## Install commands used

```bash
export PIPELINE_VERSION=2.17.0

# 1. Cluster-scoped resources: CRDs (Argo Workflows, Application, ScheduledWorkflow, Viewer)
#    and the cache-deployer's ClusterRole/ClusterRoleBinding. Creates the `kubeflow` namespace.
kubectl apply -k "github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=$PIPELINE_VERSION"
kubectl wait --for condition=established --timeout=60s crd/applications.app.k8s.io

# 2. Namespaced resources: the actual KFP components, single-user/no-auth overlay
kubectl apply -k "github.com/kubeflow/pipelines/manifests/kustomize/env/platform-agnostic?ref=$PIPELINE_VERSION"
```

Access once running (no Ingress set up for this):

```bash
kubectl port-forward -n kubeflow svc/ml-pipeline-ui 8080:80     # UI at http://localhost:8080
kubectl port-forward -n kubeflow svc/ml-pipeline 8888:8888       # API, for kfp.Client(host=...)
```

## How a pipeline gets deployed (per-run, not per-install)

Installing KFP (above) is one-time infrastructure. Deploying an actual ML pipeline is a
separate, repeatable flow that never touches `kubectl`/Helm — everything after compilation goes
through the `ml-pipeline` API:

```
pipeline.py (Python, kfp SDK, @dsl.component / @dsl.pipeline)
      |  kfp.compiler.Compiler().compile(...)
      v
pipeline.yaml (KFP IR YAML — a PipelineSpec, not a raw Argo Workflow)
      |  upload via the ml-pipeline-ui, or
      |  kfp.Client(host=...).create_run_from_pipeline_package(...)
      v
ml-pipeline API server        stores the pipeline definition in MySQL (`mlpipeline` db)
      |  on "create run": translates the IR into an Argo `Workflow` object
      v
Argo `Workflow` custom resource created in the `kubeflow` namespace
      |  workflow-controller watches Workflow CRs
      v
workflow-controller schedules one Pod per component
      |  each pod uses that component's base_image (`python:3.11-slim` in this sample)
      |  KFP's launcher (injected into the pod) pip-installs packages_to_install,
      |  then runs your Python function
      v
Outputs (Dataset/Model artifacts) uploaded to SeaweedFS (S3-compatible, in-cluster)
Metrics (accuracy, f1_macro, ...) written back through the launcher to ml-pipeline
      |
      v
ml-pipeline-persistenceagent syncs the Workflow's status into KFP's run DB
      -> ml-pipeline-ui reads that DB and renders the run graph / logs / metrics
```

There's no image build step on your side — component containers are stock base images, and
your function + its declared dependencies get injected and `pip install`ed at pod startup. Fine
for iterating; for a production pipeline you'd normally bake a custom image with dependencies
frozen in, so every run doesn't reinstall from PyPI.

## Where Kubeflow artifacts are actually stored

Two separate stores, both backed by `PersistentVolumeClaim`s in the `kubeflow` namespace:

| What | Where | K8s object | Size | Underlying path (this cluster) |
|---|---|---|---|---|
| Step **artifacts** (Dataset/Model files, e.g. `dataset`, `model` in this sample) | SeaweedFS (S3-compatible object store), bucket `mlpipeline` | `pvc/seaweedfs-pvc` | 20Gi | `/tmp/hostpath-provisioner/kubeflow/seaweedfs-pvc` inside the `fullstack` minikube node |
| **Pipeline/run metadata** (run history, DB-tracked metrics, pipeline defs) | MySQL, db `mlpipeline` | `pvc/mysql-pv-claim` | 20Gi | `/tmp/hostpath-provisioner/kubeflow/mysql-pv-claim` inside the `fullstack` minikube node |
| **ML Metadata / lineage** (execution graph, artifact provenance) | Would be MySQL db `metadb` via `metadata-grpc` | — | — | not populated — `metadata-writer` is scaled to 0 (issue #2 below) |

Artifact object keys follow this layout (from `workflow-controller-configmap`):

```
private-artifacts/{workflow.namespace}/{workflow.name}/{YYYY}/{MM}/{DD}/{pod.name}
```

i.e. every component's output lands in SeaweedFS under a path scoped by namespace, workflow run
name, and date — e.g. a `dataset` output from a run of `iris-training-pipeline` shows up as
something like `private-artifacts/kubeflow/iris-training-pipeline-abc123/2026/07/20/iris-training-pipeline-abc123-create-dataset/dataset`.

Credentials for the bucket are in the `mlpipeline-minio-artifact` Secret (kept as `minio`/`minio123`
by the chart — it's a dev-only default, not meaningful creds since nothing external can reach it).

**Persistence caveat:** both PVCs use the `standard` StorageClass, which on minikube is backed
by `hostpath-provisioner` — data lives inside the `fullstack` node's *container* filesystem, not
your Mac's filesystem. It survives `minikube stop`/`start` and the Docker Desktop restart from
issue #3 (verified below), but is gone if the `fullstack` minikube profile itself is deleted
(`minikube delete -p fullstack`). Nothing here is backed up outside the cluster.

To browse the bucket directly:

```bash
kubectl port-forward -n kubeflow svc/seaweedfs 8333:8333   # S3 API
# then use any S3 client (aws-cli, s3cmd, mc) against http://localhost:8333
# with the accesskey/secretkey from: kubectl get secret mlpipeline-minio-artifact -n kubeflow -o yaml
```

## Troubleshooting log

### 1. `env/platform-agnostic-pns` — 404 / `evalsymlink failure`

```
error: evalsymlink failure on '.../manifests/kustomize/env/platform-agnostic-pns' :
lstat .../platform-agnostic-pns: no such file or directory
```

**Why:** older KFP docs/tutorials reference `env/platform-agnostic-pns` (the PNS-executor,
no-auth overlay). That path no longer exists as of `2.17.0` — the repo's `env/` directory now
has `platform-agnostic`, `platform-agnostic-multi-user`, `platform-agnostic-postgresql`, `dev`,
`dev-kind`, `gcp`, `openshift`, etc. Directory layout moves between releases; always check the
tag you're pinning to (`git clone --branch <ref>` and `ls manifests/kustomize/env/`) rather than
trusting a remembered path.

**Fix:** use `env/platform-agnostic` instead — it's the current single-user/no-auth overlay.

### 2. `kfp-metadata-writer` — `ErrImagePull`, no arm64 manifest

```
Failed to pull image "ghcr.io/kubeflow/kfp-metadata-writer:2.17.0":
no matching manifest for linux/arm64/v8 in the manifest list entries
```

**Why:** `docker manifest inspect` confirms this image is published `amd64`-only at this tag.
The `fullstack` node is `arm64` (Apple Silicon), so kubelet can't find a matching layer.
`metadata-writer` watches Argo Workflow pods and writes execution/artifact records into MLMD —
losing it degrades the Pipelines UI's "Artifacts"/lineage view, but pipeline
submission/execution/logs through `ml-pipeline` + Argo still work.

### 3. ⚠️ Do NOT "fix" #2 with `multiarch/qemu-user-static --reset -p yes` — it broke the whole Docker daemon

The obvious fix for an amd64-only image on an arm64 host is registering QEMU emulation:

```bash
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes   # DON'T — see below
```

**What went wrong:** on Docker Desktop for Apple Silicon, this script also registered a
`binfmt_misc` handler for **`aarch64` itself** (the *native* architecture), not just the
foreign ones it's meant for. Once that's registered, the kernel routes native arm64 exec calls
through the qemu interpreter too — including `containerd-shim-runc-v2` and `runc`, which
Docker Desktop's own daemon needs to spawn anything. Within about a minute this cascaded into:

- `workflow-controller` and other pods stuck in `RunContainerError` /
  `CrashLoopBackOff` with `fork/exec /usr/bin/containerd-shim-runc-v2: exec format error`
- new `docker run` calls failing to extract *any* image layer (`fork/exec /usr/bin/unpigz:
  exec format error`)
- `docker exec` into already-running containers failing (`fork/exec /usr/bin/runc: exec format
  error`)

This isn't scoped to the `kubeflow` namespace or even to minikube — it broke process
creation for **every** container on the machine, including unrelated ones already running
(`rag_pgvector_local`, `dbx-mlflow-*`, `pg_explore`, etc.). Because `docker run`/`docker exec`
were themselves broken, there was no way to reach into the VM and unregister just the bad
`binfmt_misc` entry — nothing new could be spawned to do the unregistering.

**Fix:** restart Docker Desktop entirely (Docker menu bar icon → Restart, or
`osascript -e 'quit app "Docker"'` then `open -a Docker`). That reboots the lightweight Linux
VM, which resets kernel state including `binfmt_misc` back to defaults. Containers with a
restart policy come back on their own; everything else needs to be started again manually.

**If an arm64-incompatible image comes up again:** do *not* reach for the qemu multiarch
trick on Docker Desktop for Mac. Prefer, in order: (a) check if a newer tag/branch publishes a
multi-arch manifest, (b) build a local arm64 image from the same source, (c) accept the
degraded functionality if the component is non-critical (as with `metadata-writer` here) —
`kubectl scale deployment/metadata-writer -n kubeflow --replicas=0` silences the crash-looping
pod without touching the rest of the install.

## Current status (verified)

After the Docker Desktop restart, `minikube start -p fullstack` was needed to bring the node
back up (the VM restart stopped it). All `kubeflow` pods came back `Running` except
`metadata-writer`, which returned to the original `ErrImagePull`/`ImagePullBackOff` from issue
#2 — confirming the emulation registration is gone and this is purely the arm64-image gap.
`metadata-writer` was scaled to 0 replicas per the note above:

```bash
kubectl scale deployment/metadata-writer -n kubeflow --replicas=0
```

```
kubectl get pods -n kubeflow
NAME                                          READY   STATUS    RESTARTS   AGE
cache-deployer-deployment-...                 1/1     Running   ...
cache-server-...                              1/1     Running   ...
metadata-envoy-deployment-...                 1/1     Running   ...
metadata-grpc-deployment-...                  1/1     Running   ...
ml-pipeline-...                               1/1     Running   ...
ml-pipeline-persistenceagent-...              1/1     Running   ...
ml-pipeline-scheduledworkflow-...             1/1     Running   ...
ml-pipeline-ui-...                            1/1     Running   ...
ml-pipeline-viewer-crd-...                    1/1     Running   ...
ml-pipeline-visualizationserver-...           1/1     Running   ...
mysql-...                                     1/1     Running   ...
seaweedfs-...                                 1/1     Running   ...
workflow-controller-...                       1/1     Running   ...
```

Core pipeline functionality (submit/run/log a pipeline, view runs in the UI) works. The only
gap is the Pipelines UI's Artifacts/lineage view, which depends on `metadata-writer`.

## Running the sample pipeline

See [`pipeline.py`](./pipeline.py) in this directory — compile it with
`python pipeline.py` (needs `pip install -r requirements.txt`), then either upload the
resulting `pipeline.yaml` through the port-forwarded UI, or submit it with the `kfp` SDK
against the port-forwarded API (`kfp.Client(host="http://localhost:8888")`).
