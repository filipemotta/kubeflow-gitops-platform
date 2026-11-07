#!/usr/bin/env bash
# Step 03: the delivery side. Argo CD, Gitea and the admission policy
# (platform/60-gitops); then the GitOps repository with a protected main
# branch, one bot per team that can open pull requests but not merge them,
# the AppProject + Application per team, and per team the two Secrets the
# flow needs: the bot's Git token (for the pipeline) and the object-store
# credentials KServe uses to download the model.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
assert_lab_context

step "03 gitops"
t0=${SECONDS}
build_apply "${REPO_ROOT}/platform/60-gitops"
for ns in argocd gitops; do
  if wait_workloads "${ns}" 600s; then pass "60-gitops: workloads in ${ns} ready ($(ready_count "${ns}"))"
  else fail "60-gitops: workloads in ${ns} not ready ($(ready_count "${ns}"))"; k -n "${ns}" get pods | show; fi
done
expect_eq "admission policy immutable-model-uri installed" "immutable-model-uri" \
  "$(k get validatingadmissionpolicybinding immutable-model-uri -o jsonpath='{.metadata.name}')"

# --- Gitea: users -----------------------------------------------------------
gitea_admin() { k -n gitops exec deploy/gitea -c gitea -- gitea admin "$@"; }
create_user() { # create_user <name> [--admin]
  gitea_admin user create --username "$1" --password "${LAB_PASSWORD}" --email "$1@example.com" \
    --must-change-password=false "${@:2}" >/dev/null
}
create_user platform-admin --admin   # platform team: reviews and merges promotions
create_user team-a-bot               # team-a's pipeline: opens pull requests
create_user team-b-bot               # team-b's pipeline
create_user argocd-reader            # Argo CD: read-only access to the repository
create_user oncall                   # on-call engineer: opens rollback pull requests
pass "Gitea users created (platform-admin, team-a-bot, team-b-bot, argocd-reader, oncall)"

gitea_up
ADMIN=(-u "platform-admin:${LAB_PASSWORD}")
api() { curl -s --max-time 30 -H 'Content-Type: application/json' "$@"; }

# --- the repository ------------------------------------------------------------
api "${ADMIN[@]}" -X POST "${GITEA}/api/v1/orgs" -d '{"username":"platform","visibility":"private"}' >/dev/null
api "${ADMIN[@]}" -X POST "${GITEA}/api/v1/orgs/platform/repos" \
  -d '{"name":"gitops","private":true,"auto_init":true,"default_branch":"main","readme":"Default"}' >/dev/null
for team in team-a team-b; do
  content="$(printf 'Models served in %s. Changed only through pull requests opened by the pipeline.\n' "${team}" | base64 | tr -d '\n')"
  api "${ADMIN[@]}" -X POST "${GITEA}/api/v1/repos/platform/gitops/contents/apps/${team}/README.md" \
    -d "{\"content\":\"${content}\",\"message\":\"Add apps/${team}\",\"branch\":\"main\"}" >/dev/null
done
expect_eq "repository platform/gitops exists with apps/team-a and apps/team-b" "2" \
  "$(api "${ADMIN[@]}" "${GITEA}/api/v1/repos/platform/gitops/contents/apps?ref=main" | jq 'length')"

for user in team-a-bot team-b-bot oncall; do
  api "${ADMIN[@]}" -X PUT "${GITEA}/api/v1/repos/platform/gitops/collaborators/${user}" -d '{"permission":"write"}' >/dev/null
done
api "${ADMIN[@]}" -X PUT "${GITEA}/api/v1/repos/platform/gitops/collaborators/argocd-reader" -d '{"permission":"read"}' >/dev/null

# main is protected: nobody pushes to it directly except the platform admin
# (who merges), and a merge needs one approval from the platform admin. The
# bots can create branches and open pull requests, nothing else on main.
api "${ADMIN[@]}" -X POST "${GITEA}/api/v1/repos/platform/gitops/branch_protections" -d '{
  "rule_name": "main",
  "enable_push": true, "enable_push_whitelist": true, "push_whitelist_usernames": ["platform-admin"],
  "enable_merge_whitelist": true, "merge_whitelist_usernames": ["platform-admin"],
  "required_approvals": 1, "enable_approvals_whitelist": true, "approvals_whitelist_username": ["platform-admin"],
  "block_on_rejected_reviews": true, "dismiss_stale_approvals": true
}' >/dev/null
expect_eq "main is protected (push and merge only by platform-admin, 1 approval)" "1" \
  "$(api "${ADMIN[@]}" "${GITEA}/api/v1/repos/platform/gitops/branch_protections/main" | jq '.required_approvals')"

# Tokens: each user creates its own (Gitea requires the user's credentials).
new_token() { # new_token <user> <scope>
  api -u "$1:${LAB_PASSWORD}" -X POST "${GITEA}/api/v1/users/$1/tokens" \
    -d "{\"name\":\"lab-$(date +%s)\",\"scopes\":[\"$2\"]}" | jq -r '.sha1'
}
READER_TOKEN="$(new_token argocd-reader read:repository)"

# --- per team: Git token for the pipeline, object-store credentials for KServe
for team in team-a team-b; do
  bot_token="$(new_token "${team}-bot" write:repository)"
  k -n "${team}" create secret generic gitops-pr-token --from-literal=token="${bot_token}" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  # KFP's profile controller already gave the namespace credentials to the
  # object store (mlpipeline-minio-artifact). KServe reads the same objects
  # through an S3 Secret attached to a ServiceAccount.
  access="$(k -n "${team}" get secret mlpipeline-minio-artifact -o jsonpath='{.data.accesskey}' | base64 -d)"
  secret="$(k -n "${team}" get secret mlpipeline-minio-artifact -o jsonpath='{.data.secretkey}' | base64 -d)"
  k -n "${team}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kserve-models-s3
  annotations:
    serving.kserve.io/s3-endpoint: ${S3_ENDPOINT}
    serving.kserve.io/s3-usehttps: "0"
    serving.kserve.io/s3-region: us-east-1
    serving.kserve.io/s3-useanoncredential: "false"
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "${access}"
  AWS_SECRET_ACCESS_KEY: "${secret}"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kserve-models
secrets:
- name: kserve-models-s3
EOF
  expect_eq "${team}: Git token and KServe storage Secret in place" "2" \
    "$(k -n "${team}" get secret gitops-pr-token kserve-models-s3 -o name | wc -l | tr -d ' ')"
done

# --- Argo CD: repository credentials, then one AppProject + Application per team
k -n argocd apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitops-repo
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${GITOPS_REPO_URL}
  username: argocd-reader
  password: "${READER_TOKEN}"
EOF
k apply -f "${REPO_ROOT}/gitops/team-a.yaml" -f "${REPO_ROOT}/gitops/team-b.yaml" | show
for team in team-a team-b; do
  if wait_for 240 "Synced" k -n argocd get applications.argoproj.io "${team}-models" -o jsonpath='{.status.sync.status}'; then
    pass "Argo CD application ${team}-models synced from platform/gitops"
  else
    fail "Argo CD application ${team}-models not synced: $(k -n argocd get applications.argoproj.io "${team}-models" -o jsonpath='{.status.conditions}')"
  fi
done

gitea_down
note "03: $((SECONDS - t0)) s, node memory now $(docker stats --no-stream --format '{{.MemUsage}}' "${CLUSTER_NAME}-control-plane" | cut -d/ -f1)"
finish
