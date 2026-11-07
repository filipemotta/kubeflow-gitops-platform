#!/usr/bin/env bash
# Step 99: delete the lab cluster (and only it), with retries, and check it is gone.
set -uo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

step "99 teardown"
pkill -f "port-forward svc/(istio-ingressgateway|gitea-http)" 2>/dev/null || true
for attempt in 1 2 3; do
  kind delete cluster --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG}" 2>&1 | show
  kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}" || break
  note "cluster still listed after attempt ${attempt}, retrying"
  sleep 10
done
expect_eq "kind cluster ${CLUSTER_NAME} deleted" "" "$(kind get clusters 2>/dev/null | grep -x "${CLUSTER_NAME}" || true)"
expect_eq "node container gone" "" "$(docker ps -a --format '{{.Names}}' | grep -x "${CLUSTER_NAME}-control-plane" || true)"
rm -f "${KUBECONFIG}"
finish
