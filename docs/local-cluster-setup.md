# Local Kubernetes clusters on macOS

Every "local cluster" tool does the same fundamental thing: run a full control plane
(`kube-apiserver`, `etcd`, `kube-scheduler`, `kube-controller-manager`) plus a node
(`kubelet`, `kube-proxy`, a container runtime, a CNI) on your laptop, usually all packed onto
a single node. See [`cluster-architecture.md`](./cluster-architecture.md) for what each of
those pieces actually does — this doc is about the packaging options around them, not the
components themselves.

## Options on macOS

| Option | What it runs | Isolation | Multi-cluster | Notes |
|---|---|---|---|---|
| **minikube** | Full k8s in a VM (or container) | VM (vfkit/hyperkit) or Docker container, per **profile** | Yes — one profile per cluster | What this repo uses. Most addon/config flexibility (`minikube addons enable ...`). |
| **Docker Desktop Kubernetes** | Full k8s inside Docker Desktop's own VM | Shares Docker Desktop's VM | No — one cluster, on/off toggle | Zero extra install if you already run Docker Desktop. No addon system; upgrades tied to Docker Desktop releases. |
| **kind** ("Kubernetes in Docker") | Each node is a Docker container | Docker containers | Yes — `kind create cluster --name X` | Fast to create/destroy, good for CI-like throwaway clusters and testing multi-node topologies. Not installed on this machine. |
| **k3d** (k3s in Docker) | [k3s](https://k3s.io) (lightweight k8s distro) in Docker containers | Docker containers | Yes | Lowest resource footprint, fastest startup. k3s swaps some components (e.g. no etcd by default — uses sqlite). Not installed on this machine. |

### What's actually on this machine

```
$ which minikube kind k3d
/usr/local/bin/minikube        # installed
kind not found
k3d not found

$ docker context ls → Docker Desktop is running (desktop-linux context)
$ Docker Desktop Kubernetes: disabled (KubernetesEnabled: false)

$ minikube profile list
PROFILE     DRIVER  STATUS
fullstack   docker  (container removed — profile exists but not runnable until recreated)
minikube    vfkit   OK (this repo's cluster)

$ uname -m
arm64   # Apple Silicon — vfkit is minikube's native driver here; hyperkit/virtualbox don't support arm64
```

So: only minikube is actually usable right now, via the `minikube` profile. The `fullstack`
profile is a second minikube cluster whose backing Docker container was removed at some point
— `minikube start -p fullstack` recreates it (see below). Docker Desktop Kubernetes is
installed but switched off.

## Setting each one up

### minikube (what this repo uses)

```bash
brew install minikube

# Apple Silicon: vfkit is the modern native driver (replaces hyperkit)
minikube start --driver=vfkit                    # default profile, named "minikube"
minikube start -p fullstack --driver=docker       # a second, independent cluster ("profile")

minikube status -p fullstack
minikube addons list                              # ingress, metrics-server, storage-provisioner, etc.
minikube addons enable ingress -p fullstack
minikube delete -p fullstack                      # tear a profile down completely
```

Each profile is a fully independent cluster with its own kubeconfig context, control plane,
and addons — that's how this repo ended up with two (`minikube` running Kubeflow/Istio/Knative,
`fullstack` running Kargo/KServe).

### Docker Desktop Kubernetes

No install — it ships with Docker Desktop.

1. Docker Desktop → Settings → Kubernetes → check **Enable Kubernetes**.
2. You're asked to pick a **provisioner**: `kind` or `kubeadm` (see below) → Apply & Restart.
3. It provisions a cluster inside Docker Desktop's existing VM and adds a `docker-desktop`
   context to your kubeconfig automatically — same context name regardless of which
   provisioner you pick.
4. Disabling it later removes the cluster and its context entry.

Simplest option if you just want *a* cluster and don't need minikube-style addons or multiple
clusters.

#### `kind` vs `kubeadm` — the provisioner choice

This is a choice about *how Docker Desktop builds the one cluster it gives you*, not two
different products. Both existed before Docker Desktop offered either — `kubeadm` is the same
tool real clusters (and kOps, RKE, etc.) use to bootstrap a control plane onto a machine;
`kind` ("Kubernetes IN Docker") normally builds standalone clusters where every "node" is a
Docker container, and Docker Desktop reuses it here as an alternate way to build *its* single
cluster.

| | `kubeadm` | `kind` |
|---|---|---|
| **How the node is built** | Control plane + kubelet run directly inside Docker Desktop's Linux VM (the classic approach — same mechanism EKS/kubeadm-based clusters use, minus the VM being cloud-managed) | The "node" is itself a Docker container running inside Docker Desktop's VM — an extra layer of containerization |
| **Node count** | Single node only | Multi-node — you can provision several worker "nodes" (each a container) for realistic scheduling/affinity testing |
| **k8s version** | Fixed — whatever version ships with your Docker Desktop release | Selectable — pick the version (and node count) yourself |
| **Provisioning time** | ~1 minute | ~30 seconds |
| **Locally-built images** | Directly usable — `docker build` output is visible to the cluster immediately, no push/load step | **Not** visible the same way when using the containerd image store — you'd need `kind load docker-image` semantics; this is the main practical regression vs. kubeadm mode |
| **Enhanced Container Isolation (ECI)** | Not supported | Supported — cluster runs in unprivileged containers, extra sandboxing |
| **Status** | Legacy, still available | Default provisioner as of Docker Desktop 4.38+ |

On this machine, `~/Library/Group Containers/group.com.docker/settings-store.json` currently
shows `"KubernetesMode": "kubeadm"` (and `"KubernetesEnabled": false` — it's off). If you
picked between the two in the Docker Desktop dialog and haven't hit Apply yet, that's the
existing setting it's asking you to change.

**Which to pick**: `kind` unless you specifically rely on running `docker build` output
straight into the cluster without pushing/loading it anywhere — that one workflow is the
clearest reason to stay on `kubeadm`. For everything else (multi-node testing, faster
resets, version pinning, ECI), `kind` is the more capable and now-default option.

### kind

```bash
brew install kind

kind create cluster --name playground
kind create cluster --name multi --config kind-multi-node.yaml   # simulate multiple nodes
kind get clusters
kind delete cluster --name playground
```

`kind` is the best fit for testing something that behaves differently across multiple nodes
(scheduling, affinity/anti-affinity, DaemonSets) since a single `kind` cluster can have several
node containers, unlike minikube's single-node-by-default model.

### k3d

```bash
brew install k3d

k3d cluster create playground
k3d cluster list
k3d cluster delete playground
```

Fastest to start, lightest on resources — good for quick smoke tests where you don't need the
full addon ecosystem minikube gives you.

## Understanding `kubectl` context

A **context** is not a cluster. It's a named pointer that binds three separate things
together, all of which live independently in `~/.kube/config`:

```
context = (cluster, user, namespace)
             |        |       |
             |        |       +-- default -n for commands run under this context
             |        +-- credentials to authenticate as (cert, token, exec plugin, ...)
             +-- server URL + CA cert to talk to
```

`kubectl` doesn't "know" clusters directly — every command resolves `current-context` to a
`(cluster, user, namespace)` triple, then talks to `cluster.server` authenticating as `user`.
That indirection is the whole point: it's what lets one `kubectl` binary and one config file
drive any number of unrelated clusters without you re-typing certs and URLs each time.

### The anatomy, with this machine's real config

`kubectl config view` shows the merged file (secrets redacted). Right now, on this machine:

```yaml
clusters:
- name: docker-desktop
  cluster: {server: https://127.0.0.1:6443, certificate-authority-data: DATA+OMITTED}
- name: minikube
  cluster: {server: https://192.168.64.2:8443, certificate-authority: ~/.minikube/ca.crt}

users:
- name: docker-desktop
  user: {client-certificate-data: DATA+OMITTED, client-key-data: DATA+OMITTED}
- name: minikube
  user: {client-certificate: ~/.minikube/profiles/minikube/client.crt, client-key: ...}

contexts:
- name: docker-desktop
  context: {cluster: docker-desktop, user: docker-desktop}
- name: minikube
  context: {cluster: minikube, user: minikube}

current-context: minikube
```

Three top-level lists (`clusters`, `users`, `contexts`) plus one string (`current-context`).
A context is just a `name` that glues one entry from each list together — nothing more. This
is why you can have the same cluster under two different users (e.g. an admin cert vs. a
scoped ServiceAccount token), or the same user talking to two different clusters, all as
distinct contexts.

### Everyday commands

```bash
kubectl config get-contexts                   # list every context, * = current
kubectl config current-context

kubectl config use-context minikube            # switch — changes current-context, nothing else
kubectl config use-context docker-desktop

# One-off command against a non-current context, without switching anything:
kubectl --context=minikube get pods -A

# Per-context default namespace, so you don't need -n every time:
kubectl config set-context minikube --namespace=kubeflow
kubectl config set-context --current --namespace=default   # same thing, targeting "whichever is current"

# Rename / delete a context (does NOT touch the cluster or delete any workload):
kubectl config rename-context old-name new-name
kubectl config delete-context old-name
```

`use-context` only ever edits the `current-context` string in the file. It does not check the
cluster is reachable, does not start anything, does not validate credentials — it's a pure
local pointer change. That's *why* it's cheap to switch constantly, but also why "wrong
context" is a silent failure mode: `kubectl get pods` after a bad switch doesn't say "this
context is stale," it just times out or 404s against whatever the pointer happens to resolve
to.

### Worked example: a context that silently went stale (this machine, today)

This actually happened while working on this repo, and it's the clearest illustration of why
context ≠ cluster:

```bash
$ kubectl config get-contexts
CURRENT   NAME             CLUSTER          AUTHINFO         NAMESPACE
*         docker-desktop   docker-desktop   docker-desktop
```

Only one context left — `minikube` and `fullstack` had been wiped from `~/.kube/config`
(during a manual cleanup), and `current-context` was left pointing at `docker-desktop`, whose
Kubernetes is disabled in Docker Desktop settings. So `kubectl get nodes` failed with a
connection error — not because any cluster was actually broken, but because the *pointer*
was bad.

```bash
$ minikube profile list
PROFILE     STATUS   ACTIVE KUBECONTEXT
fullstack            (container removed — cluster itself is gone, needs recreating)
minikube    OK        (blank — VM is up and healthy, just has no context anymore)
```

The `minikube` VM was running the whole time — `minikube status` said `OK`. The cluster never
went away; only its kubeconfig entry did. That split (context missing vs. cluster missing) is
exactly why you check both independently when something doesn't connect. Fix, since the VM was
fine:

```bash
$ minikube update-context -p minikube
* "minikube" context has been updated to point to 192.168.64.2:8443
* Current context is "minikube"

$ kubectl config get-contexts
CURRENT   NAME       CLUSTER     AUTHINFO    NAMESPACE
*         minikube   minikube    minikube
```

One command regenerated the `cluster`/`user`/`context` triple for that profile from what
minikube itself knows on disk. `fullstack`, by contrast, needs `minikube start -p fullstack`
first — its underlying container is genuinely gone, not just its kubeconfig entry, so there's
no state left to point a context *at*.

### Before running anything destructive: verify, don't assume

Given the above, treat `current-context` as untrusted until checked, especially before
`delete`/`apply` on anything you didn't just explicitly target:

```bash
kubectl config current-context                        # which context
kubectl config view --minify -o jsonpath='{..server}'  # which literal server URL it resolves to
kubectl cluster-info                                    # does it actually respond
kubectl get nodes                                        # and does it look like the cluster you think it is
```

`--minify` scopes `config view` to just the current context's cluster/user (instead of
dumping everything), which is the fast way to answer "what am I actually about to hit."

### Multiple kubeconfig files

Tools that provision clusters (`minikube`, cloud CLIs, CI) often write their *own* kubeconfig
file rather than editing `~/.kube/config` directly. `KUBECONFIG` controls which files
`kubectl` merges together (colon-separated on macOS/Linux):

```bash
echo $KUBECONFIG                                # empty = just ~/.kube/config
export KUBECONFIG=~/.kube/config:~/Downloads/some-cluster.yaml
kubectl config view --flatten > ~/.kube/config  # merge everything into one file permanently
```

Useful when e.g. `eksctl`/`aws eks update-kubeconfig` (see [`eks-setup.md`](./eks-setup.md))
hands you a cluster's config separately and you want it alongside your local ones instead of
juggling `--kubeconfig` flags.

### A faster daily driver

For frequent switching, [`kubectx`](https://github.com/ahmetb/kubectx)
(`brew install kubectx`) wraps the same file — `kubectx <name>` for context,
`kubens <namespace>` for the namespace half of the same problem, `kubectx -` to hop back to the
previous context (like `cd -`).

## Picking one

- **Default for this repo**: minikube — already in use, addon system covers ingress/metrics/
  storage out of the box, profiles give clean isolation between unrelated experiments
  (this repo's `minikube` profile for the Kubeflow/Istio/Knative stack, `fullstack` for
  Kargo/KServe).
- **Want zero extra install and only ever need one cluster**: Docker Desktop Kubernetes.
- **Testing multi-node behavior specifically**: kind.
- **Want the fastest possible spin-up/teardown for a throwaway check**: k3d.
