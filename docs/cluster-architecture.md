# Cluster architecture — control plane vs. node components

The split every other concept in these docs sits on top of: a **control plane** that decides
what *should* run, and **nodes** that actually run it. Nothing schedules or runs a container by
directly deciding to — every component watches the API server and reacts.

## Control plane

| Component | Job |
|---|---|
| `kube-apiserver` | The only thing anything talks to. Validates and persists API objects (Pods, Deployments, ...) to etcd; every other component — including `kubectl` — is a client of this. |
| `etcd` | The cluster's entire state, as key-value data. If it's gone, the cluster's desired state is gone (workloads keep running, but nothing can be changed/rescheduled). |
| `kube-scheduler` | Watches for Pods with no Node assigned, picks a Node for each based on resource requests, affinity/taints/etc., and writes that decision back to the API server. It doesn't run anything itself. |
| `kube-controller-manager` | Runs the reconciliation loops — the Deployment controller, ReplicaSet controller, Node controller, Job controller, etc. Each one watches its object type and drives current state toward desired state. This is *why* `kubectl delete pod` under a Deployment gets a replacement: the ReplicaSet controller notices the shortfall and creates one. |
| `cloud-controller-manager` | Cloud-specific glue (only present on managed clusters like EKS) — provisions the ELB/NLB behind a `LoadBalancer` Service, sets Node metadata from the cloud API, etc. Not present on minikube. |

## Node components

| Component | Job |
|---|---|
| `kubelet` | The agent on every node. Watches the API server for Pods assigned to its node, tells the container runtime to start/stop containers accordingly, and reports status (health, resource usage) back. |
| Container runtime (containerd, etc.) | Actually creates/runs containers, via the CRI (see [`kubernetes-fundamentals.md`](./kubernetes-fundamentals.md)). |
| `kube-proxy` | Implements the Service abstraction on each node — programs iptables/IPVS rules so traffic to a Service's ClusterIP gets load-balanced to one of its backing Pods. This is the "how" behind everything in [`multiple-services-same-port.md`](./multiple-services-same-port.md). |
| CNI plugin | Assigns Pod IPs and wires up the pod network (on this cluster: minikube's bundled bridge networking; production clusters commonly run Calico, Cilium, or the AWS VPC CNI on EKS). Whether `NetworkPolicy` objects are actually enforced ([`network-policies.md`](./network-policies.md)) depends entirely on which CNI is installed. |

## On this cluster

```
$ kubectl get nodes
NAME        STATUS   ROLES           AGE   VERSION
fullstack   Ready    control-plane   16d   v1.34.0
```

Single-node minikube: `fullstack` runs **both** the control plane and the node components
(all of `kube-apiserver`, `etcd`, `kube-scheduler`, `kube-controller-manager`, plus `kubelet`,
`kube-proxy`, and containerd) in one VM/container. Real clusters (including EKS) separate these
— a managed control plane you don't see nodes for, and a node group you scale independently.

```
$ kubectl get pods -n kube-system
coredns-...                       # cluster DNS — resolves Service names (svc-a.default.svc.cluster.local)
etcd-fullstack                    # control plane state store
kube-apiserver-fullstack
kube-controller-manager-fullstack
kube-scheduler-fullstack
kube-proxy-...
storage-provisioner                # minikube-specific: backs the `standard` StorageClass with hostPath volumes
metrics-server-...                 # powers `kubectl top` and HorizontalPodAutoscaler
```

## The pattern behind everything else in these docs

Every resource type (Deployment, Job, Ingress, InferenceService, ...) follows the same loop:

```
you (kubectl apply) -> kube-apiserver -> etcd
                              |
                    a controller notices (watch)
                              |
                  it reconciles: creates/updates/deletes
                     the objects it's responsible for
                              |
                    kube-scheduler assigns Pods to Nodes
                              |
                       kubelet on that Node
                    starts the actual containers
```

This is why [`multiple-services-same-port.md`](./multiple-services-same-port.md)'s NodePort
example fails at the API server (a validation rule on the object, before anything is
scheduled), while a `hostPort` conflict fails at the kubelet (only discovered when it tries to
actually bind the port on that node) — different components, different point of failure.
