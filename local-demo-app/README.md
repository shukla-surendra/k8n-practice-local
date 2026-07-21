# local-demo-app

Minimal app for practicing the "build a local Docker image, run it as a pod" loop, without a
registry. A tiny Python HTTP server (stdlib only, no `pip install`) that logs every request to
stdout — so it also doubles as a live log source for
[`grafana-log-viewer`](../grafana-log-viewer), same pipeline as `sample-nginx`.

## Where this is installed

- **Cluster:** `minikube` profile
- **Namespace:** `default`
- **Method:** raw manifests (`kubectl apply -f deployment.yaml`), image built directly inside
  minikube's own Docker daemon — no registry involved at any point

## Why `imagePullPolicy: Never`

Kubernetes' default (`IfNotPresent`/`Always` depending on tag) tries to **pull** an image from
a registry before falling back to a local one — for an image that only exists locally and was
never pushed anywhere, that pull attempt fails (`ErrImagePull`/`ImagePullBackOff`). Since this
image is never going to exist in a registry, `deployment.yaml` sets `imagePullPolicy: Never`
so the kubelet only ever looks at what the node's container runtime already has.

## Build — inside minikube's own Docker daemon

### In plain terms

Your Mac and the `minikube` cluster are, for this purpose, **two separate computers** — your
Mac runs Docker Desktop with its own private stash of images; `minikube` is a little virtual
machine with a completely separate, empty stash of its own. Kubernetes, running inside that
VM, can only ever use images from *that VM's* stash — it has no way to reach over and grab one
off your Mac, the same way your kitchen can't just borrow eggs from a stranger's fridge across
town without someone physically bringing them over.

Think of `docker build` as "cook a dish using whichever kitchen `docker` is currently pointed
at." Normally `docker` is pointed at your Mac's kitchen (Docker Desktop) — you cook there, the
dish sits in your Mac's fridge, and `minikube`'s kitchen never sees it.

`eval $(minikube docker-env)` doesn't carry a dish anywhere. It's a remote control that
re-points your terminal's `docker` command at **minikube's kitchen instead of your Mac's**, for
the rest of that terminal session. So when we then ran `docker build`, we weren't cooking on
your Mac at all — we were, from your terminal, operating minikube's stove directly. The
finished dish (the image) came out sitting in minikube's fridge, because that's the kitchen
that did the cooking. It was never on your Mac to begin with — there was nothing to move.

### Mechanically, what `docker` is actually doing

`docker` (the command you type) has no daemon of its own — it's just a client that sends
instructions to whatever daemon `$DOCKER_HOST` points at, over the network if needed:

```
Normal `docker build`:
  your shell → DOCKER_HOST unset → talks to your Mac's Docker Desktop daemon (over a local socket)
             → image built and stored on your Mac

`eval $(minikube docker-env)` + `docker build` (what we did):
  your shell → DOCKER_HOST=tcp://192.168.64.2:2376 → talks to the daemon INSIDE the minikube VM
             → image built and stored inside the VM, never touches your Mac's Docker Desktop
```

`minikube docker-env` just prints the `export DOCKER_HOST=...` (plus matching TLS cert vars)
that make that redirect happen. Nothing is copied anywhere — the build itself physically ran
on the other "computer."

**Proof it never touched your Mac's normal Docker Desktop** — compare the same image lookup
against each daemon:

```bash
$ env -u DOCKER_HOST -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH docker images | grep local-demo-app
(nothing — your Mac's own Docker Desktop has never heard of this image)

$ eval $(minikube docker-env) && docker images | grep local-demo-app
local-demo-app   latest   0aa52926e873   144MB   # only exists here
```

### Commands

```bash
eval $(minikube docker-env)      # this shell only — doesn't persist to new terminals
cd local-demo-app
docker build -t local-demo-app:latest .
```

Verify it landed where the cluster can actually see it — `minikube image ls` asks the cluster's
own container runtime directly, rather than trusting whichever daemon your shell's `docker`
happens to be pointed at right now:

```bash
minikube image ls | grep local-demo-app
```

`eval $(minikube docker-env)` only affects the current shell session — open a new terminal (or
run `eval $(minikube docker-env -u)` to undo it) to go back to your normal Docker Desktop
daemon for anything else.

### Alternative: build normally, then load explicitly

The other option, in the same kitchen analogy: cook normally in your Mac's kitchen (Docker
Desktop), then physically carry the finished dish over to minikube's fridge afterward, instead
of cooking in minikube's kitchen to begin with. Useful if you'd rather not redirect your
shell's Docker daemon (e.g. other tools in the same session expect Docker Desktop):

```bash
docker build -t local-demo-app:latest .
minikube image load local-demo-app:latest
```

Slower (image gets serialized and copied into the VM) but doesn't touch your shell's `DOCKER_HOST`.

## Deploy

```bash
kubectl apply -f deployment.yaml
kubectl get pods -l app=local-demo-app
```

`Running` immediately (no `ImagePullBackOff`) confirms the local image was actually found by
the node's runtime.

## Verify

```bash
kubectl run curl-test --image=curlimages/curl --rm -i --restart=Never -- \
  curl -s http://local-demo-app.default.svc.cluster.local/
kubectl logs -l app=local-demo-app --tail=5
```

Then confirm the log actually reached Loki (see
[`docs/incidents.md`](../docs/incidents.md) for why this is worth checking directly rather than
assuming the pipeline works):

```bash
kubectl exec -n log-viewer log-viewer-loki-0 -- wget -qO- \
  'http://localhost:3100/loki/api/v1/query_range?query=%7Bapp%3D%22local-demo-app%22%7D&limit=3'
```

Or in Grafana: **Explore** → Loki → `{app="local-demo-app"}`.

## After changing `app.py`

No new file, no version bump needed for local iteration — rebuild the same tag and roll the
Deployment (`:latest` + `imagePullPolicy: Never` means Kubernetes won't know the image content
changed on its own, since the tag is identical):

```bash
eval $(minikube docker-env)
docker build -t local-demo-app:latest .
kubectl rollout restart deployment/local-demo-app
```

## Cleanup

```bash
kubectl delete -f deployment.yaml
eval $(minikube docker-env)
docker rmi local-demo-app:latest
```
