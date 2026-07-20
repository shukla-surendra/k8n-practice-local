# EKS: setup and everything

A practical, soup-to-nuts guide to standing up and running Amazon EKS. Unlike the rest of
`docs/`, this one **isn't verified against a live cluster** — everything else in this repo runs
on a free local minikube profile; EKS costs real money and needs a real AWS account, so nothing
here was actually provisioned. Treat the commands as accurate reference, not "we ran this and
it worked" — and see [Cleanup](#cleanup-cost-control) before you run anything that creates
billable resources.

Cross-references throughout to where this repo's other docs already called out EKS-specific
behavior: [`accessing-pods-and-services.md`](./accessing-pods-and-services.md) (ALB/Ingress),
[`storage-and-persistence.md`](./storage-and-persistence.md) (EBS StorageClass),
[`multiple-services-same-port.md`](./multiple-services-same-port.md) (shared ALB via
IngressGroup), [`rbac.md`](./rbac.md) (Kubernetes-side RBAC — IRSA below is the AWS-side
counterpart).

## What EKS actually is

EKS is AWS running the **control plane** for you (`kube-apiserver`, `etcd`, `kube-scheduler`,
`kube-controller-manager` — see [`cluster-architecture.md`](./cluster-architecture.md)) as a
managed, multi-AZ service you don't see nodes for and can't SSH into. You're responsible for
everything below that line: node provisioning, networking, IAM, add-ons, and everything
namespaced inside the cluster. This split is exactly why local minikube (where *you* run every
layer, in one VM) and EKS diverge on the things this repo's docs kept flagging as
"EKS differs here": StorageClass provisioner, how Ingress gets a real public address, and how
Pods get AWS-level permissions.

## Prerequisites & tooling

| Tool | Purpose |
|---|---|
| An AWS account + IAM permissions | To create the cluster, its IAM roles, VPC resources, etc. — typically `AdministratorAccess` for initial setup, scoped down afterward. |
| `aws` CLI (v2) | Talks to the AWS API; also how `kubectl` gets its auth token for EKS. |
| `eksctl` | The de facto standard CLI for creating/managing EKS clusters — wraps CloudFormation so you don't hand-write VPC/IAM stacks. (Terraform's `aws` + `aws-eks` modules are the other common path, especially once EKS is one of several IaC-managed services — not covered here.) |
| `kubectl` | Same tool you've been using against minikube all along — EKS is a normal Kubernetes API once you're authenticated. |
| `helm` | For the AWS Load Balancer Controller and most other add-ons below. |

```bash
aws configure                 # or: aws configure sso, or environment vars / an assumed role
aws sts get-caller-identity   # confirms which account/identity you're actually using
```

## 1. Networking prerequisites

EKS needs a VPC with subnets across at least two Availability Zones. `eksctl create cluster`
will create one for you if you don't pass `--vpc-*` flags — fine for learning, but production
setups almost always bring their own VPC (to fit existing network topology, peering, on-prem
connectivity via Direct Connect/VPN).

Subnet tagging matters and is a common silent-failure point:

```
kubernetes.io/cluster/<cluster-name> = shared      # required on every subnet EKS/the CNI use
kubernetes.io/role/elb = 1                          # public subnets — needed for public ALB/NLB placement
kubernetes.io/role/internal-elb = 1                 # private subnets — needed for internal LBs
```

Without these tags, the AWS Load Balancer Controller (below) can't auto-discover which subnets
to place a Service's/Ingress's load balancer in, and Ingress creation fails or picks the wrong
subnets.

Public vs. private subnets: nodes are almost always placed in **private** subnets (outbound
internet via a NAT Gateway, no direct inbound), with only the load balancers themselves in
public subnets. `eksctl`'s default cluster template does this correctly out of the box.

## 2. Creating the cluster

### With `eksctl` — config file (recommended over one-liners for anything beyond a demo)

```yaml
# cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: my-cluster
  region: us-east-2
  version: "1.31"

vpc:
  cidr: 10.0.0.0/16
  nat:
    gateway: Single          # HighlyAvailable in prod (one NAT GW per AZ)

managedNodeGroups:
  - name: ng-general
    instanceType: m6i.large
    minSize: 2
    maxSize: 6
    desiredCapacity: 2
    privateNetworking: true
    volumeSize: 50
    labels: {workload: general}
    iam:
      withAddonPolicies:
        ebsCSIController: true    # attaches the IAM policy the EBS CSI driver needs

iam:
  withOIDC: true              # provisions the OIDC provider — required for IRSA, see below

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: aws-ebs-csi-driver
```

```bash
eksctl create cluster -f cluster.yaml       # ~15-20 minutes; creates VPC, IAM roles, node group, control plane
```

Node groups: **managed node groups** (above) are the default choice — AWS handles the
underlying Auto Scaling Group, AMI updates, and graceful draining on upgrade. **Self-managed**
node groups exist for cases needing an AMI/launch-template EKS's managed path doesn't support.
**Fargate profiles** run Pods with no EC2 nodes at all — you pick namespaces/labels to schedule
onto Fargate instead, trading node management entirely for per-Pod billing; DaemonSets don't
work there (there's no persistent node to run one per), so cluster-wide agents typically still
need at least one EC2-backed node group.

### Connecting `kubectl`

```bash
aws eks update-kubeconfig --region us-east-2 --name my-cluster
kubectl get nodes          # same kubectl, same commands as everything else in these docs
```

(This is the exact command already in this repo's notes from
[`kubernetes-fundamentals.md`](./kubernetes-fundamentals.md)'s "Everyday pod ops" section —
worth noting `--profile <aws-profile>` when you're switching between multiple AWS accounts, as
that note does.)

## 3. Core add-ons

EKS ships `vpc-cni`, `coredns`, and `kube-proxy` as **EKS add-ons** — managed lifecycle
(`aws eks update-addon`) instead of something you `kubectl apply` and track yourself:

```bash
aws eks list-addons --cluster-name my-cluster
aws eks create-addon --cluster-name my-cluster --addon-name aws-ebs-csi-driver
aws eks update-addon --cluster-name my-cluster --addon-name vpc-cni --addon-version <version>
```

- **VPC CNI** — the CNI plugin ([`cluster-architecture.md`](./cluster-architecture.md)): gives
  every Pod a real VPC IP (not an overlay network), which is why Pod IPs are directly routable
  and security groups can apply to Pods directly (see IRSA/Pod networking below). Consumes real
  VPC IP addresses per node — a common EKS-specific capacity planning gotcha (`m6i.large`s have
  a fixed max-Pods-per-node based on ENI/IP limits, unrelated to CPU/memory).
- **CoreDNS**, **kube-proxy** — same role as on any cluster, just EKS-managed builds.
- **EBS CSI driver** — required for any `PersistentVolumeClaim`; without it, dynamic
  provisioning via a `gp3`-backed StorageClass (see below) simply hangs with PVCs stuck
  `Pending`.

## 4. IAM Roles for Service Accounts (IRSA) — the AWS-side RBAC layer

[`rbac.md`](./rbac.md) covers Kubernetes RBAC — who can call the Kubernetes API. IRSA is the
separate, AWS-side question: **which Pods can call AWS APIs, and with what permissions.**
Without it, the only options are "every Pod on the node inherits the node's IAM role" (far too
broad — every workload gets every permission any workload needs) or hand-managing AWS
credentials as Secrets (the anti-pattern IRSA exists to remove).

```
ServiceAccount (annotated with an IAM role ARN)
        |  the OIDC provider (from `iam.withOIDC: true` above) lets AWS trust
        |  tokens issued by the EKS cluster itself
        v
Pod using that ServiceAccount gets temporary, scoped AWS credentials
        automatically injected — no static keys anywhere
```

```bash
eksctl create iamserviceaccount \
  --cluster my-cluster \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::<account-id>:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve
```

This is the mechanism the AWS Load Balancer Controller (next section) and EBS CSI driver both
rely on to get exactly the AWS permissions they need, scoped to their own ServiceAccount, and
nothing else. (Newer alternative: **EKS Pod Identity**, a simpler association API replacing
much of IRSA's OIDC-trust-policy boilerplate — same end result, worth using on new clusters.)

## 5. Ingress — AWS Load Balancer Controller

Referenced already in [`accessing-pods-and-services.md`](./accessing-pods-and-services.md):
on EKS, an `Ingress` doesn't route through anything you installed yourself
(like this repo's `ingress-nginx` on minikube) — the **AWS Load Balancer Controller** watches
`Ingress`/`Service` objects and provisions a real ALB (for `Ingress`) or NLB (for
`type: LoadBalancer` Services) via the AWS API.

```bash
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=my-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller   # the IRSA-bound SA from step 4
```

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing        # or "internal"
    alb.ingress.kubernetes.io/target-type: ip                # routes directly to Pod IPs (needs VPC CNI); "instance" routes via NodePort
    alb.ingress.kubernetes.io/group.name: shared-alb          # optional: see below
spec:
  rules: [...]
```

`alb.ingress.kubernetes.io/group.name` is exactly the `IngressGroup` mechanism
[`multiple-services-same-port.md`](./multiple-services-same-port.md) mentioned: multiple
`Ingress` objects — even across namespaces — sharing this same group name get merged onto
**one** physical ALB, each contributing its own host/path rules, instead of one ALB per
Ingress (which is both slower to provision and more expensive).

## 6. Storage

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer   # delays provisioning until a Pod is actually scheduled, so the EBS volume lands in the right AZ
parameters:
  type: gp3
```

This is the class [`storage-and-persistence.md`](./storage-and-persistence.md) already
described as the EKS counterpart to minikube's `standard`/hostpath-provisioner class — a PVC
against this StorageClass provisions a real EBS volume, so `ReclaimPolicy` (`Delete` vs.
`Retain`) is a real decision here in a way it barely was on hostPath-backed minikube storage.
`WaitForFirstConsumer` (vs. minikube's `Immediate`) matters specifically on EKS because EBS
volumes are AZ-local — binding immediately, before the Pod is scheduled, risks provisioning the
volume in an AZ that has no room to schedule the Pod that needs it.

Need a volume multiple Pods can write to concurrently (RWX,
[`storage-and-persistence.md`](./storage-and-persistence.md)'s access-mode table) — EBS can't do
that; use the **EFS CSI driver** instead (`efs.csi.aws.com`), backed by a pre-created EFS
filesystem.

## 7. Autoscaling

Two layers, easy to conflate:

- **HorizontalPodAutoscaler** ([`resource-management.md`](./resource-management.md)) — scales
  replica count within existing node capacity. Identical on EKS and minikube.
- **Node-level autoscaling** — adds/removes EC2 nodes when Pods can't be scheduled (or nodes are
  underused). Two options:
  - **Cluster Autoscaler** — watches for unschedulable Pods, scales the matching managed node
    group's Auto Scaling Group. Mature, works with any node group shape.
  - **Karpenter** — provisions nodes directly (bypassing ASGs), picking instance types/AZs on
    the fly to fit pending Pods exactly, generally faster and more cost-efficient than Cluster
    Autoscaler's fixed node-group shapes. AWS's current recommendation for new clusters.

Neither exists on minikube — there's only ever the one node, so
[`resource-management.md`](./resource-management.md)'s `ResourceQuota`/`LimitRange` discussion
of "one namespace starving the shared cluster" is a much sharper problem locally than on an
autoscaled EKS cluster that can often just add capacity instead.

## 8. Observability

- **CloudWatch Container Insights** — the EKS add-on (`amazon-cloudwatch-observability`) route;
  minimal setup, ships logs/metrics to CloudWatch, reasonable default for teams already living
  in the AWS console.
  ```bash
  aws eks create-addon --cluster-name my-cluster --addon-name amazon-cloudwatch-observability
  ```
- **Prometheus + Grafana** (`kube-prometheus-stack` Helm chart) — the portable, cloud-agnostic
  choice if you want the same stack across EKS and elsewhere, or need PromQL-based alerting
  Container Insights doesn't give you as directly.
- `metrics-server` ([`cluster-architecture.md`](./cluster-architecture.md),
  [`resource-management.md`](./resource-management.md)) still needs to be installed
  separately either way — it's what `kubectl top` and HPA actually read from, and isn't
  included in either of the above by default.

## 9. Security posture, briefly

- **API endpoint access**: public (default), private-only, or both. Private-only means
  `kubectl` only works from inside the VPC (or over VPN/Direct Connect/a bastion) — the
  production-appropriate default once you're past initial setup.
- **Security groups for Pods** — with the VPC CNI (step 3), Pods have real VPC IPs, so you can
  attach security groups directly to specific Pods (`SecurityGroupPolicy`), not just to nodes —
  a finer-grained network boundary than [`network-policies.md`](./network-policies.md)'s
  `NetworkPolicy` objects, which only work if the CNI enforces them at all.
- **Pod Security Standards** (the `PodSecurityStandards` admission controller, or an external
  policy engine like Kyverno/OPA Gatekeeper) — enforce things like "no privileged containers,"
  cluster-wide. Worth pairing with the `securityContext` hardening this repo's own
  `full-stack-app` backend Deployment already does (`runAsNonRoot`, dropped capabilities,
  read-only root filesystem) so it's enforced, not just opted into per-chart.

## Cleanup & cost control

The single most important section if you're actually doing this, not just reading it. An idle
EKS cluster isn't free — the control plane alone is billed hourly, plus every EC2 node, every
NAT Gateway, every provisioned EBS volume, every ALB/NLB.

```bash
eksctl delete cluster -f cluster.yaml
```

`eksctl delete cluster` tears down the CloudFormation stacks it created (VPC, node groups, the
control plane) — but it does **not** reliably clean up resources that *Kubernetes controllers*
created dynamically and AWS/CloudFormation never knew about directly:

- **PersistentVolumes with `ReclaimPolicy: Retain`** — the EBS volume survives on purpose;
  delete manually if you don't want it.
- **ALBs/NLBs created by the AWS Load Balancer Controller** — delete the `Ingress`/
  `LoadBalancer` Service *before* deleting the cluster, so the controller gets a chance to clean
  up its load balancer; if the cluster's gone first, the LB can be orphaned and needs manual
  deletion in the EC2 console.
- **CloudWatch Log Groups** — persist indefinitely by default (no automatic expiry) unless a
  retention policy was set.

## Local (minikube, this repo) vs. EKS — summary

| | minikube (this repo) | EKS |
|---|---|---|
| Control plane | You run it, one node | AWS-managed, multi-AZ |
| Nodes | The same one node | Managed/self-managed node groups, or Fargate |
| CNI | minikube's bundled bridge networking | VPC CNI (real VPC IPs per Pod) |
| StorageClass | `standard`, `k8s.io/minikube-hostpath` | `gp3`/`gp2`, `ebs.csi.aws.com` (+ EFS for RWX) |
| Ingress → real traffic | `ingress-nginx` + NodePort + `kubectl port-forward`/`minikube tunnel` (see [`accessing-pods-and-services.md`](./accessing-pods-and-services.md)) | AWS Load Balancer Controller → real ALB/NLB |
| Pod → cloud-API permissions | N/A | IRSA / EKS Pod Identity |
| Node autoscaling | N/A (fixed one node) | Cluster Autoscaler or Karpenter |
| Cost while idle | Free (local compute) | Billed hourly regardless of load |
