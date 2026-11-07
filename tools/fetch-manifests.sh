#!/usr/bin/env bash
# Fetches kubeflow/manifests at the pinned tag into .cache/manifests (gitignored)
# and refuses to continue if the tag does not point at the pinned commit, so a
# moved tag cannot silently change what the lab installs.
set -euo pipefail

KCD_TAG="26.10.0"
KCD_COMMIT="7e4c522f87d293ac413d89e05a3935a9d76016ec"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO_ROOT}/.cache/manifests"

if [ -d "${DEST}/.git" ] && [ "$(git -C "${DEST}" rev-parse HEAD)" = "${KCD_COMMIT}" ]; then
  echo "kubeflow/manifests ${KCD_TAG} (${KCD_COMMIT}) already in .cache/manifests"
  exit 0
fi

rm -rf "${DEST}"
mkdir -p "$(dirname "${DEST}")"
git -c advice.detachedHead=false clone -q --depth 1 --branch "${KCD_TAG}" \
  https://github.com/kubeflow/manifests.git "${DEST}"
got="$(git -C "${DEST}" rev-parse HEAD)"
if [ "${got}" != "${KCD_COMMIT}" ]; then
  echo "kubeflow/manifests tag ${KCD_TAG} points at ${got}, expected ${KCD_COMMIT}" >&2
  exit 1
fi
echo "kubeflow/manifests ${KCD_TAG} (${got}) in .cache/manifests"
