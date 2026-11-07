#!/usr/bin/env bash
# Step 10: the guardrails, each proved by a refusal next to a positive control.
# - admission: only Argo CD writes InferenceServices; only an artifact of one
#   of the team's own pipeline runs, and no field or KServe resource that
#   could load or run something else;
# - Argo CD: a team's project cannot deploy into another team's namespace, and
#   a hand edit in the cluster is reverted to what Git says;
# - serving: no token, no prediction; another team's token, no prediction.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
assert_lab_context

step "10 guardrails"
isvc_with() { # isvc_with <storageUri> [predictor field] -> manifest
  local field="${2:-model}" fmt=""
  [ "${field}" = "model" ] && fmt="      modelFormat:
        name: sklearn
"
  cat <<EOF
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: guardrail-check
  namespace: team-a
spec:
  predictor:
    ${field}:
${fmt}      storageUri: $1
EOF
}
good_uri="$(awk '$1 == "v1" { print $2 }' "${OUT}/registered-uris.txt" | tail -1)"
isvc_with "${good_uri}" > "${OUT}/isvc-good.yaml"
isvc_with s3://mlpipeline/models/iris-classifier/latest/ > "${OUT}/isvc-latest-path.yaml"
isvc_with oci://registry.example.com/models/iris:latest > "${OUT}/isvc-latest-tag.yaml"
# The bypass a denylist of "latest" lets through: a mutable folder with another name.
isvc_with s3://mlpipeline/models/iris-classifier/current/ > "${OUT}/isvc-other-name.yaml"
# A real run artifact, but from team-b's private prefix.
isvc_with "${good_uri/private-artifacts\/team-a\//private-artifacts/team-b/}" > "${OUT}/isvc-other-team.yaml"
isvc_with s3://mlpipeline/models/iris-classifier/latest/ sklearn > "${OUT}/isvc-framework-field.yaml"
{ isvc_with "${good_uri}"; cat <<EOF
  transformer:
    containers:
    - name: kserve-container
      image: python:3.12-slim
EOF
} > "${OUT}/isvc-transformer.yaml"
{ isvc_with "${good_uri}"; cat <<EOF
  explainer:
    containers:
    - name: kserve-container
      image: python:3.12-slim
EOF
} > "${OUT}/isvc-explainer.yaml"
# A custom-container predictor: any image, loading any model from anywhere.
cat > "${OUT}/isvc-custom-container.yaml" <<EOF
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: guardrail-check
  namespace: team-a
spec:
  predictor:
    containers:
    - name: kserve-container
      image: python:3.12-slim
EOF
# The model spec is also a container spec: keep the allowed URI, swap the image.
{ isvc_with "${good_uri}"; } | sed 's|^      storageUri: |      image: python:3.12-slim\n      storageUri: |' > "${OUT}/isvc-model-image.yaml"
{ isvc_with "${good_uri}"; } | sed 's|^      storageUri: |      runtime: team-runtime\n      storageUri: |' > "${OUT}/isvc-model-runtime.yaml"
{ isvc_with "${good_uri}"; cat <<EOF
    initContainers:
    - name: fetch
      image: curlimages/curl:8.17.0
EOF
} > "${OUT}/isvc-initcontainer.yaml"
cat > "${OUT}/servingruntime.yaml" <<EOF
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: team-runtime
  namespace: team-a
spec:
  supportedModelFormats:
  - name: sklearn
    autoSelect: true
  containers:
  - name: kserve-container
    image: python:3.12-slim
EOF
cat > "${OUT}/inferencegraph.yaml" <<EOF
apiVersion: serving.kserve.io/v1alpha1
kind: InferenceGraph
metadata:
  name: team-graph
  namespace: team-a
spec:
  nodes:
    root:
      routerType: Sequence
      steps:
      - serviceName: iris-classifier
EOF
as_alice=(apply --dry-run=server --as alice@example.com -f)
# The field and URI checks run as Argo CD, the only writer gitops-only-writer
# admits: even a merged mistake is refused before it reaches the cluster.
as_argocd=(apply --dry-run=server --as system:serviceaccount:argocd:argocd-application-controller -f)
NOT_ALLOWED="is not a pipeline-run artifact of team-a"

if k "${as_argocd[@]}" "${OUT}/isvc-good.yaml" >/dev/null 2>&1; then rc=0; else rc=$?; fi
expect_eq "control: Argo CD may create an InferenceService on the run's registered URI (dry run)" "0" "${rc}"
refused "alice cannot write an InferenceService by hand, even on a registered URI" "cannot write InferenceServices in team-a" \
  k "${as_alice[@]}" "${OUT}/isvc-good.yaml"

refused "an InferenceService on .../latest/ is refused by the admission policy" "${NOT_ALLOWED}" \
  k "${as_argocd[@]}" "${OUT}/isvc-latest-path.yaml"
refused "an InferenceService with an image-style :latest URI is refused" "${NOT_ALLOWED}" \
  k "${as_argocd[@]}" "${OUT}/isvc-latest-tag.yaml"
refused "a mutable folder with another name (current/) is refused too: allowlist, not denylist" "${NOT_ALLOWED}" \
  k "${as_argocd[@]}" "${OUT}/isvc-other-name.yaml"
refused "team-b's run artifact cannot be served from team-a" "${NOT_ALLOWED}" \
  k "${as_argocd[@]}" "${OUT}/isvc-other-team.yaml"
# KServe's defaulting webhook rewrites the deprecated spec.predictor.sklearn into
# spec.predictor.model before validating admission runs, so the policy sees it.
refused "the deprecated spec.predictor.sklearn field with a latest URI is refused too" "${NOT_ALLOWED}" \
  k "${as_argocd[@]}" "${OUT}/isvc-framework-field.yaml"
refused "a transformer (which loads its own model) is refused" "transformers and explainers are not allowed" \
  k "${as_argocd[@]}" "${OUT}/isvc-transformer.yaml"
refused "an explainer is refused" "transformers and explainers are not allowed" \
  k "${as_argocd[@]}" "${OUT}/isvc-explainer.yaml"
refused "an allowed URI with a swapped image on spec.predictor.model is refused" "must not set image, command, args, env or runtime" \
  k "${as_argocd[@]}" "${OUT}/isvc-model-image.yaml"
refused "an explicit runtime on spec.predictor.model is refused" "must not set image, command, args, env or runtime" \
  k "${as_argocd[@]}" "${OUT}/isvc-model-runtime.yaml"
refused "predictor initContainers are refused" "predictor initContainers are not allowed" \
  k "${as_argocd[@]}" "${OUT}/isvc-initcontainer.yaml"
# As the lab's cluster admin, so RBAC cannot be what refuses it: the policy is.
refused "a ServingRuntime in team-a is refused by the policy, even for a cluster admin" "servingruntimes are managed by the platform" \
  k apply --dry-run=server -f "${OUT}/servingruntime.yaml"
refused "an InferenceGraph in team-a is refused too" "inferencegraphs are managed by the platform" \
  k apply --dry-run=server -f "${OUT}/inferencegraph.yaml"
refused "a custom-container predictor (no registered model) is refused" \
  "denied request: (custom predictor containers are not allowed|spec.predictor.model.storageUri is required)" \
  k "${as_argocd[@]}" "${OUT}/isvc-custom-container.yaml"

# --- Argo CD: the AppProject boundary ---------------------------------------------
k -n argocd apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: team-a-into-team-b
  namespace: argocd
spec:
  project: team-a
  source:
    repoURL: ${GITOPS_REPO_URL}
    targetRevision: main
    path: apps/team-a
  destination:
    server: https://kubernetes.default.svc
    namespace: team-b
  syncPolicy:
    automated: {}
EOF
if wait_for 120 "InvalidSpecError" k -n argocd get applications.argoproj.io team-a-into-team-b -o jsonpath='{.status.conditions[0].type}'; then
  pass "Argo CD refuses an Application of project team-a that targets team-b"
  note "  -> $(k -n argocd get applications.argoproj.io team-a-into-team-b -o jsonpath='{.status.conditions[0].message}' | head -c 220)"
else
  fail "Application team-a-into-team-b was not refused: $(k -n argocd get applications.argoproj.io team-a-into-team-b -o jsonpath='{.status}' | head -c 400)"
fi
expect_eq "nothing was deployed into team-b" "" "$(k -n team-b get inferenceservices -o name)"
k -n argocd delete applications.argoproj.io team-a-into-team-b --wait=false >/dev/null

# --- Argo CD: self-heal reverts a hand edit -------------------------------------------
# Made as the lab's cluster admin (kubeadm:cluster-admins), the break-glass
# identity gitops-only-writer still admits.
k -n team-a label inferenceservice iris-classifier lab.kubeflow-gitops/model-version=hand-edit --overwrite >/dev/null
if wait_for 180 "v1" k -n team-a get inferenceservice iris-classifier -o jsonpath='{.metadata.labels.lab\.kubeflow-gitops/model-version}'; then
  pass "a hand edit in the cluster is reverted to Git by Argo CD self-heal"
else
  fail "hand edit not reverted"
fi

# --- serving: who may call team-a's model ----------------------------------------------
# No policy was added for the model: the Profile's own AuthorizationPolicy
# (only team-a's namespace, proved by mTLS, or the owner through the ingress
# gateway) is what refuses everyone else.
expect_match "control: a team-a workload gets predictions" '^200 .*"predictions"' "$(predict team-a)"
expect_match "a team-b workload is refused by team-a's Profile policy (RBAC: access denied)" '^403 RBAC: access denied' \
  "$(predict team-b)"
expect_match "a team-a pod outside the mesh (no identity, like a default KFP step) is refused" '^403 RBAC: access denied' \
  "$(predict team-a probe-nomesh)"
finish
