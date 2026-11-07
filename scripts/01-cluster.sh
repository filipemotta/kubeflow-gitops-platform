#!/usr/bin/env bash
# Step 01: the kind cluster (one node), the inotify limits the Kubeflow README
# asks for, and the pipeline image built locally and loaded into the node.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

step "01 cluster"
kind create cluster --config "${REPO_ROOT}/kind/cluster.yaml" --kubeconfig "${KUBECONFIG}" --wait 120s 2>&1 | show
assert_lab_context

# The kind node is a container in the Docker VM: these sysctls apply to the
# VM's kernel for as long as it runs, not to your Mac or to Docker's settings.
docker exec "${CLUSTER_NAME}-control-plane" sysctl -w fs.inotify.max_user_instances=2280 fs.inotify.max_user_watches=1255360 | show

expect_eq "node Ready" "True" "$(k get node "${CLUSTER_NAME}-control-plane" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
expect_eq "node Kubernetes version" "v1.35.8" "$(k get node "${CLUSTER_NAME}-control-plane" -o jsonpath='{.status.nodeInfo.kubeletVersion}')"
expect_eq "inotify max_user_instances" "2280" "$(docker exec "${CLUSTER_NAME}-control-plane" sysctl -n fs.inotify.max_user_instances)"

docker build -q -t "${PIPELINE_IMAGE}" "${REPO_ROOT}/pipeline/image" | show
kind load docker-image "${PIPELINE_IMAGE}" --name "${CLUSTER_NAME}" 2>&1 | show
expect_match "pipeline image loaded in the node" "sklearn-trainer" \
  "$(docker exec "${CLUSTER_NAME}-control-plane" crictl images 2>/dev/null)"

finish
