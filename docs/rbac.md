# RBAC: ServiceAccount, Role, RoleBinding, ClusterRole, ClusterRoleBinding

Controls **who can do what against the Kubernetes API** — a completely separate concern from
[NetworkPolicy](./network-policies.md) (which controls Pod-to-Pod *network* traffic). RBAC
governs calls to `kube-apiserver`; it has no opinion on whether Pod A can open a TCP connection
to Pod B.

## The four object types

| Object | Scope | Answers |
|---|---|---|
| `ServiceAccount` | Namespaced | "Which identity is this Pod acting as?" Every Pod runs as some ServiceAccount (`default` if unspecified) — this is the identity RBAC rules attach to for anything running *inside* the cluster. |
| `Role` | Namespaced | A set of permissions (verbs on resources), scoped to one namespace. |
| `ClusterRole` | Cluster-wide | Same shape as a Role, but either grants cluster-scoped permissions (on Nodes, PVs, etc. — resources with no namespace) or can be bound within a single namespace via a `RoleBinding` when you want to reuse one permission set across many namespaces. |
| `RoleBinding` / `ClusterRoleBinding` | Namespaced / Cluster-wide | Grants a Role/ClusterRole's permissions to a subject (a ServiceAccount, User, or Group). The Role/ClusterRole alone grants nothing — it's inert until bound. |

## Least-privilege example — the backend's own Role

```yaml
# full-stack-app/charts/backend/templates/role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: backend-config-reader
rules:
  - apiGroups: [""]
    resources: ["configmaps", "secrets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: backend-config-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: backend-config-reader
subjects:
  - kind: ServiceAccount
    name: backend
    namespace: {{ .Release.Namespace }}
```

Read the chart's own comment on this file: *"Deliberately scoped to a Role, not a ClusterRole:
this app has no business reading resources outside its own namespace."* That's the whole
practice in one sentence — grant exactly the verbs on exactly the resources a workload needs,
scoped as narrowly as possible. This backend gets `get/list/watch` (read-only) on
`configmaps`/`secrets` in its own namespace, nothing else — it can't list Pods, can't touch
other namespaces, can't write.

`rules[].apiGroups: [""]` is the **core API group** (Pods, Services, ConfigMaps, Secrets,
Namespaces, ...) — an empty string, not "no group." Named groups look like
`apps` (Deployments), `batch` (Jobs/CronJobs), `rbac.authorization.k8s.io` (RBAC objects
themselves), `serving.kserve.io` (custom resources like `InferenceService`, see
[`crds-and-operators.md`](./crds-and-operators.md)).

## What "cluster-wide" actually looks like

Installing Kubeflow Pipelines created a large amount of RBAC — a good real example of the full
range:

```bash
$ kubectl get clusterrole,clusterrolebinding -l application-crd-id=kubeflow-pipelines
```

Notably the cache-deployer's:

```bash
$ kubectl get clusterrole kubeflow-pipelines-cache-deployer-clusterrole -o yaml
```
```yaml
rules:
  - apiGroups: ["admissionregistration.k8s.io"]
    resources: ["mutatingwebhookconfigurations"]
    verbs: ["create", "delete", "get", "list", "patch"]
  - apiGroups: ["certificates.k8s.io"]
    resources: ["certificatesigningrequests", "certificatesigningrequests/approval"]
    verbs: ["create", "delete", "get", "update"]
  - apiGroups: ["certificates.k8s.io"]
    resources: ["signers"]
    resourceNames: ["kubernetes.io/*"]     # scoped even within a cluster-wide rule
    verbs: ["approve"]
```

This has to be cluster-scoped: `MutatingWebhookConfiguration` is itself a cluster-scoped
resource (no namespace), so nothing narrower than a ClusterRole could grant access to it at all
— unlike the backend's Role above, this isn't a choice of convenience, it's the only option the
resource type allows.

## Checking effective permissions

```bash
kubectl auth can-i get secrets --as=system:serviceaccount:default:backend -n default
kubectl auth can-i list pods --as=system:serviceaccount:default:backend --all-namespaces
kubectl auth can-i '*' '*' --as=system:serviceaccount:kube-system:default   # sanity-check a suspiciously broad SA
```

`kubectl auth can-i` is the fast way to verify a Role/ClusterRole actually grants what you think
it does, without needing to `exec` into a Pod running as that ServiceAccount.

## Quick reference

```bash
kubectl get sa,role,rolebinding -n <namespace>
kubectl get clusterrole,clusterrolebinding
kubectl describe role <name> -n <namespace>
kubectl describe rolebinding <name> -n <namespace>

# who can do X — no built-in single command; auth can-i --list is the closest:
kubectl auth can-i --list --as=system:serviceaccount:<ns>:<sa> -n <ns>
```
