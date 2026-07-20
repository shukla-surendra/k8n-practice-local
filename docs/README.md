# Kubernetes docs

Working notes and explainers, basic to advanced, grounded in the actual charts/manifests and
live cluster in this repo wherever possible. Run `make docs-serve` from the repo root for a
browsable site (search, dark mode).

## Basics

- [`kubernetes-fundamentals.md`](./kubernetes-fundamentals.md) — container runtimes/CRI, Pod
  vs Deployment vs ReplicaSet, everyday `kubectl` commands.
- [`cluster-architecture.md`](./cluster-architecture.md) — control plane vs. node components,
  the watch-reconcile pattern everything else is built on.
- [`configmaps-and-secrets.md`](./configmaps-and-secrets.md) — non-sensitive vs. sensitive
  config, why Secrets aren't real encryption, the config-reload gotcha.
- [`storage-and-persistence.md`](./storage-and-persistence.md) — Volume vs PV vs PVC vs
  StorageClass, `volumeClaimTemplates`, what backs storage on minikube vs. EKS.

## Networking & Access

- [`accessing-pods-and-services.md`](./accessing-pods-and-services.md) — `kubectl port-forward`
  vs. the production way (Service + Ingress), worked through with `sample-nginx/`.
- [`multiple-services-same-port.md`](./multiple-services-same-port.md) — why N services all
  listening on the same port (e.g. 8080) don't conflict, and the few places port reuse
  actually does (same-Pod containers, `hostPort`, explicit `NodePort` — cross-namespace too).
- [`network-policies.md`](./network-policies.md) — default-open networking, allow-list
  NetworkPolicy semantics, and why enforcement depends on the CNI.

## Workloads & Reliability

- [`workload-types.md`](./workload-types.md) — Deployment vs StatefulSet vs DaemonSet vs Job
  vs CronJob, and when each one is the right choice.
- [`probes-and-health-checks.md`](./probes-and-health-checks.md) — liveness vs readiness vs
  startup probes, and why a missing readiness probe breaks rollouts.
- [`resource-management.md`](./resource-management.md) — requests/limits, LimitRange,
  ResourceQuota, HorizontalPodAutoscaler, PodDisruptionBudget, and how they interact.

## Security

- [`rbac.md`](./rbac.md) — ServiceAccount/Role/RoleBinding/ClusterRole, least-privilege in
  practice, checking effective permissions with `kubectl auth can-i`.

## Advanced

- [`crds-and-operators.md`](./crds-and-operators.md) — how CustomResourceDefinitions +
  controllers work, with KServe/Kargo/Argo Workflows as real examples already on this cluster.
- [`helm-vs-kustomize.md`](./helm-vs-kustomize.md) — templating + release tracking vs.
  overlay/patch on plain YAML, and why this repo uses both.

## Install logs

For what broke and how it was fixed installing specific components on this cluster, see the
`INSTALL-*.md` files next to each project: `kserve-inference/INSTALL-KSERVE.md`,
`kargo/INSTALL-KARGO.md`, `kubeflow-pipeline-sample/INSTALL-KUBEFLOW.md`.
