"""Sample Kubeflow Pipeline: train and evaluate an Iris classifier.

Three lightweight (function-based) components, chained into a pipeline:
  create_dataset -> train_model -> evaluate_model

Each component runs in its own container (base image below), so dependencies
are declared per-component via `packages_to_install` rather than a shared
requirements file.
"""

from kfp import compiler, dsl
from kfp.dsl import Dataset, Input, Metrics, Model, Output

BASE_IMAGE = "python:3.11-slim"


@dsl.component(base_image=BASE_IMAGE, packages_to_install=["scikit-learn==1.5.2", "pandas==2.2.3"])
def create_dataset(dataset: Output[Dataset]):
    from sklearn.datasets import load_iris

    iris = load_iris(as_frame=True)
    df = iris.frame
    df.to_csv(dataset.path, index=False)


@dsl.component(base_image=BASE_IMAGE, packages_to_install=["scikit-learn==1.5.2", "pandas==2.2.3", "joblib==1.4.2"])
def train_model(dataset: Input[Dataset], model: Output[Model], test_size: float = 0.2):
    import joblib
    import pandas as pd
    from sklearn.ensemble import RandomForestClassifier
    from sklearn.model_selection import train_test_split

    df = pd.read_csv(dataset.path)
    X, y = df.drop(columns=["target"]), df["target"]
    X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=test_size, random_state=42)

    clf = RandomForestClassifier(n_estimators=100, random_state=42)
    clf.fit(X_train, y_train)

    joblib.dump({"model": clf, "X_test": X_test, "y_test": y_test}, model.path)


@dsl.component(base_image=BASE_IMAGE, packages_to_install=["scikit-learn==1.5.2", "joblib==1.4.2"])
def evaluate_model(model: Input[Model], metrics: Output[Metrics]):
    import joblib
    from sklearn.metrics import accuracy_score, f1_score

    bundle = joblib.load(model.path)
    clf, X_test, y_test = bundle["model"], bundle["X_test"], bundle["y_test"]
    y_pred = clf.predict(X_test)

    metrics.log_metric("accuracy", accuracy_score(y_test, y_pred))
    metrics.log_metric("f1_macro", f1_score(y_test, y_pred, average="macro"))


@dsl.pipeline(
    name="iris-training-pipeline",
    description="Load Iris, train a RandomForest classifier, and evaluate it.",
)
def iris_training_pipeline(test_size: float = 0.2):
    dataset_task = create_dataset()
    train_task = train_model(dataset=dataset_task.outputs["dataset"], test_size=test_size)
    evaluate_model(model=train_task.outputs["model"])


if __name__ == "__main__":
    compiler.Compiler().compile(
        pipeline_func=iris_training_pipeline,
        package_path="pipeline.yaml",
    )
    print("Compiled pipeline.yaml")
