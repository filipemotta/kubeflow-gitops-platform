#!/usr/bin/env bash
# Step 05: a pipeline that can say no. alice submits a run whose training data
# is 90% shuffled labels. The gate must fail the run, and nothing downstream
# may happen: no version in Kubeflow Hub, no branch, no pull request.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
assert_lab_context

step "05 the gate refuses a bad model"
gateway_up
dex_login alice@example.com "${OUT}/alice.jar" || fail "alice cannot log in"
result="$(submit_run alice team-a gate-bad-data version=v0-bad label_noise=0.9 accuracy_threshold=0.9)"
note "${result}"
expect_eq "run with bad data ends FAILED" "FAILED" "$(jq -r '.state' <<< "${result}")"
expect_eq "the failing step is the gate" "FAILED" "$(jq -r '.tasks.gate // "missing"' <<< "${result}")"
expect_eq "train and evaluate ran" "SUCCEEDED SUCCEEDED" "$(jq -r '"\(.tasks.train) \(.tasks.evaluate)"' <<< "${result}")"
expect_eq "register never ran" "null" "$(jq -r '.tasks.register // "null"' <<< "${result}")"
expect_eq "open-pull-request never ran" "null" "$(jq -r '.tasks["open-pull-request"] // "null"' <<< "${result}")"
expect_match "gate log names the reason" "GATE REJECTED: accuracy 0\.[0-9]+ < threshold 0\.9000" "$(run_step_log team-a "$(jq -r '.run_id' <<< "${result}")" gate)"
gateway_down

registry_versions="$(hub team-a "/model_versions?pageSize=100" | jq -r '[.items[]?.name] | join(",")')"
expect_no_match "Kubeflow Hub has no version v0-bad" "(^|,)v0-bad(,|$)" "${registry_versions}"
gitea_up
expect_eq "no promotion branch for v0-bad" "404" \
  "$(http_code -u "platform-admin:${LAB_PASSWORD}" "${GITEA}/api/v1/repos/platform/gitops/branches/promote%2Firis-classifier-v0-bad")"
expect_eq "no pull request at all" "0" \
  "$(curl -s -u "platform-admin:${LAB_PASSWORD}" "${GITEA}/api/v1/repos/platform/gitops/pulls?state=all" | jq 'length')"
gitea_down
finish
