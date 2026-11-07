#!/usr/bin/env bash
# Step 02: the Kubeflow Community Distribution 26.10.0, trimmed to what the
# lab proves, installed stage by stage (platform/10..50), then the two teams
# (Profiles) and one Kubeflow Hub per team. Each stage waits for its workloads
# before the next one starts, so the memory peak of one stage's image pulls
# and start-ups does not stack on top of the next one's.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
assert_lab_context

step "02 platform"
mem_sample() { docker stats --no-stream --format '{{.MemUsage}}' "${CLUSTER_NAME}-control-plane" | cut -d/ -f1 | tr -d ' '; }

stage() { # stage <dir> <namespaces...>
  local dir="$1" t0=${SECONDS} ns; shift
  build_apply "${REPO_ROOT}/platform/${dir}"
  for ns in "$@"; do
    if wait_workloads "${ns}" 900s; then
      pass "${dir}: workloads in ${ns} ready ($(ready_count "${ns}"))"
    else
      fail "${dir}: workloads in ${ns} not ready ($(ready_count "${ns}"))"
      k -n "${ns}" get pods | show
    fi
  done
  note "${dir}: $((SECONDS - t0)) s, node memory now $(mem_sample)"
  echo "${dir} $((SECONDS - t0)) $(mem_sample)" >> "${OUT}/stage-times.txt"
}

# Images published as a multi-platform index WITHOUT the node's platform (on
# an arm64 node: kfp-metadata-writer 2.18.0, which has only linux/amd64) fail
# with "no match for platform in manifest"; containerd does not fall back to
# emulation for an index. Pull the amd64 entry by digest into the node and tag
# it with the original name; the pods use IfNotPresent, so they run it under
# the Docker VM's amd64 emulation. Single-platform amd64 images (the ML
# Metadata server) need nothing: containerd pulls and emulates them as they are.
preload_foreign_images() {
  local node_arch image platforms kind digest ref
  node_arch="$(docker exec "${CLUSTER_NAME}-control-plane" uname -m)"
  [ "${node_arch}" = "aarch64" ] || return 0
  [ -f "${OUT}/arch-report.txt" ] || { note "no out/arch-report.txt: run 00-preflight.sh first"; return 1; }
  # Only images that some Deployment/StatefulSet/DaemonSet/Job of this lab runs
  # (not, say, the image of a KServe runtime nobody uses).
  "${PY}" "${REPO_ROOT}/tools/list-images.py" --workloads "${OUT}"/render-*.yaml > "${OUT}/workload-images.txt"
  while read -r image platforms kind; do
    [ "${kind}" = "index" ] || continue
    [[ ",${platforms}," == *",linux/arm64,"* ]] && continue
    [[ ",${platforms}," == *",linux/amd64,"* ]] || continue
    grep -qxF "${image}" "${OUT}/workload-images.txt" || continue
    # ctr wants fully qualified names: kserve/x:1 -> docker.io/kserve/x:1.
    ref="${image}"
    [[ "${ref%%/*}" == *.* ]] || ref="docker.io/${ref}"
    [[ "${ref}" == */*/* ]] || ref="${ref/docker.io\//docker.io/library/}"
    digest="$(crane digest --platform linux/amd64 "${image}")"
    docker exec "${CLUSTER_NAME}-control-plane" ctr -n k8s.io images pull --platform linux/amd64 "${ref%:*}@${digest}" > /dev/null
    docker exec "${CLUSTER_NAME}-control-plane" ctr -n k8s.io images tag --force "${ref%:*}@${digest}" "${ref}" > /dev/null
    note "preloaded linux/amd64 variant of ${image} (emulated on this arm64 node)"
    echo "${image}" >> "${OUT}/preloaded-amd64.txt"
  done < "${OUT}/arch-report.txt"
}

: > "${OUT}/stage-times.txt"
: > "${OUT}/preloaded-amd64.txt"
preload_foreign_images
stage 10-cert-manager cert-manager
stage 20-istio istio-system
stage 30-auth auth oauth2-proxy
stage 40-kubeflow kubeflow
stage 50-serving kserve

step "02b teams"
k apply -f "${REPO_ROOT}/tenants/profiles.yaml" | show
for team in team-a team-b; do
  if wait_for 180 "Active" k get namespace "${team}" -o jsonpath='{.status.phase}'; then
    pass "Profile ${team} created its namespace"
  else
    fail "Profile ${team} did not create its namespace"
  fi
  expect_eq "${team} has Istio injection" "enabled" "$(k get namespace "${team}" -o jsonpath='{.metadata.labels.istio-injection}')"
  # The KFP profile controller (metacontroller) gives every team namespace its
  # own artifact credentials and the ml-pipeline-ui-artifact proxy.
  if wait_for 300 "1" sh -c "kubectl --context ${KUBE_CONTEXT} -n ${team} get secret mlpipeline-minio-artifact -o name 2>/dev/null | wc -l | tr -d ' '"; then
    pass "${team}: KFP artifact credentials synced into the namespace"
  else
    fail "${team}: KFP artifact credentials not synced"
  fi
  build_apply "${REPO_ROOT}/tenants/${team}"
  if wait_workloads "${team}" 600s; then
    pass "${team}: Kubeflow Hub (model registry + PostgreSQL) ready ($(ready_count "${team}"))"
  else
    fail "${team}: Kubeflow Hub not ready ($(ready_count "${team}"))"
    k -n "${team}" get pods | show
  fi
done

note "node memory after install: $(mem_sample)"
k top node 2>/dev/null | show || true
finish
