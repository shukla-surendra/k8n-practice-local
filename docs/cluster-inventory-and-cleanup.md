# What's running on this cluster, how to know what's expected, and how to remove it

## Why a "new" cluster has this much on it

It isn't new. The `minikube` profile is **206 days old** (`kubectl get node minikube` → `AGE`)
and has been the target of many separate sessions/tasks in this repo's history — it accumulates,
it doesn't reset between tasks. "Why so much is running" has a specific answer here, not just
"clusters grow over time":

```
$ kubectl get ns
auth              # Dex — SSO/OIDC identity provider
cert-manager      # TLS certificate automation (used by Knative, Istio, KServe webhooks)
ingress-nginx     # ingress controller (minikube addon, see local-cluster-setup.md)
istio-system      # service mesh — sidecar injection, mTLS, traffic routing
knative-serving   # serverless/autoscaling layer — what gives KServe scale-to-zero
kubeflow          # 33 Deployments: ml-pipeline (KFP), mysql, seaweedfs, workflow-controller
                  #   (Argo), katib, kserve-controller-manager, notebook-controller,
                  #   tensorboard-controller, profiles, central dashboard, and more
kubeflow-system   # jobset-controller, kubeflow-trainer-controller (training-operator successor)
oauth2-proxy      # auth proxy in front of the dashboard, works with Dex
```

That combination — Istio + Knative + Dex + oauth2-proxy + cert-manager + the full Kubeflow
component set, all cross-wired — is not several small installs. It is **one thing**: the
official [`kubeflow/manifests`](https://github.com/kubeflow/manifests) distribution, installed
via its standard `kustomize build example | kubectl apply -f -` loop (it needs several passes —
CRDs before the CRs that use them — hence "loop" rather than a single apply). That single
install brings in every namespace above as a package; you don't get Istio and Knative and Dex
independently, KServe running in `Serverless` mode *requires* them.

**This is not documented anywhere in this repo.** Two install docs *do* exist —
[`kubeflow-pipeline-sample/`](../kubeflow-pipeline-sample)'s `INSTALL-KUBEFLOW.md`
and [`kserve-inference/`](../kserve-inference)'s `INSTALL-KSERVE.md` — but both
describe smaller, standalone installs (KFP alone; KServe alone in `Standard`/raw mode, no
Istio/Knative) targeted at the **`fullstack`** profile, not `minikube`. Checking the live
cluster against those docs:

```
$ kubectl get ns kserve                          # INSTALL-KSERVE.md says KServe lives here
Error from server (NotFound): namespaces "kserve" not found

$ kubectl get deploy -n kubeflow | grep kserve    # but it's actually here
kserve-controller-manager               0/1   1   0   205d
kserve-localmodel-controller-manager    0/1   1   0   205d
kserve-models-web-app                   0/1   1   0   205d

$ helm list -A                                    # INSTALL-KSERVE.md describes helm releases
(empty)                                           # — none exist on this profile at all
```

That's real drift, not a documentation nitpick: what's installed on `minikube` is the full
platform distribution (KServe bundled inside it, via raw kustomize manifests, not Helm), while
the repo's docs describe a different, smaller, Helm-based install that — per its own doc — went
onto `fullstack` instead. Two different install events, two different clusters, only one of
them written down accurately. The lesson below ("record what you install") exists because of
exactly this gap.

## How to know what's *expected* to be running

Two independent sources, cross-checked against each other — neither alone is trustworthy:

**1. What the repo says should be there** — every documented install and its target cluster:

```bash
find . -iname 'INSTALL-*.md' -o -iname 'README.md' | xargs grep -l -i 'cluster\|profile\|helm install\|kubectl apply' 2>/dev/null
```

In this repo: `kubeflow-pipeline-sample/INSTALL-KUBEFLOW.md` (KFP → `fullstack`),
`kserve-inference/INSTALL-KSERVE.md` (KServe standard mode → `fullstack`). Nothing documents
what's on `minikube` beyond `docs/cluster-architecture.md`'s generic control-plane description.

**2. What's actually live** — a repeatable inventory, not a one-off `kubectl get pods`:

```bash
kubectl get ns                                          # every namespace = every "package" present
helm list -A                                             # Helm-managed releases (empty here — see above)
minikube addons list | grep enabled                      # minikube-specific extras (ingress, metrics-server, ...)
kubectl get deploy,statefulset,daemonset -A --no-headers | awk '{print $1}' | sort | uniq -c   # workload count per namespace
kubectl get crd -o name                                  # the strongest signal for "what operator/platform is this from" —
                                                           #   CRD group names (serving.kserve.io, networking.istio.io,
                                                           #   *.kubeflow.org, argoproj.io) identify the project even when
                                                           #   there's no Helm release or README to check
```

CRDs are the most reliable signal because they can't be installed silently by accident the way
a stray namespace can — each one is a deliberate `kubectl apply` of that project's install
manifests, and its group name (`serving.kserve.io`, `networking.istio.io`, `*.kubeflow.org`,
`argoproj.io`, `cert-manager.io`) tells you exactly which project put it there even with zero
other documentation.

**3. Reconcile the two.** Anywhere live state has a namespace/CRD group that no doc mentions
(or a doc claims a namespace/cluster that live state contradicts, as above), that's undocumented
drift — worth writing down the moment you find it, the same way this doc and
[`incidents.md`](./incidents.md) do, rather than leaving the next person to re-derive it.

## Removal process

**Principle: uninstall the way it was installed.** A Helm release comes off cleanly with
`helm uninstall`; a `kustomize`-applied manifest set comes off with `kubectl delete -k` against
the *same* source and ref used to install it. Reversing the install command is always safer and
more complete than guessing at cleanup, because the installer's manifests are the authoritative
list of everything it created — that's why the two sections below look different.

### Where the install source is known (documented)

```bash
# KFP standalone (kubeflow-pipeline-sample/INSTALL-KUBEFLOW.md) — same ref used to install:
export PIPELINE_VERSION=2.17.0
kubectl delete -k "github.com/kubeflow/pipelines/manifests/kustomize/env/platform-agnostic?ref=$PIPELINE_VERSION"
kubectl delete -k "github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=$PIPELINE_VERSION"

# KServe standalone, Helm-based (kserve-inference/INSTALL-KSERVE.md):
helm uninstall kserve-runtime-configs -n kserve
helm uninstall kserve-resources -n kserve
helm uninstall kserve-crd -n kserve
helm uninstall cert-manager -n cert-manager   # only if nothing else in the cluster depends on it
```

### Where the install source is unknown (the undocumented case above)

This is the actual state of the `minikube` profile's Kubeflow platform install — no recorded
ref, no recorded overlay, no Helm release to reverse. Two options, in order of preference:

**Option A — re-derive the source, then uninstall properly.** The
`kubeflow/manifests` repo's standard uninstall mirrors its install: check out the same
(or matching) tag, then `kustomize build example | kubectl delete -f -` against the identified
overlay. Worth 10 minutes of checking `kubectl get deploy -n kubeflow -o yaml` for image tags to
pin down the version before doing this — an uninstall run against the wrong ref can leave
orphaned CRDs/webhooks behind, which is exactly option B's problem.

**Option B — manual teardown**, when the source truly can't be re-derived. Order matters, to
avoid stuck finalizers and to stop mid-teardown breakage of unrelated future installs:

1. **Delete high-level custom resources first**, while their controllers are still running to
   process the deletion (finalizers on `InferenceService`, `Notebook`, `Workflow`, etc. run
   cleanup logic — deleting the controller before its CRs means that cleanup never happens):
   ```bash
   kubectl delete inferenceservices,notebooks,workflows,profiles --all -A
   ```
2. **Delete the namespaces** — cascades to everything inside:
   ```bash
   kubectl delete ns auth cert-manager istio-system knative-serving kubeflow kubeflow-system oauth2-proxy
   ```
   A namespace can hang in `Terminating` if something inside it has a finalizer whose
   controller is already gone (chicken-and-egg with step 1 if done out of order). Check with
   `kubectl get ns <name> -o json | jq .status.conditions`; as a last resort, edit the namespace
   and clear `spec.finalizers` — this force-deletes the namespace without running any cleanup
   logic, so only do it after confirming nothing inside still needs to gracefully unwind.
3. **Delete cluster-scoped leftovers** — namespace deletion does *not* touch these, and stray
   ones are the most common source of "why does an unrelated future install fail" (a
   `ValidatingWebhookConfiguration` still pointing at a Service that no longer exists rejects
   *any* matching resource cluster-wide with a connection error, not just resources from the
   project that registered it):
   ```bash
   kubectl get crd -o name | grep -Ei 'istio|knative|kubeflow|kserve|argoproj' | xargs -r kubectl delete
   kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations -o name \
     | grep -Ei 'istio|knative|kubeflow|kserve|cache-webhook|admission-webhook|katib|jobset|pvcviewer|spark' \
     | xargs -r kubectl delete
   kubectl get clusterrole,clusterrolebinding -o name \
     | grep -Ei 'istio|knative|kubeflow|kserve' | xargs -r kubectl delete
   ```
4. **Verify** nothing was missed:
   ```bash
   kubectl get crd,mutatingwebhookconfigurations,validatingwebhookconfigurations,clusterrole -A \
     | grep -Ei 'istio|knative|kubeflow|kserve|argoproj'
   ```
   Empty output = clean.

### The nuclear option

`minikube delete -p minikube` removes everything at once, guaranteed-clean, no leftover
webhooks or CRDs possible — because it deletes the VM, not the objects inside it. The tradeoff
is total: it also takes the CPU/memory allocation with it (can't be resized in place either —
see [`incidents.md`](./incidents.md#2026-07-21-grafana-log-viewer-stuck-pending-insufficient-cpu)),
and every workload on the profile needs full reinstallation afterward. Reasonable when you
genuinely want a clean slate; wrong tool when you only want one platform off the cluster.

## Going forward

Every install onto a shared, long-lived cluster is worth writing down the same way
`INSTALL-KUBEFLOW.md` and `INSTALL-KSERVE.md` already do for their targets: **what**, exact
**command/source/ref**, and **which cluster/profile**. That's the only thing that makes Option A
above possible instead of Option B — the full Kubeflow platform install on `minikube` needed
the manual-teardown fallback specifically because no doc records what put it there.
