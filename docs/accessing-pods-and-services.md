# Accessing a Pod from a browser — port-forward vs. the production way

Worked example using [`sample-nginx/`](../sample-nginx), verified against the `fullstack`
minikube cluster.

## `kubectl port-forward` — what it actually is

```bash
kubectl port-forward pod/nginx-pod 8080:80
# or against a Service:
kubectl port-forward svc/nginx-deployment 8080:80
```

- Opens a tunnel: `you -> localhost:8080 -> kube-apiserver -> one specific Pod's port 80`.
- The **API server proxies the connection** — your laptop needs a valid kubeconfig with
  permission to `pods/portforward`, and network access to the API server. The target
  container image is never exposed on the network directly.
- Targets **one Pod**, not a load-balanced set. Pointing it at a Service just picks one of the
  Service's endpoint Pods for you — it does not spread requests across replicas.
- Lives only as long as the terminal/process running it. Close it, and access stops. Nobody
  else can use your tunnel.

This is why it's a debugging tool, not an access mechanism: it requires cluster credentials on
the client, forwards to a single pod, and dies with your terminal. None of that is acceptable
for "how do users reach this app."

## The production way: Service + Ingress

Production traffic doesn't reach a Pod through the API server at all — it goes through the data
plane: a `Service` (stable virtual IP + load-balancing across matching Pods) fronted by
something that terminates real inbound traffic.

```
Browser -> [cloud LoadBalancer / Ingress controller] -> Service (ClusterIP) -> Pod (any replica)
```

### The pieces, in order of how a real request flows

1. **Deployment** — runs the actual replicas.
   ```bash
   kubectl apply -f sample-nginx/nginx-deployment.yaml
   ```
2. **Service (`ClusterIP`)** — a stable in-cluster address that load-balances across all Pods
   matching its selector. This is the thing Ingress/LoadBalancers actually point at.
   ```bash
   kubectl expose deployment nginx-deployment --port=80 --target-port=80 --type=ClusterIP
   ```
   Note: this is deliberately `ClusterIP`, not `NodePort`. `NodePort` (used in
   `sample-nginx/readme.md`'s original walkthrough) opens a fixed high port
   (30000-32767) on every node — fine for quick local testing, but it's not how you expose
   HTTP(S) apps for real: no hostnames, no path routing, no TLS, and you're leaking node IPs
   as the access point.
3. **Ingress** — HTTP(S)-aware routing: host/path rules mapped to backend Services, TLS
   termination, all in one config resource instead of one Service-per-app exposure.
   ```yaml
   # sample-nginx/ingress.yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: nginx-deployment
   spec:
     ingressClassName: nginx
     rules:
     - host: sample-nginx.local
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: nginx-deployment
               port:
                 number: 80
   ```
   ```bash
   kubectl apply -f sample-nginx/ingress.yaml
   ```
   An `Ingress` resource alone routes nothing — it's config consumed by an **Ingress
   controller**, a real running proxy (`ingress-nginx` here — already installed on this
   cluster, see `kubectl get pods -n ingress-nginx`) that watches `Ingress` objects and
   configures itself accordingly.
4. **Something that gets real traffic to the Ingress controller.** This is the one part that's
   genuinely different between local and cloud:
   - **Cloud (EKS/GKE/AKS):** the Ingress controller's own Service is `type: LoadBalancer`,
     which asks the cloud provider to provision a real external load balancer (on AWS, an ALB
     via the AWS Load Balancer Controller, or a classic/NLB) with a public IP/DNS name. That's
     the actual production entry point — no `kubectl` involved, no client-side tunnel.
   - **Local (minikube, this cluster):** there's no cloud to hand out a real IP, so
     `ingress-nginx-controller`'s Service is `NodePort` instead
     (`kubectl get svc -n ingress-nginx` shows `80:32193/TCP`). On Linux this NodePort is
     reachable directly at the node IP; on macOS with the `docker` driver the node runs inside
     a container the host can't route to directly, so you still need `minikube tunnel` or
     `kubectl port-forward` — **but forwarded to the Ingress controller, not the app** — to
     reach it from your laptop. That's a limitation of running Kubernetes-on-a-laptop, not a
     production pattern.

### Verified end-to-end

```bash
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 18080:80 &
curl -H "Host: sample-nginx.local" http://127.0.0.1:18080/
# -> nginx welcome page
```

The `Host` header is what makes this a realistic Ingress test rather than a plain
port-forward: the request goes to the **controller**, and the controller does the routing that
a real load balancer would trigger in production — port-forwarding to the app Pod directly
would skip that entirely.

## Summary

| Method | Client needs | Load-balanced | Survives terminal close | TLS/host routing | Use for |
|---|---|---|---|---|---|
| `kubectl port-forward` | kubeconfig + RBAC | No (one pod) | No | No | Local debugging only |
| `Service: NodePort` | network route to any node | Yes (across pods) | Yes | No | Quick local testing |
| `Service: LoadBalancer` | — (cloud provisions a public LB) | Yes | Yes | Only what the LB gives you | Simple single-service exposure on a cloud provider |
| `Ingress` + controller | — (public LB in front of controller) | Yes | Yes | Yes (host/path rules, TLS) | Real HTTP(S) app exposure — the default for production |

Nobody runs `kubectl port-forward` in production — it's a one-person, one-terminal debugging
tunnel through the control plane. Production traffic always goes through the data plane:
`Service` for stable load-balanced addressing, `Ingress` (or a cloud `LoadBalancer` Service, or
a Gateway API `Gateway`/`HTTPRoute` on newer clusters) for the actual internet-facing entry
point.
