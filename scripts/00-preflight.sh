#!/usr/bin/env bash
# Step 00: preflight. Checks the machine, fetches the pinned CLIs and
# kubeflow/manifests 26.10.0, renders every stage the lab installs and checks
# that each container image it references has a linux/<node arch> variant.
# Creates nothing in any cluster.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

MIN_CPUS=5
MIN_MEM_MIB=7000
MIN_DISK_GIB=15

step "00 preflight"
bash "${REPO_ROOT}/tools/install-cli.sh" | show
bash "${REPO_ROOT}/tools/fetch-manifests.sh" | show

cpus="$(docker info --format '{{.NCPU}}')"
mem_mib="$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 ))"
arch="$(docker info --format '{{.Architecture}}')"
case "${arch}" in aarch64|arm64) node_arch="arm64" ;; *) node_arch="amd64" ;; esac
disk_gib="$(df -Pk "${REPO_ROOT}" | awk 'NR==2 { print int($4 / 1024 / 1024) }')"
note "docker VM: ${cpus} CPUs, ${mem_mib} MiB, ${arch}; free disk: ${disk_gib} GiB"
expect_ge "docker VM CPUs" "${MIN_CPUS}" "${cpus}"
expect_ge "docker VM memory (MiB)" "${MIN_MEM_MIB}" "${mem_mib}"
expect_ge "free disk (GiB)" "${MIN_DISK_GIB}" "${disk_gib}"
expect_eq "no leftover lab cluster" "" "$(kind get clusters 2>/dev/null | grep -x "${CLUSTER_NAME}" || true)"

# Render every stage once: a kustomize error is found here, not halfway
# through the install.
rendered=()
for dir in "${REPO_ROOT}"/platform/*/; do
  name="$(basename "${dir}")"
  if kustomize build "${dir}" > "${OUT}/render-${name}.yaml" 2> "${OUT}/render-${name}.err"; then
    pass "kustomize build platform/${name} ($(grep -c '^kind:' "${OUT}/render-${name}.yaml") objects)"
    rendered+=("${OUT}/render-${name}.yaml")
  else
    fail "kustomize build platform/${name}: $(head -3 "${OUT}/render-${name}.err")"
  fi
done
for dir in "${REPO_ROOT}"/tenants/*/; do
  name="tenant-$(basename "${dir}")"
  if kustomize build "${dir}" > "${OUT}/render-${name}.yaml" 2> "${OUT}/render-${name}.err"; then
    pass "kustomize build tenants/$(basename "${dir}")"
    rendered+=("${OUT}/render-${name}.yaml")
  else
    fail "kustomize build tenants/$(basename "${dir}"): $(head -3 "${OUT}/render-${name}.err")"
  fi
done

# Images that are not in the manifests but that the lab pulls at run time.
extra_images=(
  "kindest/node:v1.35.8"
  "quay.io/argoproj/argocd:${ARGOCD_VERSION}"
  "docker.gitea.com/gitea:${GITEA_VERSION}-rootless"
  "${PIPELINE_BASE_IMAGE}"
)

"${PY}" "${REPO_ROOT}/tools/list-images.py" "${rendered[@]}" > "${OUT}/images.txt"
printf '%s\n' "${extra_images[@]}" >> "${OUT}/images.txt"
sort -u -o "${OUT}/images.txt" "${OUT}/images.txt"
note "$(wc -l < "${OUT}/images.txt" | tr -d ' ') distinct images referenced"

: > "${OUT}/arch-report.txt"
missing=0
while read -r image; do
  # An image index (multi-platform) and a single-platform image fail
  # differently on a node of another architecture: containerd refuses an
  # index without the node's platform ("no match for platform in manifest"),
  # but pulls a single amd64 image and runs it under emulation.
  kind="index"
  platforms="$(crane manifest "${image}" 2>/dev/null \
    | jq -r 'if .manifests then [.manifests[].platform | select(. != null) | "\(.os)/\(.architecture)"] | join(",") else "single" end' 2>/dev/null || echo "unreachable")"
  if [ "${platforms}" = "single" ]; then
    kind="single"
    platforms="$(crane config "${image}" 2>/dev/null | jq -r '"\(.os)/\(.architecture)"' 2>/dev/null || echo "unreachable")"
  fi
  printf '%s %s %s\n' "${image}" "${platforms}" "${kind}" >> "${OUT}/arch-report.txt"
  if [[ ",${platforms}," != *",linux/${node_arch},"* ]]; then
    missing=$((missing + 1))
    note "no linux/${node_arch}: ${image} (${platforms})"
  fi
done < "${OUT}/images.txt"
note "images without linux/${node_arch}: ${missing} (report: out/arch-report.txt)"
echo "${missing}" > "${OUT}/arch-missing.txt"

finish
