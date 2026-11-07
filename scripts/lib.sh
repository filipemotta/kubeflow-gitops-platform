#!/usr/bin/env bash
# Shared helpers sourced by the lab scripts. Not meant to be run directly.
# shellcheck shell=bash

# Decimal point and plain messages whatever the operator's locale.
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_ROOT}/out"
MANIFESTS="${REPO_ROOT}/.cache/manifests"
mkdir -p "${OUT}" "${REPO_ROOT}/.kube"
export REPO_ROOT OUT MANIFESTS
export PATH="${REPO_ROOT}/bin:${PATH}"
PY="${REPO_ROOT}/.venv/bin/python"

CLUSTER_NAME="kfp-gitops"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
export CLUSTER_NAME KUBE_CONTEXT

# Pinned versions of what the lab installs besides kubeflow/manifests 26.10.0.
ARGOCD_VERSION="v3.6.1"      # latest Argo CD release on 2026-11-06
GITEA_VERSION="28.3.0"       # latest Gitea release on 2026-11-06 (rootless image)
# The pipeline's own image: python + scikit-learn 1.5.2, the line KServe 0.21's
# sklearn runtime pins (scikit-learn~=1.5.1), so a model pickled by the
# pipeline loads in the server. Built locally and loaded into kind.
PIPELINE_BASE_IMAGE="python:3.12-slim"
PIPELINE_IMAGE="kfp-gitops/sklearn-trainer:1.5.2"
export ARGOCD_VERSION GITEA_VERSION PIPELINE_BASE_IMAGE PIPELINE_IMAGE

# Anonymous Docker/registry config for everything the lab pulls (all images
# are public). Docker Desktop's credential helper can block forever in a
# non-interactive shell; this also keeps your registry logins out of the lab.
DOCKER_CONFIG="${REPO_ROOT}/.cache/docker-anon"
mkdir -p "${DOCKER_CONFIG}"
[ -f "${DOCKER_CONFIG}/config.json" ] || echo '{}' > "${DOCKER_CONFIG}/config.json"
export DOCKER_CONFIG

# The lab never reads or writes your ~/.kube/config: it has its own, created
# by "kind create cluster --kubeconfig" in step 01.
export KUBECONFIG="${REPO_ROOT}/.kube/kind-${CLUSTER_NAME}.yaml"

# The two teams. alice owns team-a, bob owns team-b (Dex static users).
LAB_PASSWORD="kubeflow-lab"   # Dex password of both lab users (lab only)
export LAB_PASSWORD

# Safety: every kubectl call passes --context explicitly, and the lab refuses
# to run if that context is not a kind context pointing at a local API server.
assert_lab_context() {
  local current cluster server
  current="$(kubectl config current-context 2>/dev/null || true)"
  if [[ "${current}" != kind-* ]]; then
    echo "refusing to run: current context '${current}' in ${KUBECONFIG} is not a kind context" >&2
    exit 3
  fi
  cluster="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"${KUBE_CONTEXT}\")].context.cluster}" 2>/dev/null || true)"
  server="$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"${cluster}\")].cluster.server}" 2>/dev/null || true)"
  if [ -z "${cluster}" ] || [[ ! "${server}" =~ ^https://(127\.0\.0\.1|localhost):[0-9]+$ ]]; then
    echo "refusing to run: context ${KUBE_CONTEXT} is missing or does not point at a local kind API server (server='${server}')" >&2
    exit 3
  fi
}

k() { kubectl --context "${KUBE_CONTEXT}" "$@"; }

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
show() { sed 's/^/      /'; }

# --- assertions: failures are counted, the script exits non-zero at the end ---
PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf '    [PASS] %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '    [FAIL] %s\n' "$1"; }

# expect_eq <description> <expected> <actual>
expect_eq() {
  if [ "$2" = "$3" ]; then pass "$1 (got $3)"; else fail "$1 (expected $2, got $3)"; fi
}
# expect_match <description> <extended regex> <actual>
expect_match() {
  if grep -Eq -- "$2" <<< "$3"; then pass "$1"; else fail "$1 (no match for /$2/ in: $(head -c 600 <<< "$3"))"; fi
}
# expect_no_match <description> <extended regex> <actual>
expect_no_match() {
  if grep -Eq -- "$2" <<< "$3"; then fail "$1 (unexpected /$2/ in: $(head -c 600 <<< "$3"))"; else pass "$1"; fi
}
# expect_ge <description> <minimum> <actual integer>
expect_ge() {
  if [[ "$3" =~ ^-?[0-9]+$ ]] && [ "$3" -ge "$2" ]; then pass "$1 (got $3, minimum $2)"; else fail "$1 (got $3, minimum $2)"; fi
}

# refused <description> <regex the error must match> <command...>
# The command must FAIL and its output must say why. Isolation that is only
# proved by the happy path is not proved at all.
refused() {
  local desc="$1" why="$2" out rc attempt
  shift 2
  # A webhook that times out (KServe's, under load) is not a refusal: retry it.
  for attempt in 1 2 3; do
    out="$("$@" 2>&1)" && rc=0 || rc=$?
    grep -q 'failed calling webhook' <<< "${out}" || break
    note "  (attempt ${attempt}: webhook unavailable, retrying)"
    sleep 10
  done
  if [ "${rc}" -ne 0 ] && grep -Eq -- "${why}" <<< "${out}"; then
    pass "${desc}"
    note "  -> ...$(grep -E -- "${why}" <<< "${out}" | head -1 | tail -c 220)"
  elif [ "${rc}" -eq 0 ]; then
    fail "${desc} (the command SUCCEEDED: $(head -c 300 <<< "${out}"))"
  else
    fail "${desc} (failed, but not with /${why}/: $(head -c 400 <<< "${out}"))"
  fi
}

finish() {
  printf '\n    result: %s passed, %s failed\n' "${PASSED}" "${FAILED}"
  printf '%s %s %s\n' "$(basename "$0" .sh)" "${PASSED}" "${FAILED}" >> "${OUT}/assertions.txt"
  [ "${FAILED}" -eq 0 ]
}

# wait_for <seconds> <expected> <command...>: re-runs the command every 3s
# until its output equals <expected>. Returns 1 on timeout.
wait_for() {
  local deadline=$((SECONDS + $1)) expected="$2"; shift 2
  until [ "$("$@" 2>/dev/null)" = "${expected}" ]; do
    [ "${SECONDS}" -lt "${deadline}" ] || { note "timeout (${expected}): $*"; return 1; }
    sleep 3
  done
}

# build_apply <kustomization dir>: kustomize build | server-side apply, with
# retries, as the upstream README does: CRDs and webhooks created by one
# document are often not ready for the next one on the first pass.
build_apply() {
  local dir="$1" attempt rendered
  rendered="${OUT}/render-$(basename "${dir}").yaml"
  kustomize build "${dir}" > "${rendered}"
  note "kustomize build ${dir#"${REPO_ROOT}"/} ($(grep -c '^kind:' "${rendered}") objects)"
  for attempt in 1 2 3 4 5 6; do
    if k apply --server-side --force-conflicts -f "${rendered}" > "${OUT}/apply.log" 2>&1; then
      note "applied on attempt ${attempt}"
      return 0
    fi
    note "apply attempt ${attempt} failed: $(grep -vE 'serverside-applied|unchanged|configured|created' "${OUT}/apply.log" | head -2 | cut -c1-220)"
    sleep 15
  done
  cat "${OUT}/apply.log" >&2
  return 1
}

# wait_workloads <namespace> [timeout]: every Deployment and StatefulSet of the
# namespace rolled out.
wait_workloads() {
  local ns="$1" t="${2:-600s}" w
  for w in $(k -n "${ns}" get deploy,statefulset -o name 2>/dev/null); do
    k -n "${ns}" rollout status "${w}" --timeout="${t}" >/dev/null || { note "not ready: ${ns}/${w}"; return 1; }
  done
}

# ready_count <namespace> -> "<ready>/<total>" Deployments+StatefulSets
ready_count() {
  k -n "$1" get deploy,statefulset -o json \
    | jq -r '[.items[] | ((.spec.replicas // 1) as $want | ((.status.readyReplicas // 0) >= $want))] | "\(map(select(.)) | length)/\(length)"'
}

# --- the Istio ingress gateway, reached through a port-forward ---
GW_PORT="${GW_PORT:-18080}"
GW="http://127.0.0.1:${GW_PORT}"
export GW
gateway_up() {
  if curl -s -o /dev/null --max-time 2 "${GW}/dex/healthz" 2>/dev/null; then return 0; fi
  k -n istio-system port-forward svc/istio-ingressgateway "${GW_PORT}:80" > "${OUT}/port-forward-gw.log" 2>&1 &
  GW_PF_PID=$!
  local i
  for i in $(seq 1 30); do
    curl -s -o /dev/null --max-time 2 "${GW}/dex/healthz" && return 0
    sleep 1
  done
  note "gateway port-forward did not come up (attempt ${i})"
  return 1
}
gateway_down() { [ -n "${GW_PF_PID:-}" ] && kill "${GW_PF_PID}" 2>/dev/null; GW_PF_PID=""; }

# --- Gitea (the GitOps repository), reached through a port-forward ---
GITEA_PORT="${GITEA_PORT:-13000}"
GITEA="http://127.0.0.1:${GITEA_PORT}"
GITOPS_REPO_URL="http://gitea-http.gitops.svc.cluster.local:3000/platform/gitops.git"
# KFP 26.10 stores artifacts in SeaweedFS; this is the S3 endpoint KFP itself
# uses (workflow-controller-configmap, artifactRepository.s3.endpoint).
S3_ENDPOINT="seaweedfs.kubeflow.svc:9000"
export GITEA GITOPS_REPO_URL S3_ENDPOINT
gitea_up() {
  if curl -s -o /dev/null --max-time 2 "${GITEA}/api/healthz" 2>/dev/null; then return 0; fi
  k -n gitops port-forward svc/gitea-http "${GITEA_PORT}:3000" > "${OUT}/port-forward-gitea.log" 2>&1 &
  GITEA_PF_PID=$!
  local i
  for i in $(seq 1 30); do
    curl -s -o /dev/null --max-time 2 "${GITEA}/api/healthz" && return 0
    sleep 1
  done
  note "gitea port-forward did not come up (attempt ${i})"
  return 1
}
gitea_down() { [ -n "${GITEA_PF_PID:-}" ] && kill "${GITEA_PF_PID}" 2>/dev/null; GITEA_PF_PID=""; }

# http_code <curl args...> -> HTTP status only
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$@"; }

# sa_token <namespace> <serviceaccount> -> a short-lived ServiceAccount token
sa_token() { k -n "$1" create token "$2" --duration=1h; }

# dex_login <email> <cookie jar>: the browser flow a person goes through,
# done with curl: ingress -> oauth2-proxy -> Dex login form -> callback.
# Leaves the oauth2-proxy session cookie in the jar.
dex_login() {
  local email="$1" jar="$2" form action
  rm -f "${jar}"
  # 1. Start the flow; follow redirects to the Dex login form.
  form="$(curl -s -L -c "${jar}" -b "${jar}" --max-time 30 "${GW}/oauth2/start?rd=%2F")"
  action="$(grep -oE 'action="[^"]+"' <<< "${form}" | head -1 | sed -E 's/action="([^"]+)"/\1/; s/&amp;/\&/g')"
  if [ -z "${action}" ]; then
    # Dex shows a connector chooser only with more than one connector.
    action="$(grep -oE 'href="/dex/auth/local[^"]*"' <<< "${form}" | head -1 | sed -E 's/href="([^"]+)"/\1/; s/&amp;/\&/g')"
    form="$(curl -s -L -c "${jar}" -b "${jar}" --max-time 30 "${GW}${action}")"
    action="$(grep -oE 'action="[^"]+"' <<< "${form}" | head -1 | sed -E 's/action="([^"]+)"/\1/; s/&amp;/\&/g')"
  fi
  [ -n "${action}" ] || { echo "no Dex login form" >&2; return 1; }
  [[ "${action}" == /* ]] || action="/dex/auth/local/login?${action#*\?}"
  # 2. Post the credentials; Dex redirects to /oauth2/callback, which sets the session cookie.
  curl -s -L -c "${jar}" -b "${jar}" --max-time 30 -o /dev/null \
    --data-urlencode "login=${email}" --data-urlencode "password=${LAB_PASSWORD}" "${GW}${action}"
  grep -q oauth2_proxy_kubeflow "${jar}"
}

# submit_run <user> <namespace> <run name> [key=value...]: submits the
# compiled pipeline as <user> (Dex session in out/<user>.jar) and waits.
# Prints one JSON line: {"run_id", "state", "tasks": {step: state}}.
submit_run() {
  local user="$1" ns="$2" name="$3" p args=()
  shift 3
  for p in "$@"; do args+=(--param "${p}"); done
  "${PY}" "${REPO_ROOT}/pipeline/submit.py" --host "${GW}/pipeline" --cookie-jar "${OUT}/${user}.jar" \
    --namespace "${ns}" --run-name "${name}" --timeout "${RUN_TIMEOUT:-2400}" "${args[@]}" 2>/dev/null | tail -1
}

# run_step_log <namespace> <run id> <step>: log of the step's main container.
run_step_log() {
  local pod
  for pod in $(k -n "$1" get pods -l "pipeline/runid=$2" -o name); do
    if k -n "$1" get "${pod}" -o jsonpath='{.metadata.annotations.workflows\.argoproj\.io/node-name}' | grep -q "\.$3(0)\.executor"; then
      k -n "$1" logs "${pod}" -c main 2>/dev/null
    fi
  done
}

# hub <team> <path>: GET on the team's Kubeflow Hub REST API, from the team's
# own probe pod (the only callers its AuthorizationPolicy admits).
hub() {
  k -n "$1" exec deploy/probe -c curl -- curl -s --max-time 15 \
    "http://model-registry-service.$1.svc.cluster.local:8080/api/model_registry/v1alpha3$2"
}

# predict <caller namespace> [probe deployment]: a prediction request to
# team-a's model from a pod of <caller namespace> (default: the probe with an
# Istio sidecar; "probe-nomesh" has none). Prints "<http code> <body>".
PREDICT_BODY='{"instances":[[6.8,2.8,4.8,1.4],[5.1,3.5,1.4,0.2]]}'
PREDICT_URL="http://iris-classifier-predictor.team-a.svc.cluster.local/v1/models/iris-classifier:predict"
predict() {
  k -n "$1" exec "deploy/${2:-probe}" -c curl -- curl -s -w ' %{http_code}' --max-time 30 \
    -H 'Content-Type: application/json' -d "${PREDICT_BODY}" "${PREDICT_URL}" 2>/dev/null \
    | tr -d '\n' | awk '{ code = $NF; $NF = ""; print code, $0 }'
}

# assert_served <version> <uri>: team-a's InferenceService is Ready, declares
# <uri>, its running predictor downloaded <uri>, Argo CD reports it Healthy,
# and it answers predictions.
assert_served() {
  local version="$1" uri="$2" isvc="iris-classifier" pod resp
  if wait_for 600 "True ${uri}" sh -c "kubectl --context ${KUBE_CONTEXT} -n team-a get inferenceservice ${isvc} -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status} {.spec.predictor.model.storageUri}' 2>/dev/null"; then
    pass "InferenceService Ready on the ${version} URI"
  else
    fail "InferenceService not Ready on the ${version} URI: $(k -n team-a get inferenceservice "${isvc}" -o jsonpath='{.spec.predictor.model.storageUri} {.status.conditions}' 2>&1 | head -c 600)"
  fi
  expect_eq "InferenceService labeled ${version}" "${version}" \
    "$(k -n team-a get inferenceservice "${isvc}" -o jsonpath='{.metadata.labels.lab\.kubeflow-gitops/model-version}')"
  # Ready is not "the new model answers": in Standard mode the InferenceService
  # turns Ready on the new URI while the Deployment is still rolling and the
  # old pod is still serving. Wait until every predictor pod is the new one.
  if wait_for 300 "0" sh -c "kubectl --context ${KUBE_CONTEXT} -n team-a get pods -l serving.kserve.io/inferenceservice=${isvc} -o json \
       | jq --arg u '${uri}' '[.items[] | select(([.spec.initContainers[]?.args[]?] | index(\$u)) == null)] | length'"; then
    pass "every predictor pod runs the ${version} URI (old pods gone)"
  else
    fail "predictor pods still on another URI: $(k -n team-a get pods -l "serving.kserve.io/inferenceservice=${isvc}" -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.spec.initContainers[*].args}{"\n"}{end}' | grep -o 'iris[^ ]* [A-Za-z]*\|train-and-promote/[a-f0-9-]*' | tr '\n' ' ')"
  fi
  if wait_for 300 "Synced Healthy" k -n argocd get applications.argoproj.io team-a-models -o jsonpath='{.status.sync.status} {.status.health.status}'; then
    pass "Argo CD: team-a-models Synced and Healthy"
  else
    fail "Argo CD: team-a-models $(k -n argocd get applications.argoproj.io team-a-models -o jsonpath='{.status.sync.status} {.status.health.status}')"
  fi
  resp="$(predict team-a)"
  expect_match "team-a gets predictions from ${version}" '^200 .*"predictions":\[1,0\]' "${resp}"
}
