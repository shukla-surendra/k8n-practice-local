# Helm vs. Kustomize

Two different answers to "how do I manage YAML for different environments without copy-pasting
it," both used in this repo — deliberately, since they solve overlapping but distinct problems.

## Helm — templating + packaging

```
full-stack-app/
  Chart.yaml           # name, version
  values.yaml           # defaults
  templates/
    *.yaml               # Go templates — {{ .Values.x }}, {{ include "..." }}, {{- if }}
  charts/
    backend/ frontend/ database/   # subcharts, each with their own values.yaml
```

Renders **Go templates** into YAML at install time — real conditionals, loops, string
manipulation, reusable snippets (`_helpers.tpl`, see `my-app/templates/_helpers.tpl`), and
subcharts for composing multiple components (`full-stack-app`'s `backend`/`frontend`/`database`
subcharts, each independently versioned/testable) into one release. A Helm **release** is a
tracked, named, versioned deployment — `helm upgrade`/`helm rollback` know what changed between
versions and can revert. Bundles CRDs too (`kargo`'s chart ships its nine CRDs directly, no
separate step — see [`crds-and-operators.md`](./crds-and-operators.md)).

```bash
helm install my-release ./full-stack-app -f full-stack-app/values.yaml
helm upgrade my-release ./full-stack-app --set backend.replicaCount=3
helm rollback my-release 1
helm template ./full-stack-app | less              # render without installing — inspect output
```

## Kustomize — overlay/patch, no templating language

```
manifests/kustomize/
  base/                                # plain, complete YAML — no {{ }} anywhere
  env/
    platform-agnostic/kustomization.yaml    # references base + patches on top
    gcp/kustomization.yaml
    ...
```

Used to install Kubeflow Pipelines on this cluster (`kubeflow-pipeline-sample/INSTALL-KUBEFLOW.md`)
— there's no Helm chart because upstream doesn't ship one; instead a `base/` of plain YAML gets
layered with strategic-merge or JSON patches per environment overlay
(`env/platform-agnostic`, `env/gcp`, `env/openshift`, ...). No templating language at all — every
file is valid standalone YAML; a `kustomization.yaml` just lists `resources:` to include and
`patches:`/`replacements:` to apply on top. `kubectl apply -k <dir>` (or a bare directory with a
`kustomization.yaml`) builds and applies it — kustomize is built into `kubectl` since 1.14, no
separate install needed, which is exactly why the KFP install commands in this repo are plain
`kubectl apply -k github.com/...` with no CLI installed for it.

```bash
kubectl kustomize ./manifests/kustomize/env/platform-agnostic | less    # render without applying
kubectl apply -k ./manifests/kustomize/env/platform-agnostic
```

## Why both exist in this repo, not just one

| | Helm | Kustomize |
|---|---|---|
| Templating | Real language (conditionals, loops, functions) | None — patches on top of plain YAML |
| Versioned releases, rollback | Yes (`helm rollback`) | No — it's just `kubectl apply`, no release history |
| Packaging/distribution | Chart repos, OCI registries (`kargo`'s chart is pulled via `oci://ghcr.io/...`) | Just a git ref/directory — `?ref=<tag>` on a URL |
| Best fit | You're authoring the chart yourself, want reuse across environments via `values.yaml`, want rollback | Upstream ships plain manifests and per-environment overlays; you don't want a templating layer between you and the exact YAML applied |

Concretely in this repo: `full-stack-app`, `kserve-inference`, and `my-app` are Helm charts
*we* wrote, so we get to choose templating + release tracking. Kubeflow Pipelines and Kargo's
CRDs come from upstream `pipelines`/`kargo-charts` repos — KFP ships Kustomize overlays (no
chart), Kargo ships a Helm chart (`oci://ghcr.io/akuity/kargo-charts/kargo`) — so the tool used
for each install was upstream's choice, not ours. Reading `kubectl apply -k` vs. `helm install`
in an install doc is a reliable signal for which one upstream picked.

## Quick reference

```bash
helm list -A                          # installed releases
helm get values <release>             # what values a release was installed with
helm diff upgrade <release> ./chart   # (needs helm-diff plugin) preview an upgrade's changes

kubectl kustomize <dir>               # render a kustomize dir to stdout
kubectl get all -l application-crd-id=kubeflow-pipelines -n kubeflow   # kustomize output has no release concept — label selectors are how you find "everything this install created"
```
