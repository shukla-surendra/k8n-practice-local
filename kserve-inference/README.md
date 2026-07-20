# kserve-inference

A minimal Helm chart that deploys a [KServe](https://kserve.github.io/website/) `InferenceService`
to serve a model. This chart does **not** install KServe itself — it assumes KServe's control
plane (CRDs + controller, plus Knative Serving if you're using Serverless mode) is already
running on the cluster.

## Prerequisites

- A Kubernetes cluster with KServe installed (`kubectl get crd inferenceservices.serving.kserve.io`
  should succeed). See [INSTALL-KSERVE.md](./INSTALL-KSERVE.md) for how KServe itself was
  installed locally (and the issues hit along the way), plus notes on installing it on EKS.
- A model artifact in supported storage (GCS, S3, PVC, HTTP, etc.) in a format matching a
  `ServingRuntime` registered in the cluster (sklearn, xgboost, tensorflow, pytorch, onnx, ...).

## Install

```bash
helm install my-model ./kserve-inference
```

By default this deploys the KServe sklearn "iris" example model, so you can verify the chart
works end-to-end before pointing it at your own model.

## Configure your own model

Override values, e.g. in a `values-myapp.yaml`:

```yaml
predictor:
  model:
    modelFormat: sklearn
    storageUri: "s3://my-bucket/models/my-model/"
  serviceAccountName: "s3-credentials-sa" # only needed for private storage
```

```bash
helm install my-model ./kserve-inference -f values-myapp.yaml
```

## Key values

| Key | Description | Default |
|---|---|---|
| `predictor.model.modelFormat` | Model framework (must match an installed ServingRuntime) | `sklearn` |
| `predictor.model.storageUri` | Where the model artifacts live | KServe's public iris example |
| `predictor.minReplicas` | Min pods; `0` allows scale-to-zero (Serverless mode) | `1` |
| `predictor.maxReplicas` | Max pods | `3` |
| `predictor.scaleMetric` / `predictor.scaleTarget` | Autoscaling metric and target value | `concurrency` / `5` |
| `predictor.serviceAccountName` | ServiceAccount for private model storage credentials | `""` |
| `transformer.enabled` | Add a pre/post-processing container in front of the predictor | `false` |

See `values.yaml` for the full list and inline comments.

## Check status

```bash
kubectl get inferenceservice my-model -w
kubectl get inferenceservice my-model -o jsonpath='{.status.url}'
```

## Uninstall

```bash
helm uninstall my-model
```
