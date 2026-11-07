#!/usr/bin/env bash
# The whole lab, end to end, on a fresh kind cluster, and the cluster deleted
# at the end whatever happens. Prints one line per step and the total number
# of assertions; exits non-zero if any assertion failed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO_ROOT="$(pwd)"
OUT="${REPO_ROOT}/out"
mkdir -p "${OUT}"
rm -f "${OUT}/assertions.txt" "${OUT}/registered-uris.txt" "${OUT}/merge-commits.txt"

STEPS=(
  "00-preflight"
  "01-cluster"
  "02-platform"
  "03-gitops"
  "04-isolation"
  "05-gate"
  "06-promote v1 7"
  "06-promote v2 11"
  "09-rollback"
  "10-guardrails"
  "11-static"
)

# shellcheck disable=SC2317,SC2329  # invoked by the EXIT trap
teardown() { bash scripts/99-teardown.sh > "${OUT}/step-99-teardown.log" 2>&1; tail -1 "${OUT}/step-99-teardown.log"; }
trap teardown EXIT

start=${SECONDS}
status=0
for entry in "${STEPS[@]}"; do
  read -r script args <<< "${entry}"
  log="${OUT}/step-${script}${args:+-${args// /-}}.log"
  t0=${SECONDS}
  # shellcheck disable=SC2086
  bash "scripts/${script}.sh" ${args} > "${log}" 2>&1
  rc=$?
  printf '%-22s rc=%s %4ss  %s\n' "${script} ${args}" "${rc}" "$((SECONDS - t0))" "$(grep -E 'result:' "${log}" | tail -1 | sed 's/^ *//')"
  if [ "${rc}" -ne 0 ]; then
    status=1
    grep -E '\[FAIL\]' "${log}" | head -5
    # Without a platform there is nothing left to test.
    case "${script}" in 00-preflight|01-cluster|02-platform|03-gitops) break ;; esac
  fi
done

passed=$(awk '{ s += $2 } END { print s + 0 }' "${OUT}/assertions.txt" 2>/dev/null)
failed=$(awk '{ s += $3 } END { print s + 0 }' "${OUT}/assertions.txt" 2>/dev/null)
echo "assertions: ${passed} passed, ${failed} failed; lab time $((SECONDS - start)) s"
[ "${failed}" -eq 0 ] || status=1
exit "${status}"
