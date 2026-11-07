#!/usr/bin/env bash
# Step 11: what the lab cannot run (no GPU, no AWS) is still validated against
# the real schemas: the Karpenter v1.15.1 CRDs are installed in the kind
# cluster, the GPU NodePool and EC2NodeClass go through a server-side dry run
# (schema + CEL validation rules of the CRDs), and the CRDs are removed again.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
assert_lab_context

KARPENTER_VERSION="v1.15.1"
CRDS="https://raw.githubusercontent.com/aws/karpenter-provider-aws/${KARPENTER_VERSION}/pkg/apis/crds"

step "11 static validation of what the lab does not run"
k apply --server-side -f "${CRDS}/karpenter.sh_nodepools.yaml" -f "${CRDS}/karpenter.k8s.aws_ec2nodeclasses.yaml" | show
k wait --for=condition=Established crd/nodepools.karpenter.sh crd/ec2nodeclasses.karpenter.k8s.aws --timeout=60s | show

out="$(k apply --dry-run=server -f "${REPO_ROOT}/karpenter/gpu-nodepool.yaml" 2>&1)" && rc=0 || rc=$?
expect_eq "GPU NodePool + EC2NodeClass accepted by the Karpenter ${KARPENTER_VERSION} CRDs (dry run)" "0" "${rc}"
note "${out}"

# The same CRDs refuse a broken spec: proof the dry run checks something.
refused "a NodePool with an invalid consolidationPolicy is refused by the CRD" "Unsupported value|should be one of|consolidationPolicy" \
  sh -c "sed 's/consolidationPolicy: WhenEmpty/consolidationPolicy: WhenIdle/' '${REPO_ROOT}/karpenter/gpu-nodepool.yaml' | kubectl --context ${KUBE_CONTEXT} apply --dry-run=server -f -"

k delete crd nodepools.karpenter.sh ec2nodeclasses.karpenter.k8s.aws --wait=false | show
finish
