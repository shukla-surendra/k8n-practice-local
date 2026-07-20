# Kubernetes fundamentals — container runtimes, Pods, Deployments, ReplicaSets

Working notes from initial Kubernetes learning, cleaned up and organized by topic.

## Container runtimes & CRI

Kubernetes was originally built around Docker specifically. It now talks to any container
runtime through the **CRI (Container Runtime Interface)** — a gRPC API (`imagespec` +
`runtimespec`) that any runtime can implement as long as it follows the **OCI (Open Container
Initiative)** spec.

- **containerd** — the runtime actually used under the hood today. Docker itself runs on
  containerd; Kubernetes used to talk to Docker via a shim (`dockershim`), which was removed
  in 1.24 — kubelet now talks to containerd (or another CRI runtime) directly.
- **rkt** ("rocket") — an early CoreOS-built alternative to Docker, focused on security and
  OCI adherence. Largely historical at this point; mentioned here because CRI's design was
  partly shaped by supporting both Docker and rkt.

### Runtime CLIs

| Tool | Purpose |
|---|---|
| `nerdctl` | Docker-CLI-compatible client for containerd — closest thing to a drop-in `docker` replacement |
| `ctl` (`ctr`) | containerd's bundled low-level CLI — minimal, not meant for production use |
| `crictl` | CRI-native CLI (installed separately) for inspecting/debugging containers across *any* CRI runtime — for debugging, not for creating containers |

## Local cluster setup

```bash
# prerequisites: kubectl, minikube installed
minikube start --driver=docker
kubectl get nodes                    # minikube provisions a single node

kubectl create deployment hello-minikube --image=k8s.gcr.io/echoserver:1.10
kubectl get deployments
kubectl expose deployment hello-minikube --type=NodePort --port=8080

kubectl delete service hello-minikube
kubectl delete deployment hello-minikube
```

Quick imperative pod commands:

```bash
kubectl run nginx --image nginx        # creates a pod named "nginx"
kubectl describe pod nginx             # full detail: events, image, node, state
kubectl get pod nginx -o wide          # includes node/IP in table form
kubectl delete pod nginx
```

## Pod vs Deployment vs ReplicaSet

### Pod

- The smallest deployable unit in Kubernetes.
- Usually one container, but can run multiple tightly-coupled containers sharing network
  (same IP/port space) and storage (shared volumes).
- **Ephemeral** — if a pod dies, nothing recreates it unless something else (Deployment,
  ReplicaSet, Job) is managing it.
- Best used for single instances, debugging, or one-off testing — rarely created bare in
  production.

### ReplicationController vs ReplicaSet

Both exist to keep a fixed number of pod replicas running; ReplicaSet is the modern
replacement.

| | ReplicationController (RC) | ReplicaSet (RS) |
|---|---|---|
| Selector | Equality-based only | Equality-based **and** set-based (more flexible) |
| Status | Legacy | Recommended; introduced in Kubernetes 1.2+ |
| Works with Deployment | No | Yes — Deployments manage ReplicaSets for rolling updates |

**API version rule of thumb:** core-group resources (`Pod`, `Service`) use just `v1`; named-group
resources use `<group>/<version>` — e.g. `apps/v1` for Deployment/ReplicaSet, `batch/v1` for Job.

### Deployment

- Higher-level abstraction that manages ReplicaSets (which in turn manage Pods).
- Declares desired replica count, container image/version, and update strategy (rolling
  update, rollback).
- Guarantees pods are recreated on failure and the desired count is always met.
- The default choice for stateless workloads (web servers, APIs) — you almost never create
  bare Pods or ReplicaSets directly in production, you create a Deployment (or StatefulSet /
  DaemonSet for stateful or per-node workloads) and let it manage the rest.

**Analogy:** a Pod is one worker; a Deployment is the manager making sure the right number of
workers are always present, replacing them when they fail.

## Working with Pods and Deployments

```bash
kubectl get pods
kubectl get deployments

kubectl delete deployment <deployment_name>   # deletes the deployment AND all its pods
kubectl delete pod <pod_name>                 # deletes just that pod — if it's owned by a
                                               # Deployment/ReplicaSet, a replacement is created
```

Creating from a manifest:

```bash
kubectl apply -f pod-definition.yaml
kubectl get pods
```

**Gotcha:** `kubectl edit pod <name>` opens the live object in an editor, but edits to most
Pod fields (e.g. `image`) don't actually take effect — most Pod spec fields are immutable
after creation. If you're managing the pod from a YAML file, edit the **file** and
`kubectl apply -f` it instead; for a bare Pod with an immutable field, delete and recreate.

Useful shortcut for generating a manifest instead of hand-writing one:

```bash
kubectl run redis --image=redis123 --dry-run=client -o yaml > redis-definition.yaml
```

## ReplicaSet

```yaml
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: my-replicaset
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapp
  template:              # pod template — required if the RS needs to create pods
    metadata:
      labels:
        app: myapp
    spec:
      containers:
      - name: mycontainer
        image: nginx:latest
        ports:
        - containerPort: 80
```

Key behavior:

- `selector` determines which pods the ReplicaSet controls — it can adopt existing pods
  created outside the ReplicaSet, as long as their labels match.
- If enough matching pods already exist, the ReplicaSet won't create new ones. It only uses
  `template` when it needs to make up a shortfall (a pod failed or was deleted).
- Effectively: **always provide a pod template**, unless you intend the ReplicaSet to only
  ever manage pods that already exist.

### Scaling

```bash
# 1. Manual, imperative
kubectl scale replicaset my-replicaset --replicas=5

# 2. Manual, interactive
kubectl edit replicaset my-replicaset      # change spec.replicas, save

# 3. Declarative — edit the YAML's replicas field, then:
kubectl apply -f replicaset.yaml

# 4. Automatic — Horizontal Pod Autoscaler, based on CPU/memory or custom metrics
kubectl autoscale rs my-replicaset --min=2 --max=10 --cpu-percent=50
```

### Command reference

```bash
kubectl apply -f replicaset.yaml                # create/update
kubectl get rs                                  # list (alias: kubectl get replicaset)
kubectl describe rs <name>                      # detail: pods, selector, events, status
kubectl get rs <name> -o yaml                   # full config
kubectl get pods --selector=app=myapp           # pods managed by a given selector

kubectl edit rs <name>                          # live edit
kubectl delete rs <name>                        # deletes the RS and its pods
kubectl delete rs <name> --cascade=orphan        # deletes the RS, keeps the pods running
```

## Everyday pod ops (incl. remote/EKS clusters)

```bash
kubectl get pods -n <namespace>
kubectl logs <pod-name> -n <namespace>
kubectl delete pod <pod-name> -n <namespace>

# switching kubectl context to a remote EKS cluster
aws eks update-kubeconfig --region <region> --name <cluster-name> --profile <aws-profile>
```
