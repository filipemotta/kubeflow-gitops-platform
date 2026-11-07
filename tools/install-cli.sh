#!/usr/bin/env bash
# Downloads the pinned CLIs used by the lab into ./bin (gitignored), each one
# checked against the SHA-256 published with its release, and creates a Python
# virtualenv in ./.venv with the Kubeflow Pipelines SDK.
# Idempotent: a binary is only downloaded when missing or at another version.
# Supports darwin/linux on arm64/amd64. No sudo, nothing outside the repo.
# Prerequisites: Docker, curl, tar, jq, python3 (3.10+), git.
set -euo pipefail

KUBECTL_VERSION="v1.35.10"   # nodes run v1.35.8; kubectl skew +/-1 is supported
KIND_VERSION="v0.33.0"       # the kind release the Kubeflow 26.10.0 CI uses
KUSTOMIZE_VERSION="v5.8.1"   # the kustomize release the Kubeflow 26.10.0 CI uses
CRANE_VERSION="v0.22.1"      # registry client for the linux/arm64 image scan
KFP_VERSION="2.18.0"         # Kubeflow Pipelines SDK, same as the KFP backend in 26.10.0

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${REPO_ROOT}/bin"
mkdir -p "${BIN}"

case "$(uname -s)" in
  Darwin) OS="darwin" ;;
  Linux)  OS="linux" ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="amd64" ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

have_version() { # $1 binary, $2 expected substring of the version output, rest: version args
  local out
  [ -x "${BIN}/$1" ] || return 1
  out="$("${BIN}/$1" "${@:3}" 2>/dev/null)" || return 1
  [[ "${out}" == *"$2"* ]]
}
sha256_of() { local s; s="$(shasum -a 256 "$1" 2>/dev/null || sha256sum "$1")"; printf '%s' "${s%% *}"; }
# check_sha <file> <expected sha256> <name>
check_sha() {
  local got
  got="$(sha256_of "$1")"
  if [ -z "$2" ] || [ "$2" != "${got}" ]; then
    echo "$3: checksum mismatch (want ${2:-none}, got ${got})" >&2
    exit 1
  fi
}

if have_version kubectl "${KUBECTL_VERSION}" version --client; then
  echo "kubectl ${KUBECTL_VERSION} already in bin/"
else
  echo "downloading kubectl ${KUBECTL_VERSION} (${OS}/${ARCH})"
  tmp="$(mktemp -d)"
  base="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}"
  curl -sSfL "${base}/kubectl" -o "${tmp}/kubectl"
  check_sha "${tmp}/kubectl" "$(curl -sSfL "${base}/kubectl.sha256" | awk '{ print $1 }')" kubectl
  mv "${tmp}/kubectl" "${BIN}/kubectl"
  chmod +x "${BIN}/kubectl"
  rm -rf "${tmp}"
fi

if have_version kind "${KIND_VERSION} " version; then
  echo "kind ${KIND_VERSION} already in bin/"
else
  echo "downloading kind ${KIND_VERSION} (${OS}-${ARCH})"
  tmp="$(mktemp -d)"
  base="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}"
  curl -sSfL "${base}/kind-${OS}-${ARCH}" -o "${tmp}/kind"
  check_sha "${tmp}/kind" "$(curl -sSfL "${base}/kind-${OS}-${ARCH}.sha256sum" | awk '{ print $1 }')" kind
  mv "${tmp}/kind" "${BIN}/kind"
  chmod +x "${BIN}/kind"
  rm -rf "${tmp}"
fi

if have_version kustomize "${KUSTOMIZE_VERSION}" version; then
  echo "kustomize ${KUSTOMIZE_VERSION} already in bin/"
else
  echo "downloading kustomize ${KUSTOMIZE_VERSION} (${OS}_${ARCH})"
  tmp="$(mktemp -d)"
  pkg="kustomize_${KUSTOMIZE_VERSION}_${OS}_${ARCH}.tar.gz"
  base="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}"
  curl -sSfL "${base}/${pkg}" -o "${tmp}/${pkg}"
  check_sha "${tmp}/${pkg}" "$(curl -sSfL "${base}/checksums.txt" | awk -v p="${pkg}" '$2 == p { print $1 }')" kustomize
  tar -xzf "${tmp}/${pkg}" -C "${tmp}" kustomize
  mv "${tmp}/kustomize" "${BIN}/kustomize"
  chmod +x "${BIN}/kustomize"
  rm -rf "${tmp}"
fi

if have_version crane "${CRANE_VERSION#v}" version; then
  echo "crane ${CRANE_VERSION} already in bin/"
else
  case "${OS}/${ARCH}" in
    darwin/arm64) asset="go-containerregistry_Darwin_arm64.tar.gz" ;;
    darwin/amd64) asset="go-containerregistry_Darwin_x86_64.tar.gz" ;;
    linux/arm64)  asset="go-containerregistry_Linux_arm64.tar.gz" ;;
    linux/amd64)  asset="go-containerregistry_Linux_x86_64.tar.gz" ;;
  esac
  echo "downloading crane ${CRANE_VERSION} (${asset})"
  tmp="$(mktemp -d)"
  base="https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}"
  curl -sSfL "${base}/${asset}" -o "${tmp}/${asset}"
  check_sha "${tmp}/${asset}" "$(curl -sSfL "${base}/checksums.txt" | awk -v p="${asset}" '$2 == p { print $1 }')" crane
  tar -xzf "${tmp}/${asset}" -C "${tmp}" crane
  mv "${tmp}/crane" "${BIN}/crane"
  chmod +x "${BIN}/crane"
  rm -rf "${tmp}"
fi

# Python SDK of Kubeflow Pipelines (+ the kfp-kubernetes extension for the
# Secret mounted in the PR step), used to compile and submit the pipeline.
VENV="${REPO_ROOT}/.venv"
if [ -x "${VENV}/bin/python" ] && "${VENV}/bin/python" -c "import kfp, kfp.kubernetes, sys; sys.exit(kfp.__version__ != '${KFP_VERSION}')" 2>/dev/null; then
  echo "kfp ${KFP_VERSION} already in .venv/"
else
  echo "creating .venv with kfp==${KFP_VERSION}"
  python3 -m venv "${VENV}"
  "${VENV}/bin/pip" install -q --disable-pip-version-check "kfp==${KFP_VERSION}" "kfp-kubernetes==${KFP_VERSION}"
fi

echo "binaries in ${BIN}:"
"${BIN}/kubectl" version --client | sed -n 1p
"${BIN}/kind" version
echo "kustomize $("${BIN}/kustomize" version)"
echo "crane $("${BIN}/crane" version)"
echo "kfp $("${VENV}/bin/python" -c 'import kfp; print(kfp.__version__)')"
