"""Training pipeline that ends in a pull request, not in a bucket.

train -> evaluate -> gate -> register in Kubeflow Hub -> open a PR in the
GitOps repository that changes the team's InferenceService.

The gate fails the run when accuracy is below the threshold, so nothing
downstream runs: no registry entry, no pull request. The pipeline never gets
credentials to the cluster it deploys to; its only write access outside its
own namespace is a Git token that can push branches and open pull requests,
not merge them.

Compile:  python pipeline/train_and_promote.py   (writes train_and_promote.yaml)
"""
from kfp import compiler, dsl, kubernetes

IMAGE = "kfp-gitops/sklearn-trainer:1.5.2"


@dsl.component(base_image=IMAGE, install_kfp_package=False)
def train(label_noise: float, seed: int, model: dsl.Output[dsl.Model]):
    """Trains a logistic regression on iris. label_noise > 0 shuffles that
    fraction of the training labels: the lab's stand-in for bad data."""
    import os

    import joblib
    import numpy as np
    from sklearn.datasets import load_iris
    from sklearn.linear_model import LogisticRegression
    from sklearn.model_selection import train_test_split

    x, y = load_iris(return_X_y=True)
    x_train, _, y_train, _ = train_test_split(x, y, test_size=0.3, random_state=42, stratify=y)
    rng = np.random.default_rng(seed)
    noisy = rng.random(len(y_train)) < label_noise
    y_train = np.where(noisy, rng.integers(0, 3, len(y_train)), y_train)

    clf = LogisticRegression(max_iter=500).fit(x_train, y_train)
    # KServe's sklearn runtime loads <storageUri>/model.joblib.
    os.makedirs(model.path, exist_ok=True)
    joblib.dump(clf, os.path.join(model.path, "model.joblib"))
    model.metadata["framework"] = "sklearn"
    model.metadata["label_noise"] = label_noise


@dsl.component(base_image=IMAGE, install_kfp_package=False)
def evaluate(model: dsl.Input[dsl.Model], metrics: dsl.Output[dsl.Metrics]) -> float:
    """Accuracy on a held-out split the training step never saw."""
    import os

    import joblib
    from sklearn.datasets import load_iris
    from sklearn.model_selection import train_test_split

    x, y = load_iris(return_X_y=True)
    _, x_test, _, y_test = train_test_split(x, y, test_size=0.3, random_state=42, stratify=y)
    # Loads the artifact the train step of this same run just wrote. joblib is
    # pickle: only ever load models your own pipeline produced.
    clf = joblib.load(os.path.join(model.path, "model.joblib"))
    accuracy = float(clf.score(x_test, y_test))
    metrics.log_metric("accuracy", accuracy)
    print(f"accuracy={accuracy:.4f}")
    return accuracy


@dsl.component(base_image=IMAGE, install_kfp_package=False)
def gate(accuracy: float, threshold: float):
    """Fails the run below the threshold. A gate that only logs is not a gate."""
    if accuracy < threshold:
        raise SystemExit(f"GATE REJECTED: accuracy {accuracy:.4f} < threshold {threshold:.4f}")
    print(f"GATE PASSED: accuracy {accuracy:.4f} >= threshold {threshold:.4f}")


@dsl.component(base_image=IMAGE, install_kfp_package=False)
def register(model: dsl.Input[dsl.Model], accuracy: float, model_name: str,
             version: str, registry_url: str, namespace: str, run_id: str) -> str:
    """Registers the model version in the team's Kubeflow Hub and returns the
    storage URI that serving must use. The URI is the run's own artifact path,
    unique per run: there is no "latest" to overwrite."""
    import json
    import urllib.error
    import urllib.request

    api = f"{registry_url}/api/model_registry/v1alpha3"

    def call(method, path, body=None):
        req = urllib.request.Request(api + path, method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.status, json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as err:
            return err.code, {"error": err.read().decode(errors="replace")}

    # KFP writes artifacts with the minio:// scheme; KServe's storage
    # initializer reads the same object store through s3://.
    uri = model.uri.replace("minio://", "s3://", 1)

    status, found = call("GET", f"/registered_model?name={model_name}")
    if status == 200:
        model_id = found["id"]
    else:
        status, created = call("POST", "/registered_models", {"name": model_name})
        if status != 201:
            raise SystemExit(f"cannot create registered model: {status} {created}")
        model_id = created["id"]

    status, mv = call("POST", "/model_versions", {
        "name": version,
        "registeredModelId": model_id,
        "customProperties": {
            "accuracy": {"metadataType": "MetadataDoubleValue", "double_value": accuracy},
        },
    })
    if status != 201:
        # 409: the version name already exists. Versions are immutable: a new
        # model needs a new version name, never an overwrite.
        raise SystemExit(f"cannot create model version {version}: {status} {mv}")

    status, art = call("POST", f"/model_versions/{mv['id']}/artifacts", {
        "artifactType": "model-artifact",
        "name": f"{model_name}-{version}",
        "uri": uri,
        "modelFormatName": "sklearn",
        "modelFormatVersion": "1",
        "modelSourceKind": "kfp",
        "modelSourceClass": "pipelinerun",
        "modelSourceGroup": namespace,
        "modelSourceId": run_id,
    })
    if status not in (200, 201):
        raise SystemExit(f"cannot attach artifact: {status} {art}")
    print(f"registered {model_name} {version} (model version id {mv['id']}) -> {uri}")
    return uri


@dsl.component(base_image=IMAGE, install_kfp_package=False)
def open_pull_request(storage_uri: str, model_name: str, version: str, namespace: str,
                      git_api: str, repo: str, accuracy: float) -> str:
    """Opens a pull request that points the team's InferenceService at the new
    version. Merging it is a human (or policy) decision; Argo CD does the rest."""
    import base64
    import json
    import os
    import urllib.error
    import urllib.request

    token = os.environ["GIT_TOKEN"]
    api = f"{git_api}/api/v1/repos/{repo}"
    path = f"apps/{namespace}/{model_name}.yaml"
    branch = f"promote/{model_name}-{version}"

    def call(method, url, body=None):
        req = urllib.request.Request(url, method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Content-Type": "application/json",
                                              "Authorization": f"token {token}"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.status, json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as err:
            return err.code, {"error": err.read().decode(errors="replace")}

    manifest = f"""# Managed by the training pipeline through pull requests. Do not edit by hand:
# the version below is the one registered in Kubeflow Hub.
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: {model_name}
  namespace: {namespace}
  labels:
    lab.kubeflow-gitops/model-version: "{version}"
  annotations:
    # A plain Deployment + Service (no Knative): callers reach the predictor
    # over mTLS and the team's Profile policy decides who may call it.
    serving.kserve.io/deploymentMode: Standard
spec:
  predictor:
    serviceAccountName: kserve-models
    minReplicas: 1
    model:
      modelFormat:
        name: sklearn
      storageUri: {storage_uri}
      resources:
        requests:
          cpu: 20m
          memory: 128Mi
        limits:
          cpu: "1"
          memory: 512Mi
"""
    status, created = call("POST", f"{api}/branches", {"new_branch_name": branch, "old_branch_name": "main"})
    if status not in (200, 201):
        raise SystemExit(f"cannot create branch {branch}: {status} {created}")

    status, current = call("GET", f"{api}/contents/{path}?ref={branch}")
    body = {"content": base64.b64encode(manifest.encode()).decode(), "branch": branch,
            "message": f"Promote {model_name} {version} (accuracy {accuracy:.4f})"}
    if status == 200:
        body["sha"] = current["sha"]
        status, res = call("PUT", f"{api}/contents/{path}", body)
    else:
        status, res = call("POST", f"{api}/contents/{path}", body)
    if status not in (200, 201):
        raise SystemExit(f"cannot write {path} on {branch}: {status} {res}")

    status, pr = call("POST", f"{api}/pulls", {
        "head": branch, "base": "main",
        "title": f"Promote {model_name} {version}",
        "body": f"Registered in Kubeflow Hub as {model_name} {version}.\n\n"
                f"accuracy: {accuracy:.4f}\nstorageUri: {storage_uri}\n",
    })
    if status != 201:
        raise SystemExit(f"cannot open pull request: {status} {pr}")
    print(f"opened pull request #{pr['number']}: {pr['html_url']}")
    return str(pr["number"])


@dsl.pipeline(name="train-and-promote")
def train_and_promote(
    model_name: str = "iris-classifier",
    version: str = "v1",
    label_noise: float = 0.0,
    seed: int = 7,
    accuracy_threshold: float = 0.9,
    namespace: str = "team-a",
    registry_url: str = "http://model-registry-service:8080",
    git_api: str = "http://gitea-http.gitops.svc.cluster.local:3000",
    gitops_repo: str = "platform/gitops",
):
    trained = train(label_noise=label_noise, seed=seed)
    scored = evaluate(model=trained.outputs["model"])
    passed = gate(accuracy=scored.outputs["Output"], threshold=accuracy_threshold)
    registered = register(model=trained.outputs["model"], accuracy=scored.outputs["Output"],
                          model_name=model_name, version=version,
                          registry_url=registry_url, namespace=namespace,
                          run_id=dsl.PIPELINE_JOB_ID_PLACEHOLDER).after(passed)
    pr = open_pull_request(storage_uri=registered.output, model_name=model_name, version=version,
                           namespace=namespace, git_api=git_api, repo=gitops_repo,
                           accuracy=scored.outputs["Output"])
    # The Git token comes from a Secret in the team's namespace; it never
    # appears as a pipeline parameter, in the UI or in the compiled YAML.
    kubernetes.use_secret_as_env(pr, secret_name="gitops-pr-token", secret_key_to_env={"token": "GIT_TOKEN"})
    # KFP runs every step with sidecar.istio.io/inject: "false", outside the
    # mesh and without a workload identity. The team's Kubeflow Hub only
    # admits callers that prove they run in the team's namespace (mTLS), so
    # the step that talks to it joins the mesh. Istio runs the proxy as a
    # native sidecar here, so the pod still completes when the step ends.
    kubernetes.add_pod_annotation(registered, "sidecar.istio.io/inject", "true")
    for task in (trained, scored, passed, registered, pr):
        task.set_caching_options(False)
        kubernetes.set_image_pull_policy(task, "IfNotPresent")


if __name__ == "__main__":
    import pathlib

    out = pathlib.Path(__file__).with_name("train_and_promote.yaml")
    compiler.Compiler().compile(train_and_promote, str(out))
    print(f"compiled {out}")
