# Installing Kargo

[Kargo](https://kargo.io) is a GitOps-native progressive delivery / promotion tool built on
Argo CD. It watches for new "Freight" (artifacts — images, charts, manifests) in a `Warehouse`
and promotes it through a pipeline of `Stage`s, each scoped to a `Project`. Unlike the
`kserve-inference` chart in this repo, we did not template a Kargo `Project` here — this only
covers installing the **control plane** itself. There is no chart in this directory; the install
was driven straight from Kargo's official Helm chart.

## Where it's installed

- **Cluster:** `fullstack` minikube profile (same cluster KServe is on)
- **Namespace:** `kargo`
- **Chart:** `oci://ghcr.io/akuity/kargo-charts/kargo`, version `1.10.9`
- **Components deployed** (all `Running`):
  - `kargo-api` — the API server + web UI
  - `kargo-controller` — reconciles `Stage`/`Warehouse`/`Promotion` resources
  - `kargo-management-controller` — reconciles `Project`/`ClusterConfig` resources
  - `kargo-webhooks-server` — internal `ValidatingWebhookConfiguration`/`MutatingWebhookConfiguration` backend
  - `kargo-external-webhooks-server` — receives inbound webhooks (e.g. from a Git host or registry) to trigger reconciliation
- **CRDs installed:** `projects`, `projectconfigs`, `clusterconfigs`, `stages`, `warehouses`,
  `freights`, `promotions`, `promotiontasks`, `clusterpromotiontasks` (all under
  `*.kargo.akuity.io`) — bundled directly in the chart, no separate CRD chart needed.

Argo CD and Argo Rollouts integrations are enabled by default in the chart's values, but neither
is installed on this cluster — Kargo's controller/API server detect the missing CRDs at startup
and fall back to running with those integrations effectively disabled. Install Argo CD
separately (and set `controller.argocd.integrationEnabled` explicitly, or just let the sanity
check handle it) once you actually want Kargo driving Argo CD-based promotions.

## Install command used

Kargo's chart requires a bcrypt password hash and a signing key for the built-in admin account —
these are **not** generated for you, unlike KServe's install script.

```bash
KARGO_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)
KARGO_PASSWORD_HASH=$(htpasswd -bnBC 10 "" "$KARGO_PASSWORD" | tr -d ':\n')
KARGO_SIGNING_KEY=$(openssl rand -base64 48 | tr -d '\n')

helm upgrade --install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
  --version 1.10.9 \
  --namespace kargo --create-namespace \
  --set api.adminAccount.passwordHash="$KARGO_PASSWORD_HASH" \
  --set api.adminAccount.tokenSigningKey="$KARGO_SIGNING_KEY" \
  --wait --timeout 5m
```

**The generated admin password is not stored in this repo.** It was written to
`kargo-admin-creds.env` in this session's scratchpad directory (outside the repo, not committed)
so it survives for the rest of this session only. If you need it again later, regenerate the
hash and re-run the same `helm upgrade` — Kargo's admin auth is stateless (bcrypt hash + signing
key), so rotating it is just re-running the command with new values.

### Troubleshooting: "invalid password" even with the right password

The first install hit exactly this. Root cause: the credentials were saved to
`kargo-admin-creds.env` **unquoted** (`KARGO_ADMIN_PASSWORD_HASH=$2y$10$CDKs...`), then later
read back with `source kargo-admin-creds.env`. A bcrypt hash is full of literal `$` characters,
and `source` parses the file as shell script — so `$2`, `$1`, `$10`, `$CDKsuEJfaZuYxiuozieUm`
etc. inside the unquoted value were interpreted as positional-parameter/variable expansions
(mostly expanding to nothing) instead of literal text. The hash that got `helm --set` into the
cluster was silently mangled into garbage that didn't correspond to any password.

**Fix applied:**
1. Single-quote secret values when writing them to a file meant to be `source`d:
   `KARGO_ADMIN_PASSWORD_HASH='$2y$10$...'` — single quotes stop `$` expansion entirely.
2. Even better, don't `source` a file containing secrets with `$` in it at all — extract the
   value with `grep`/`cut` (or `jq`/`yq` for structured formats) instead, so it's never
   evaluated as shell syntax:
   ```bash
   HASH=$(grep KARGO_ADMIN_PASSWORD_HASH kargo-admin-creds.env | cut -d"'" -f2)
   ```
3. **Verify the hash actually matches the password before installing anything**, with the same
   tool used to check it at login time:
   ```bash
   printf "admin:%s\n" "$HASH" > /tmp/check
   htpasswd -vb /tmp/check admin "$PASSWORD"   # "Password for user admin correct." or it fails loudly
   ```
   This would have caught the bug immediately instead of only surfacing as a confusing
   "invalid password" in the browser after the fact.
4. After fixing, confirm the *cluster* actually has the corrected hash (not just your local
   file) — Helm doesn't tell you if a `--set` value got mangled before it ever reached `helm`:
   ```bash
   kubectl get secret kargo-api -n kargo -o jsonpath='{.data.ADMIN_ACCOUNT_PASSWORD_HASH}' | base64 -d
   ```
   and diff that against what you intended to install.

**General lesson:** never round-trip a secret containing `$`, `` ` ``, or `"` through an
unquoted shell variable assignment/`source` — either single-quote it at rest, or read it with a
non-shell-evaluating tool (`grep`/`cut`/`jq`/`yq`).

## Accessing it

The API server (and the web UI it serves) defaults to a `ClusterIP` Service with a self-signed
cert, so it's only reachable via port-forward — same pattern as the KServe predictor:

```bash
kubectl port-forward --namespace kargo svc/kargo-api 3000:443
```

Leave that running, then open **https://localhost:3000** in a browser. It'll warn about the
self-signed cert (expected — `api.tls.selfSignedCert=true` in the chart, see table below) —
accept/click through it.

**Login credentials:**

| Field | Value |
|---|---|
| Username | `admin` — Kargo has a single built-in account; there's no separate username field, just tick "Admin login" / pass `--admin` |
| Password | `AEiHzrDxWwwQ2NvqDgMI` |

(This replaces an earlier password that was generated correctly but never actually worked —
see the troubleshooting note below for why, and how the fix was verified before reinstalling.)

That password is **not stored in this repo** — it only exists in this session's scratchpad
(`kargo-admin-creds.env`), so copy it somewhere durable (password manager, secrets store) if
you'll need it after this session ends. It's the plaintext value that was bcrypt-hashed into
`api.adminAccount.passwordHash` at install time (see command above) — Kargo's server never
stores or can recover the plaintext itself.

To log in via the CLI instead of the browser (grab the `kargo` CLI from
[the latest release](https://github.com/akuity/kargo/releases/latest) — it isn't installed in
this environment):

```bash
kargo login https://localhost:3000 --admin --insecure-skip-tls-verify
# prompts for the password above
```

**Lost/rotating the password:** since auth is just a bcrypt hash + signing key in the Helm
values, there's no "forgot password" flow — regenerate both and re-run the same
`helm upgrade --install kargo ...` command from above with the new `--set` values.

## Where you'd install it on EKS

Same chart, same CRDs — what changes is how it's exposed and how promotions get their inputs:

| Concern | Local (minikube) | EKS |
|---|---|---|
| Namespace | `kargo` | Same — `kargo` (convention) |
| API/UI exposure | `ClusterIP` + `kubectl port-forward` | `Ingress` (`api.ingress.enabled=true`) behind the AWS Load Balancer Controller, or `service.type: LoadBalancer` for an NLB directly |
| TLS | self-signed cert via cert-manager | Real cert — either cert-manager + ACM/Let's Encrypt via DNS-01, or terminate TLS at the ALB and set `api.tls.enabled=false` upstream |
| Admin auth | bcrypt password (what we set up) | Usually swapped for OIDC SSO (`api.oidc.*` in values) against your IdP instead of the shared admin account, especially once more than one person needs access |
| Argo CD integration | disabled (Argo CD not installed) | Typically **enabled** — install Argo CD in the same cluster (or point `controller.argocd.namespace` at wherever it lives) so Kargo can actually drive promotions by updating Argo CD `Application` resources |
| Freight sources | manual `Warehouse` pointing at public registries/repos | `Warehouse`s watching your ECR repos / Git repos, usually needing IRSA-scoped credentials or a Git App/deploy key stored as a `Secret` |
| Inbound webhooks | `kargo-external-webhooks-server` port-forwarded, not reachable from outside | Exposed via its own `Ingress` (`externalWebhooksServer.ingress.enabled=true`) so GitHub/GitLab/registry webhooks can actually reach it |
| cert-manager | installed fresh alongside KServe | Usually already present cluster-wide — reuse it, don't reinstall |

### Practical EKS install sketch

```bash
helm upgrade --install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
  --version 1.10.9 \
  --namespace kargo --create-namespace \
  --set api.adminAccount.passwordHash="$KARGO_PASSWORD_HASH" \
  --set api.adminAccount.tokenSigningKey="$KARGO_SIGNING_KEY" \
  --set api.service.type=ClusterIP \
  --set api.ingress.enabled=true \
  --set api.ingress.ingressClassName=alb \
  --set api.ingress.host=kargo.yourdomain.com \
  --set controller.argocd.integrationEnabled=true \
  --set controller.argocd.namespace=argocd
```

As with KServe, prefer driving this from CI/CD or GitOps rather than running `helm upgrade` by
hand — the admin password/signing key in particular should come from a secrets manager
(AWS Secrets Manager / External Secrets Operator), not a shell variable.
