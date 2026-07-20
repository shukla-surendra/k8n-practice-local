# CustomResourceDefinitions and Operators

The mechanism that lets Kubernetes model things it has no built-in concept of — an ML inference
service, a GitOps promotion pipeline, a training job's workflow — as first-class API objects
with `kubectl get/apply/describe` support, backed by a custom controller instead of a built-in
one. Grounded in three CRDs actually installed on this cluster.

## The pattern

1. A **CustomResourceDefinition (CRD)** registers a new `kind` with the API server — e.g.
   `InferenceService`, `Workflow`, `Stage`. From that point on it behaves like any built-in
   type: validated on `apply`, stored in etcd, watchable.
2. An **operator/controller** — just another Pod, running the same watch-reconcile loop
   described in [`cluster-architecture.md`](./cluster-architecture.md) — watches objects of that
   `kind` and does whatever the CRD represents: creates a Deployment+Service+autoscaler for an
   `InferenceService`, promotes a `Stage`'s Freight, runs a `Workflow`'s steps as Pods.

A CRD with no controller running is just inert schema — `kubectl apply` succeeds and the object
sits in etcd, but nothing acts on it. This is a common local-dev trap: installing only a CRD
bundle (or a Helm chart that ships CRDs) without also running the operator that watches them.

## Example 1 — KServe's `InferenceService`

```yaml
# kserve-inference/templates/inferenceservice.yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
spec:
  predictor:
    model:
      modelFormat: {name: sklearn}
      storageUri: "..."
      resources: {...}
```

The chart's own comment: *"KServe's controller reads this and creates the underlying Knative
Service / Deployment, Service, and (in Serverless mode) the autoscaling + scale-to-zero
wiring."* — this repo's Helm chart only ever creates the one `InferenceService` object; every
Deployment/Service/HPA-equivalent underneath it is created and owned by KServe's controller, not
by the chart. See `kserve-inference/INSTALL-KSERVE.md` for the controller install itself.

## Example 2 — Kargo's promotion pipeline CRDs

From `kargo/INSTALL-KARGO.md`: `Project`, `Stage`, `Warehouse`, `Freight`, `Promotion`,
`PromotionTask`, and cluster-scoped variants — nine custom types, all under
`*.kargo.akuity.io`, backing a GitOps promotion pipeline built on top of Argo CD. `kargo-api`,
`kargo-controller`, and `kargo-management-controller` are the operators reconciling them.

## Example 3 — Argo Workflows' `Workflow` (via Kubeflow Pipelines)

From `kubeflow-pipeline-sample/INSTALL-KUBEFLOW.md`: every KFP pipeline run compiles down to an
Argo `Workflow` custom resource, reconciled by the `workflow-controller` Deployment — one Pod
per pipeline step, exactly the watch-reconcile pattern above. This is a good example of a CRD
being an **implementation detail** behind a higher-level API (`ml-pipeline`'s REST API) rather
than something a user interacts with directly.

## Checking what's installed and who's watching it

```bash
kubectl get crd | grep kserve       # or kargo.akuity.io, argoproj.io, etc.
kubectl get crd <name> -o jsonpath='{.spec.group}/{.spec.versions[0].name} {.spec.names.kind}'

# is anything actually reconciling these objects? — check for a controller Deployment
# in the CRD's install namespace, then check its logs against a specific object:
kubectl get inferenceservice -A
kubectl logs -n kserve deploy/kserve-controller-manager | grep <object-name>
```

## Why this matters more than it looks like

Every "installer" in this repo that isn't a plain Helm chart of Deployments — KServe, Kargo,
Kubeflow Pipelines — is this same pattern: a CRD bundle plus one or more controller Pods.
Understanding CRD+operator as one mechanism (not three unrelated products) is what makes
`kubectl get <weird-custom-kind>` and "why isn't this InferenceService doing anything" both
answerable the same way: check the CRD is registered, then check the controller is running and
actually watching it.
