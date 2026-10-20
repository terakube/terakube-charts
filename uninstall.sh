#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Terakube — uninstaller
#
# 1. helm uninstall the release (removes core/UI/ML, services, PVC, StorageClass,
#    RBAC, ServiceAccount).
# 2. Optionally tear down the AWS EFS + IAM resources created by install.sh.
#    This is DESTRUCTIVE (deletes the EFS filesystem and its data) and is only
#    done after an explicit confirmation.
#
# Usage: ./uninstall.sh [helm-release-name]   (default release: terakube)
# =============================================================================

HERE="$(cd "$(dirname "$0")" && pwd)"
RELEASE="${1:-terakube}"
NAMESPACE="terakube-core"

command -v helm >/dev/null 2>&1 || { echo "ERROR: helm not found"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }

echo "=============================================="
echo "  Terakube uninstaller"
echo "=============================================="
echo

# ---------------------------------------------------------------------------
# 1. Helm uninstall
# ---------------------------------------------------------------------------
if helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "[helm] uninstalling release '$RELEASE' in namespace '$NAMESPACE'..."
  helm uninstall "$RELEASE" -n "$NAMESPACE" || true
else
  echo "[helm] release '$RELEASE' not found in '$NAMESPACE' (skipping helm uninstall)"
fi

# The PVC/StorageClass are part of the chart and removed by helm uninstall, but
# a PVC with data may linger if finalizers are slow — report it.
if kubectl get pvc terakube-core-data -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "[k8s] PVC terakube-core-data still present; deleting..."
  kubectl delete pvc terakube-core-data -n "$NAMESPACE" --wait=false || true
fi

read -r -p "Also delete the namespace '$NAMESPACE'? (yes/no): " DEL_NS
DEL_NS="$(echo "${DEL_NS:-no}" | tr '[:upper:]' '[:lower:]')"
if [[ "$DEL_NS" == "yes" || "$DEL_NS" == "y" ]]; then
  kubectl delete namespace "$NAMESPACE" --wait=false || true
  echo "[k8s] namespace deletion requested"
fi
echo

# ---------------------------------------------------------------------------
# 2. Optional AWS teardown (EFS + IAM) — DESTRUCTIVE
# ---------------------------------------------------------------------------
read -r -p "Tear down AWS EFS + IAM resources created by install.sh? (yes/no): " DO_AWS
DO_AWS="$(echo "${DO_AWS:-no}" | tr '[:upper:]' '[:lower:]')"
if [[ "$DO_AWS" != "yes" && "$DO_AWS" != "y" ]]; then
  echo "Leaving AWS resources in place. Done."
  exit 0
fi

for bin in aws; do command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' required for AWS teardown"; exit 1; }; done
read -r -p "  AWS Region: " AWS_REGION
read -r -p "  EKS Cluster Name: " CLUSTER_NAME
: "${AWS_REGION:?region required}"; : "${CLUSTER_NAME:?cluster name required}"

EFS_NAME="terakube-efs-${CLUSTER_NAME}"
SG_NAME="terakube-efs-sg-${CLUSTER_NAME}"
CSI_ROLE_NAME="terakube-efs-csi-role-${CLUSTER_NAME}"
IRSA_ROLE_NAME="terakube-core-irsa-role"
POLICY_NAME="terakube-core-policy"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

echo
echo "  !! This DELETES the EFS filesystem '$EFS_NAME' and ALL its data. !!"
read -r -p "  Type the cluster name again to confirm: " CONFIRM
if [[ "$CONFIRM" != "$CLUSTER_NAME" ]]; then
  echo "  Confirmation mismatch — aborting AWS teardown."; exit 1
fi

# ---- EFS filesystem + mount targets ----
FS_ID="$(aws efs describe-file-systems --region "$AWS_REGION" \
  --query "FileSystems[?Name=='${EFS_NAME}'].FileSystemId | [0]" --output text 2>/dev/null || echo "None")"
if [[ -n "$FS_ID" && "$FS_ID" != "None" ]]; then
  echo "[efs] deleting mount targets for $FS_ID..."
  for MT in $(aws efs describe-mount-targets --region "$AWS_REGION" --file-system-id "$FS_ID" \
      --query 'MountTargets[].MountTargetId' --output text 2>/dev/null); do
    aws efs delete-mount-target --region "$AWS_REGION" --mount-target-id "$MT" >/dev/null 2>&1 || true
    echo "  deleted mount target $MT"
  done
  echo "[efs] waiting for mount targets to drain..."
  for _ in $(seq 1 24); do
    n="$(aws efs describe-mount-targets --region "$AWS_REGION" --file-system-id "$FS_ID" \
      --query 'length(MountTargets)' --output text 2>/dev/null || echo 0)"
    [[ "$n" == "0" ]] && break; sleep 5
  done
  aws efs delete-file-system --region "$AWS_REGION" --file-system-id "$FS_ID" >/dev/null 2>&1 \
    && echo "[efs] deleted filesystem $FS_ID" || echo "[efs] WARN: could not delete $FS_ID (retry after MTs drain)"
else
  echo "[efs] no filesystem named $EFS_NAME found"
fi

# ---- Security group ----
VPC_ID="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo "")"
if [[ -n "$VPC_ID" ]]; then
  SG_ID="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")"
  if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
    # SG can't be deleted until its ENIs (mount targets) are gone; retry a few times.
    for _ in $(seq 1 12); do
      aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$SG_ID" >/dev/null 2>&1 \
        && { echo "[sg] deleted $SG_ID"; break; } || sleep 5
    done
  fi
fi

# ---- EFS CSI add-on + role ----
read -r -p "  Also remove the aws-efs-csi-driver add-on + its IAM role? (yes/no): " DEL_CSI
DEL_CSI="$(echo "${DEL_CSI:-no}" | tr '[:upper:]' '[:lower:]')"
if [[ "$DEL_CSI" == "yes" || "$DEL_CSI" == "y" ]]; then
  aws eks delete-addon --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --addon-name aws-efs-csi-driver >/dev/null 2>&1 && echo "[addon] delete requested" || true
  aws iam detach-role-policy --role-name "$CSI_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy >/dev/null 2>&1 || true
  aws iam delete-role --role-name "$CSI_ROLE_NAME" >/dev/null 2>&1 \
    && echo "[iam] deleted $CSI_ROLE_NAME" || true
fi

# ---- Core IRSA role + policy ----
read -r -p "  Also remove the terakube-core IRSA role + policy? (yes/no): " DEL_IRSA
DEL_IRSA="$(echo "${DEL_IRSA:-no}" | tr '[:upper:]' '[:lower:]')"
if [[ "$DEL_IRSA" == "yes" || "$DEL_IRSA" == "y" ]]; then
  POLICY_ARN="$(aws iam list-policies --scope Local \
    --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn | [0]" --output text 2>/dev/null || echo "None")"
  if [[ -n "$POLICY_ARN" && "$POLICY_ARN" != "None" ]]; then
    aws iam detach-role-policy --role-name "$IRSA_ROLE_NAME" --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
  fi
  aws iam delete-role --role-name "$IRSA_ROLE_NAME" >/dev/null 2>&1 \
    && echo "[iam] deleted $IRSA_ROLE_NAME" || true
  if [[ -n "$POLICY_ARN" && "$POLICY_ARN" != "None" ]]; then
    # Delete non-default versions first, then the policy.
    for V in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
        --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null); do
      aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$V" >/dev/null 2>&1 || true
    done
    aws iam delete-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1 \
      && echo "[iam] deleted policy $POLICY_NAME" || true
  fi
fi

echo
echo "=============================================="
echo "  Teardown complete."
echo "=============================================="
