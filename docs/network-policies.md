# NetworkPolicy

Controls **Pod-to-Pod network traffic** — the counterpart to [RBAC](./rbac.md), which controls
API access. A NetworkPolicy has no opinion on who can call `kubectl`; RBAC has no opinion on
whether Pod A can open a TCP connection to Pod B. Grounded in `full-stack-app`'s three-tier
policy set.

## Default: everything can talk to everything

With no NetworkPolicy objects in a namespace, every Pod can reach every other Pod (in any
namespace) on any port — Kubernetes' network model is flat and fully open by default.
NetworkPolicy is exclusively **allow-list**: as soon as *any* policy selects a Pod for a given
direction (ingress/egress), that direction becomes deny-by-default for that Pod, and only
traffic matching some policy's rules is permitted. A Pod matched by zero policies stays fully
open.

## The three-tier example

```yaml
# full-stack-app/templates/networkpolicy.yaml — frontend
spec:
  podSelector: {matchLabels: {app.kubernetes.io/name: frontend, ...}}
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - {}                                    # allow from anywhere
  egress:
    - to: [{podSelector: {matchLabels: {app.kubernetes.io/name: backend, ...}}}]
      ports: [{protocol: TCP, port: 8080}]  # only to backend, on its port
    - ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]   # DNS
```

```yaml
# backend
ingress:
  - from: [{podSelector: {matchLabels: {app.kubernetes.io/name: frontend, ...}}}]
    ports: [{protocol: TCP, port: 8080}]
egress:
  - to: [{podSelector: {matchLabels: {app.kubernetes.io/name: database, ...}}}]
    ports: [{protocol: TCP, port: 5432}]
  - ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]   # DNS
```

```yaml
# database — ingress only, no egress rule at all (doesn't need to call out)
ingress:
  - from:
      - podSelector: {matchLabels: {app.kubernetes.io/name: backend, ...}}
      - podSelector: {matchLabels: {app.kubernetes.io/name: db-job, ...}}  # migration/backup Jobs
    ports: [{protocol: TCP, port: 5432}]
```

This enforces the same shape as the [RBAC](./rbac.md) example enforces for API access, but at
the network layer: `frontend` is reachable from anywhere (it's the entry point) but can only
call `backend` (+ DNS); `backend` is only reachable from `frontend`, and can only call
`database` (+ DNS); `database` is only reachable from `backend` and the migration/backup Jobs
(matched via the shared `db-job` label — see [`workload-types.md`](./workload-types.md)), and
has no `egress` block at all — it never needs to initiate outbound connections.

**The DNS egress rule in both `frontend` and `backend` is not optional decoration** — once a
Pod is selected by a policy with an `egress` section, *all* outbound traffic is denied except
what's explicitly allowed, including DNS lookups to CoreDNS. Forgetting the DNS rule is the
single most common NetworkPolicy mistake: the app can't resolve any hostname, including the
Service names the other rules were written to allow.

## The catch: enforcement depends on the CNI

A NetworkPolicy object always creates successfully regardless of the cluster — the API server
doesn't know or care whether anything will actually enforce it. Whether it does anything is
entirely down to the **CNI plugin**:

- Calico, Cilium, the AWS VPC CNI (with `ENABLE_NETWORK_POLICY=true` on EKS), and several others
  implement `NetworkPolicy`.
- Plain bridge networking (minikube's default CNI) does **not** — the chart's own comment flags
  this: *"Enforcement depends on the cluster's CNI plugin supporting NetworkPolicy (e.g. minikube
  `--cni=calico`). On plugins that don't enforce it, these objects still create fine — they're
  just advisory."*

Practical implication: `kubectl get networkpolicy` returning objects is not evidence that
traffic is actually being restricted — always check what CNI a cluster runs before treating a
NetworkPolicy as a real security boundary. On EKS specifically, this is opt-in and easy to miss
enabling.

## Quick reference

```bash
kubectl get networkpolicy -n <namespace>
kubectl describe networkpolicy <name> -n <namespace>

# check the CNI in use:
kubectl get pods -n kube-system -o wide | grep -iE 'calico|cilium|aws-node|weave|flannel'
```
