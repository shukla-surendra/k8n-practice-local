# ConfigMaps and Secrets

Both hold key-value data you don't want baked into a container image; the difference is
handling, not real security. Grounded in `full-stack-app`'s backend/database charts, which use
both.

## ConfigMap — non-sensitive config

```yaml
# full-stack-app/charts/backend — referenced via envFrom in deployment.yaml
envFrom:
  - configMapRef:
      name: {{ include "backend.fullname" . }}-config
```

Every key in the ConfigMap becomes an environment variable in the container. The other common
mount style is as files (`volumes.configMap`), used here for the database's init scripts:

```yaml
# full-stack-app/charts/database/templates/statefulset.yaml
volumeMounts:
  - name: init-scripts
    mountPath: /docker-entrypoint-initdb.d
    readOnly: true
volumes:
  - name: init-scripts
    configMap:
      name: {{ include "database.fullname" . }}-init
```

## Secret — same API shape, different handling

```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: {{ .Release.Name }}-database
        key: postgres-password
```

Structurally a Secret is just a ConfigMap with `data` base64-encoded instead of plain strings.
**Base64 is encoding, not encryption** — anyone with API read access to the Secret (or etcd
access) can decode it trivially. What actually differs from a ConfigMap:

- etcd encryption-at-rest can be scoped to Secrets specifically (`EncryptionConfiguration`) —
  worth turning on since Secrets are where credentials live.
- RBAC is usually written to treat `secrets` as a more sensitive resource than `configmaps`
  (see [`rbac.md`](./rbac.md) — the backend's own Role grants `get/list/watch` on both, but a
  tighter setup would split them).
- Kubelet keeps Secret data in tmpfs (in-memory) when mounted as a volume, not written to disk.
- Some Secret `type`s (`kubernetes.io/tls`, `kubernetes.io/dockerconfigjson`) get special
  handling by other components (Ingress TLS termination, image pull auth).

For real secret management beyond what plain Secrets give you (audit logging, rotation,
external KMS), look at **External Secrets Operator** or cloud-native options (AWS Secrets
Manager + IRSA on EKS) — out of scope for this local cluster, but worth knowing the plain
`Secret` object is deliberately minimal.

## Live reload gotcha

Neither ConfigMap nor Secret changes trigger a Pod restart on their own — an updated ConfigMap
just becomes visible in already-mounted-as-files data (with a delay, via kubelet sync) or not
at all for `envFrom`, since env vars are only set at container start. `full-stack-app`'s
Deployment works around this with a checksum annotation that changes when the ConfigMap does,
forcing a new Pod:

```yaml
# full-stack-app/charts/backend/templates/deployment.yaml
annotations:
  checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

Since the Pod template's annotations changed, the Deployment controller sees a diff and rolls
out new Pods — same trick the database StatefulSet uses for its init-scripts ConfigMap
(`checksum/init`).

## Quick reference

```bash
kubectl create configmap my-config --from-literal=KEY=value
kubectl create secret generic my-secret --from-literal=PASSWORD=hunter2

kubectl get configmap my-config -o yaml
kubectl get secret my-secret -o jsonpath='{.data.PASSWORD}' | base64 -d

kubectl delete configmap my-config
```
