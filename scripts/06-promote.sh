#!/usr/bin/env bash
# Step 06: promotion is a pull request. Usage: 06-promote.sh <version> [seed]
# alice's run trains, passes the gate, registers <version> in team-a's
# Kubeflow Hub and opens a pull request in the GitOps repository. The bot
# that opened it cannot merge it or push to main; the platform admin approves
# and merges; Argo CD syncs the merge commit; KServe serves the registered URI.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
assert_lab_context

VERSION="${1:?usage: 06-promote.sh <version> [seed]}"
SEED="${2:-7}"
MODEL="iris-classifier"
BRANCH="promote/${MODEL}-${VERSION}"

step "06 promote ${MODEL} ${VERSION} through a pull request"

# --- 1. the run ---------------------------------------------------------------
gateway_up
dex_login alice@example.com "${OUT}/alice.jar" || fail "alice cannot log in"
result="$(submit_run alice team-a "promote-${VERSION}" "version=${VERSION}" "seed=${SEED}" label_noise=0.0 accuracy_threshold=0.9)"
gateway_down
note "${result}"
run_id="$(jq -r '.run_id' <<< "${result}")"
expect_eq "run ${VERSION} SUCCEEDED" "SUCCEEDED" "$(jq -r '.state' <<< "${result}")"
expect_eq "every step succeeded (train evaluate gate register open-pull-request)" \
  "SUCCEEDED SUCCEEDED SUCCEEDED SUCCEEDED SUCCEEDED" \
  "$(jq -r '"\(.tasks.train) \(.tasks.evaluate) \(.tasks.gate) \(.tasks.register) \(.tasks["open-pull-request"])"' <<< "${result}")"

# --- 2. Kubeflow Hub ------------------------------------------------------------
rm_id="$(hub team-a "/registered_model?name=${MODEL}" | jq -r '.id')"
mv="$(hub team-a "/registered_models/${rm_id}/versions?pageSize=100" | jq -c --arg v "${VERSION}" '.items[] | select(.name == $v)')"
mv_id="$(jq -r '.id' <<< "${mv}")"
uri="$(hub team-a "/model_versions/${mv_id}/artifacts" | jq -r '.items[0].uri')"
expect_match "Kubeflow Hub has ${MODEL} ${VERSION} with its accuracy" '"double_value":' "$(jq -c '.customProperties.accuracy' <<< "${mv}")"
expect_match "registered URI is this run's own artifact path (immutable)" \
  "^s3://mlpipeline/private-artifacts/team-a/v2/artifacts/train-and-promote/${run_id}/train/" "${uri}"
echo "${VERSION} ${uri}" >> "${OUT}/registered-uris.txt"

# --- 3. the pull request ---------------------------------------------------------
gitea_up
ADMIN=(-u "platform-admin:${LAB_PASSWORD}")
BOT=(-u "team-a-bot:${LAB_PASSWORD}")
REPO_API="${GITEA}/api/v1/repos/platform/gitops"
pr="$(curl -s "${ADMIN[@]}" "${REPO_API}/pulls?state=open" | jq -c --arg t "Promote ${MODEL} ${VERSION}" '.[] | select(.title == $t)')"
pr_number="$(jq -r '.number' <<< "${pr}")"
expect_eq "pull request opened by team-a-bot" "team-a-bot" "$(jq -r '.user.login' <<< "${pr}")"
proposed="$(curl -s "${ADMIN[@]}" "${REPO_API}/raw/apps/team-a/${MODEL}.yaml?ref=$(jq -rn --arg b "${BRANCH}" '$b|@uri')")"
expect_match "the PR points the InferenceService at the registered URI" "storageUri: ${uri}$" "${proposed}"

# The bot that opened it can do nothing else with main.
expect_match "team-a-bot cannot merge its own pull request" "^(403|405|422)$" \
  "$(http_code "${BOT[@]}" -X POST -H 'Content-Type: application/json' "${REPO_API}/pulls/${pr_number}/merge" -d '{"Do":"merge"}')"
expect_match "team-a-bot cannot push to main" "^(403|422)$" \
  "$(http_code "${BOT[@]}" -X PUT -H 'Content-Type: application/json' "${REPO_API}/contents/apps/team-a/${MODEL}.yaml" \
      -d "{\"content\":\"$(printf 'x' | base64)\",\"branch\":\"main\",\"message\":\"bypass\",\"sha\":\"0000000000000000000000000000000000000000\"}")"
expect_match "a merge without approval is refused, even for the platform admin" "^(405|422)$" \
  "$(http_code "${ADMIN[@]}" -X POST -H 'Content-Type: application/json' "${REPO_API}/pulls/${pr_number}/merge" -d '{"Do":"merge"}')"

# The platform admin reviews and merges.
expect_eq "platform-admin approves" "200" \
  "$(http_code "${ADMIN[@]}" -X POST -H 'Content-Type: application/json' "${REPO_API}/pulls/${pr_number}/reviews" \
      -d "{\"event\":\"APPROVED\",\"body\":\"Accuracy above the gate, URI registered in Kubeflow Hub.\"}")"
expect_eq "platform-admin merges" "200" \
  "$(http_code "${ADMIN[@]}" -X POST -H 'Content-Type: application/json' "${REPO_API}/pulls/${pr_number}/merge" \
      -d '{"Do":"merge","delete_branch_after_merge":true}')"
merge_sha="$(curl -s "${ADMIN[@]}" "${REPO_API}/pulls/${pr_number}" | jq -r '.merge_commit_sha')"
echo "${VERSION} ${merge_sha}" >> "${OUT}/merge-commits.txt"
gitea_down

# --- 4. Argo CD and KServe ---------------------------------------------------------
if wait_for 300 "${merge_sha}" k -n argocd get applications.argoproj.io team-a-models -o jsonpath='{.status.sync.revision}'; then
  pass "Argo CD synced the merge commit ${merge_sha:0:10}"
else
  fail "Argo CD did not reach ${merge_sha:0:10}: $(k -n argocd get applications.argoproj.io team-a-models -o jsonpath='{.status.sync.revision} {.status.conditions}')"
fi
assert_served "${VERSION}" "${uri}"
finish
