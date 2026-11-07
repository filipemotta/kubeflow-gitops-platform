#!/usr/bin/env bash
# Step 04: two teams on one Kubeflow, proved by being refused. Each check has
# a positive control (the team reaching its own thing) next to the refusal,
# so a refusal caused by a broken setup cannot pass for isolation.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
assert_lab_context

step "04 isolation between team-a and team-b"
gateway_up

# --- people, through the ingress gateway (oauth2-proxy + Dex) ------------------
expect_eq "no session: KFP API answers 401" "401" \
  "$(http_code "${GW}/pipeline/apis/v2beta1/runs?namespace=team-a")"
for user in alice bob; do
  if dex_login "${user}@example.com" "${OUT}/${user}.jar"; then pass "${user} logs in through Dex"; else fail "${user} cannot log in"; fi
done
expect_eq "alice lists runs in team-a (her Profile)" "200" \
  "$(http_code -b "${OUT}/alice.jar" "${GW}/pipeline/apis/v2beta1/runs?namespace=team-a")"
expect_eq "alice lists runs in team-b: refused by KFP (SubjectAccessReview)" "403" \
  "$(http_code -b "${OUT}/alice.jar" "${GW}/pipeline/apis/v2beta1/runs?namespace=team-b")"
expect_eq "bob lists runs in team-b (his Profile)" "200" \
  "$(http_code -b "${OUT}/bob.jar" "${GW}/pipeline/apis/v2beta1/runs?namespace=team-b")"
expect_eq "bob lists runs in team-a: refused" "403" \
  "$(http_code -b "${OUT}/bob.jar" "${GW}/pipeline/apis/v2beta1/runs?namespace=team-a")"
gateway_down

# --- workloads, inside the mesh -------------------------------------------------
for team in team-a team-b; do
  k -n "${team}" apply -f "${REPO_ROOT}/probes/probe.yaml" >/dev/null
done
for team in team-a team-b; do
  k -n "${team}" rollout status deploy/probe --timeout=300s >/dev/null
done
k -n team-a apply -f "${REPO_ROOT}/probes/probe-nomesh.yaml" >/dev/null
k -n team-a rollout status deploy/probe-nomesh --timeout=300s >/dev/null
from() { # from <team> <url> -> HTTP status seen by a pod of <team>
  k -n "$1" exec deploy/probe -c curl -- curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$2" || true
}
REGISTRY_PATH=":8080/api/model_registry/v1alpha3/registered_models"
expect_eq "a team-a pod reaches team-a's Kubeflow Hub" "200" \
  "$(from team-a "http://model-registry-service.team-a.svc.cluster.local${REGISTRY_PATH}")"
expect_eq "a team-a pod calling team-b's Kubeflow Hub: refused by Istio (RBAC: access denied)" "403" \
  "$(from team-a "http://model-registry-service.team-b.svc.cluster.local${REGISTRY_PATH}")"
expect_eq "a team-b pod reaches team-b's Kubeflow Hub" "200" \
  "$(from team-b "http://model-registry-service.team-b.svc.cluster.local${REGISTRY_PATH}")"
expect_eq "a team-b pod calling team-a's Kubeflow Hub: refused" "403" \
  "$(from team-b "http://model-registry-service.team-a.svc.cluster.local${REGISTRY_PATH}")"
expect_eq "a team-a pod outside the mesh (no identity) calling team-a's Hub: refused" "403" \
  "$(k -n team-a exec deploy/probe-nomesh -c curl -- curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
      "http://model-registry-service.team-a.svc.cluster.local${REGISTRY_PATH}" || true)"

# Kubernetes RBAC: what a team's pipeline identity may do outside its namespace.
expect_eq "team-a's pipeline identity cannot read Secrets in team-b" "no" \
  "$(k auth can-i get secrets -n team-b --as system:serviceaccount:team-a:default-editor || true)"
expect_eq "team-a's pipeline identity cannot create InferenceServices in team-b" "no" \
  "$(k auth can-i create inferenceservices.serving.kserve.io -n team-b --as system:serviceaccount:team-a:default-editor || true)"
expect_eq "alice cannot create InferenceServices in team-b" "no" \
  "$(k auth can-i create inferenceservices.serving.kserve.io -n team-b --as alice@example.com || true)"

finish
