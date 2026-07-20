# kubeflow-pipeline-sample

A sample Kubeflow Pipelines (KFP) v2 SDK pipeline: loads the Iris dataset, trains a
`RandomForestClassifier`, and evaluates it. Three lightweight (function-based) components,
each running in its own container, chained together:

```
create_dataset -> train_model -> evaluate_model
```

For how KFP itself got installed on this cluster (and the troubleshooting along the way),
see [`INSTALL-KUBEFLOW.md`](./INSTALL-KUBEFLOW.md).

## Compile

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python pipeline.py
```

Produces `pipeline.yaml`.

## Run

Port-forward the KFP UI and API from the `kubeflow` namespace:

```bash
kubectl port-forward -n kubeflow svc/ml-pipeline-ui 8080:80
kubectl port-forward -n kubeflow svc/ml-pipeline 8888:8888
```

Then either:

- **UI:** open http://localhost:8080, create a run, and upload `pipeline.yaml`.
- **SDK:**

  ```python
  import kfp

  client = kfp.Client(host="http://localhost:8888")
  client.create_run_from_pipeline_package("pipeline.yaml", arguments={"test_size": 0.2})
  ```

Metrics (`accuracy`, `f1_macro`) logged by `evaluate_model` show up on the run's page in the UI.
