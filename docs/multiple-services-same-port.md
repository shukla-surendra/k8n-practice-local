# Multiple Services on the same port (e.g. three services all on 8080)

Short answer: **this is completely normal and doesn't conflict.** Every `Service` gets its own
cluster-internal IP, so reusing port `8080` across many Services is no different from three
unrelated web servers on three different machines each listening on port `8080` — the IP makes
them distinct, the port number is just "which door on that address."

The confusion usually comes from thinking of ports the way an OS thinks of them (one process per
port per host). Kubernetes has an extra layer of addressing — the Service's own ClusterIP — that
means "port" alone is never the whole address.

## Why it doesn't conflict: verified live

Deployed three independent apps, each a `Deployment` + `Service`, every one listening on
`8080` ([`docs/examples/same-port-services.yaml`](./examples/same-port-services.yaml)):

```bash
kubectl apply -f docs/examples/same-port-services.yaml --validate=false
```

```
NAME    TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
svc-a   ClusterIP   10.102.235.60   <none>        8080/TCP   3m
svc-b   ClusterIP   10.101.44.254   <none>        8080/TCP   3m
svc-c   ClusterIP   10.107.90.167   <none>        8080/TCP   3m
```

Three different ClusterIPs, same port. Each is independently reachable by its Service DNS name
from any pod in the cluster:

```bash
$ kubectl exec curl-test -- curl -s http://svc-a:8080/
response from svc-a
$ kubectl exec curl-test -- curl -s http://svc-b:8080/
response from svc-b
$ kubectl exec curl-test -- curl -s http://svc-c:8080/
response from svc-c
```

No port clash, because nothing ever actually shares an address:

- **Pods** each get their own network namespace and IP (from the pod CIDR) — a container
  listening on `8080` inside Pod A and a container listening on `8080` inside Pod B are on two
  different IPs. Same as two containers on two different hosts.
- **Services** each get their own ClusterIP (from the Service CIDR) — `svc-a:8080`,
  `svc-b:8080`, `svc-c:8080` are three distinct `IP:port` pairs as far as the network (and
  `kube-proxy`'s iptables/IPVS rules) are concerned.
- **DNS** gives each Service a stable name (`<service>.<namespace>.svc.cluster.local`, or just
  `<service>` from within the same namespace) — clients address services by name, never by
  reusing a bare port number.

`spec.ports[].port` (the Service's own port) and `spec.ports[].targetPort` (the container port
it forwards to) are also independent — a Service can expose `8080` while forwarding to a
container listening on a completely different port, or vice versa. Reusing `8080` as
`targetPort` across many unrelated Services is exactly as safe as reusing it as `port`.

## Where port reuse *does* actually conflict

The abstraction breaks down exactly where two things are forced onto the **same** IP:

### 1. Two containers in the *same* Pod

Containers in one Pod share the Pod's network namespace — i.e. share one IP. Two containers in
the same Pod both trying to listen on `8080` is a real conflict (whichever binds second fails at
the OS level) — Kubernetes doesn't validate this for you; the container just crashes/fails to
start. Fix: give each container its own `containerPort` inside the Pod.

### 2. `hostPort` / `hostNetwork: true`

Setting `hostPort: 8080` (or `hostNetwork: true` and listening on 8080) binds directly to the
**node's** IP, bypassing the Pod-IP abstraction entirely. Only one Pod per node can hold that
port — a second Pod requesting the same `hostPort` on the same node fails to schedule. This is
rarely what you want; it exists mainly for node-level agents (log shippers, CNI components),
not regular app Services.

### 3. Explicit `NodePort` collisions

A `NodePort` Service opens the same port on **every node's** IP — so, unlike ClusterIP, a
NodePort must be unique across the whole cluster. If you pin an explicit `nodePort` instead of
letting Kubernetes allocate one from the default range (`30000-32767`), a second Service
claiming the same value is rejected outright — reproduced live:

```bash
$ kubectl expose deployment svc-a --type=NodePort --port=8080 \
    --overrides='{"spec":{"ports":[{"port":8080,"targetPort":8080,"nodePort":30080}]}}'
service/svc-a-nodeport exposed

$ kubectl expose deployment svc-b --type=NodePort --port=8080 \
    --overrides='{"spec":{"ports":[{"port":8080,"targetPort":8080,"nodePort":30080}]}}'
The Service "svc-b-nodeport" is invalid: spec.ports[0].nodePort: Invalid value: 30080:
provided port is already allocated
```

The API server rejects it at creation time — this is the one case in this doc that's a hard
error rather than just "surprising behavior." In practice you rarely set `nodePort` explicitly;
letting Kubernetes auto-assign one avoids this entirely, and NodePort itself is a local/dev
mechanism anyway (see [`accessing-pods-and-services.md`](./accessing-pods-and-services.md)) —
production traffic goes through a `LoadBalancer` Service or `Ingress`, neither of which have
this problem.

### 4. Exposing all three externally through one entry point

This is the other half of "3 services all on 8080" — getting to them from *outside* the
cluster without opening three different NodePorts or LoadBalancers. An `Ingress` multiplexes
many backend Services (each still just using its own `8080` internally) onto a single public
`80`/`443`, routed by hostname or path:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: three-services
spec:
  ingressClassName: nginx
  rules:
  - host: svc-a.local
    http:
      paths: [{path: /, pathType: Prefix, backend: {service: {name: svc-a, port: {number: 8080}}}}]
  - host: svc-b.local
    http:
      paths: [{path: /, pathType: Prefix, backend: {service: {name: svc-b, port: {number: 8080}}}}]
  - host: svc-c.local
    http:
      paths: [{path: /, pathType: Prefix, backend: {service: {name: svc-c, port: {number: 8080}}}}]
```

Each rule points at a different Service's `8080` — no conflict, because the Ingress controller
is the one thing actually bound to the shared public port, and it dispatches by `Host` header
before ever reaching a Service.

## Does a namespace change any of this? (e.g. on EKS)

No — a namespace is a label/RBAC/DNS boundary, not a network partition. It doesn't add or
remove any port isolation beyond what's already true from Service ClusterIPs:

- **ClusterIP / LoadBalancer / Ingress:** completely unaffected by namespace. `svc-a.default`
  and `svc-a.other-namespace` can both use port `8080` for the same reason two Services in the
  *same* namespace can — different ClusterIPs. On EKS, a `LoadBalancer` Service also
  provisions its own dedicated ELB/NLB per Service, so two `LoadBalancer` Services in different
  namespaces on port `8080` just get two different load balancers with two different public
  addresses — no conflict, no shared state at all.
- **NodePort:** still cluster-wide, namespace or not — because it binds on every *node's* IP,
  and namespaces don't partition a node's port space. Verified live: created a `NodePort`
  Service on `30081` in `default`, then tried the identical `nodePort: 30081` in the `kubeflow`
  namespace:

  ```bash
  $ kubectl expose deployment svc-a --type=NodePort --port=8080 -n default \
      --overrides='{"spec":{"ports":[{"port":8080,"targetPort":8080,"nodePort":30081}]}}'
  service/cross-ns-test exposed

  $ kubectl expose deployment ml-pipeline-ui --type=NodePort --port=8080 -n kubeflow \
      --overrides='{"spec":{"ports":[{"port":8080,"targetPort":8080,"nodePort":30081}]}}'
  The Service "cross-ns-test" is invalid: spec.ports[0].nodePort: Invalid value: 30081:
  provided port is already allocated
  ```

  Same error, same cause, regardless of namespace — the API server checks NodePort uniqueness
  cluster-wide, not per-namespace.
- **Ingress backend references:** a plain `Ingress` can only route to a Service in its *own*
  namespace (that's a namespacing rule on the `Ingress`/backend relationship, not a port
  conflict). On EKS with the AWS Load Balancer Controller, multiple `Ingress` objects — even in
  different namespaces — can share one physical ALB via the `IngressGroup` annotation; each
  still just routes by host/path to its own namespace's Service on whatever port it declares,
  same multiplexing story as the single-namespace Ingress example above.

## Summary

| Layer | Own address space? | Reusing the same port across many of these |
|---|---|---|
| Container (within one Pod) | No — shares the Pod's IP | **Conflicts** |
| Pod | Yes — own IP from the pod CIDR | Fine |
| Service (ClusterIP) | Yes — own IP from the service CIDR | Fine |
| `hostPort` / `hostNetwork` | No — shares the node's IP | **Conflicts** (one Pod per node) |
| `NodePort` (explicit value) | No — shares every node's IP | **Conflicts** (must be cluster-unique) |
| `NodePort` (auto-assigned) | Yes — Kubernetes picks a free one | Fine |
| Ingress (multiple `Host` rules) | Yes — routed by hostname/path before hitting a Service | Fine |

## Cleanup

```bash
kubectl delete -f docs/examples/same-port-services.yaml
```
