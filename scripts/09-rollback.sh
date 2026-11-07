#!/usr/bin/env bash
# Step 09: rollback is git revert. The on-call engineer reverts the merge that
# promoted v2 and opens a pull request; the platform admin approves and
# merges; Argo CD puts v1 back. Nobody touches the cluster or the pipeline.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
assert_lab_context

step "09 rollback v2 -> v1 with git revert"
v2_merge="$(awk '$1 == "v2" { print $2 }' "${OUT}/merge-commits.txt" | tail -1)"
v1_uri="$(awk '$1 == "v1" { print $2 }' "${OUT}/registered-uris.txt" | tail -1)"
if [ -z "${v2_merge}" ] || [ -z "${v1_uri}" ]; then fail "run 06-promote.sh v1 and v2 first"; finish; fi

gitea_up
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
git clone -q "http://oncall:${LAB_PASSWORD}@127.0.0.1:${GITEA_PORT}/platform/gitops.git" "${work}/gitops"
(
  cd "${work}/gitops"
  git config user.name "On-call engineer"
  git config user.email "oncall@example.com"
  git checkout -q -b revert/iris-classifier-v2
  git revert -m 1 --no-edit "${v2_merge}" > /dev/null
  git push -q origin revert/iris-classifier-v2
)
expect_match "the revert restores the v1 URI in apps/team-a" "storageUri: ${v1_uri}$" \
  "$(cat "${work}/gitops/apps/team-a/iris-classifier.yaml")"

REPO_API="${GITEA}/api/v1/repos/platform/gitops"
pr_number="$(curl -s -u "oncall:${LAB_PASSWORD}" -X POST -H 'Content-Type: application/json' "${REPO_API}/pulls" \
  -d '{"head":"revert/iris-classifier-v2","base":"main","title":"Revert iris-classifier v2","body":"Roll back to v1."}' | jq -r '.number')"
expect_match "on-call opened the revert pull request" '^[0-9]+$' "${pr_number}"
expect_eq "platform-admin approves the revert" "200" \
  "$(http_code -u "platform-admin:${LAB_PASSWORD}" -X POST -H 'Content-Type: application/json' "${REPO_API}/pulls/${pr_number}/reviews" -d '{"event":"APPROVED","body":"Rollback."}')"
expect_eq "platform-admin merges the revert" "200" \
  "$(http_code -u "platform-admin:${LAB_PASSWORD}" -X POST -H 'Content-Type: application/json' "${REPO_API}/pulls/${pr_number}/merge" -d '{"Do":"merge","delete_branch_after_merge":true}')"
revert_sha="$(curl -s -u "platform-admin:${LAB_PASSWORD}" "${REPO_API}/pulls/${pr_number}" | jq -r '.merge_commit_sha')"
gitea_down

if wait_for 300 "${revert_sha}" k -n argocd get applications.argoproj.io team-a-models -o jsonpath='{.status.sync.revision}'; then
  pass "Argo CD synced the revert ${revert_sha:0:10}"
else
  fail "Argo CD did not reach the revert ${revert_sha:0:10}"
fi
assert_served v1 "${v1_uri}"
finish
