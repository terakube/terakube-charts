#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Terakube — one-click installer (core + UI + EFS persistence)
#
# Flow:
#   1. Ask whether to provision EFS (yes/no).
#      - yes → ask region + cluster name → run scripts/efs-setup.sh which:
#              OIDC provider · EFS-CSI IAM role · aws-efs-csi-driver add-on ·
#              EFS filesystem · mount targets on auto-discovered node subnets.
#              The resulting fs-id is passed to Helm.
#      - no  → continue; you must supply storage.fileSystemId yourself (or set
#              storage.create=false if a StorageClass already exists).
#   2. helm upgrade --install the chart.
#   3. Run scripts/terakube-irsa-setup.sh AFTER the app is deployed, to wire the
#      core's least-privilege IAM (IRSA).
#
# Usage: ./install.sh [helm-release-name]   (default release: terakube)
# =============================================================================

HERE="$(cd "$(dirname "$0")" && pwd)"
HELMURL="oci://ghcr.io/terakube/charts/terakube"
RELEASE="${1:-terakube}"
NAMESPACE="terakube-core"

for bin in helm kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found"; exit 1; }
done

echo "=============================================="
echo "  Terakube installer (core + UI + EFS)"
echo "=============================================="
echo

HELM_EFS_ARGS=()

read -r -p "Provision EFS persistence now? (yes/no): " DO_EFS
DO_EFS="$(echo "${DO_EFS:-no}" | tr '[:upper:]' '[:lower:]')"

if [[ "$DO_EFS" == "yes" || "$DO_EFS" == "y" ]]; then
  for bin in aws jq; do
    command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' required for EFS setup"; exit 1; }
  done
  read -r -p "  AWS Region (e.g. us-east-1): " AWS_REGION
  read -r -p "  EKS Cluster Name: " CLUSTER_NAME
  export AWS_REGION CLUSTER_NAME

  echo "  Provisioning EFS (this calls AWS APIs)..."
  EFS_OUT="$(bash "$HERE/scripts/efs-setup.sh" "$CLUSTER_NAME" "$AWS_REGION")"
  FS_ID="$(echo "$EFS_OUT" | grep '^FS_ID=' | cut -d= -f2)"
  if [[ -z "$FS_ID" ]]; then
    echo "ERROR: EFS setup did not return a filesystem id"; exit 1
  fi
  echo "  EFS filesystem: $FS_ID"
  HELM_EFS_ARGS+=(--set "storage.create=true" --set "storage.fileSystemId=${FS_ID}")
else
  echo "  Skipping EFS provisioning (not creating a new filesystem)."
  echo "  NOTE: Helm needs an EFS filesystem id. Either:"
  echo "    - give an existing one below (recommended — we'll validate it), or"
  echo "    - reuse an existing StorageClass: --set storage.create=false --set storage.className=<existing>"
  read -r -p "  Enter an existing EFS filesystem id (or leave blank to manage storage yourself): " FS_ID
  if [[ -n "$FS_ID" ]]; then
    # An existing filesystem is NOT enough on its own: pods still need the IRSA
    # prerequisites (OIDC provider, EFS-CSI IAM role, aws-efs-csi-driver add-on)
    # and a mount target in EVERY availability zone the cluster schedules into.
    # Previously we jumped straight to `helm upgrade`, so on a fresh cluster the
    # driver was missing and/or the filesystem had no mount target in the node
    # AZs → every PVC stayed Pending. Run efs-setup.sh against the PROVIDED id:
    # it validates the filesystem, ensures the prerequisites, and creates only
    # the missing per-AZ mount targets (it never creates a new filesystem).
    for bin in aws kubectl jq; do
      command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required to prepare an existing EFS filesystem"; exit 1; }
    done
    read -r -p "  AWS Region (e.g. us-east-1): " AWS_REGION
    read -r -p "  EKS Cluster Name: " CLUSTER_NAME
    export AWS_REGION CLUSTER_NAME
    echo "  Validating EFS $FS_ID and ensuring OIDC / EFS-CSI IAM role / driver add-on / per-AZ mount targets..."
    EFS_OUT="$(bash "$HERE/scripts/efs-setup.sh" "$CLUSTER_NAME" "$AWS_REGION" "$FS_ID")"
    FS_ID="$(echo "$EFS_OUT" | grep '^FS_ID=' | cut -d= -f2)"
    if [[ -z "$FS_ID" ]]; then
      echo "ERROR: preparing the existing EFS filesystem failed"; exit 1
    fi
    echo "  EFS $FS_ID is ready (prerequisites + mount targets ensured)."
    HELM_EFS_ARGS+=(--set "storage.create=true" --set "storage.fileSystemId=${FS_ID}")
  else
    echo "  No EFS id provided — you are managing storage yourself."
  fi
fi
echo

# ---------------------------------------------------------------------------
# Deploy the application
# ---------------------------------------------------------------------------
echo "[deploy] helm upgrade --install $RELEASE ..."
helm upgrade --install "$RELEASE" $HELMURL \
  --namespace "$NAMESPACE" --create-namespace \
  "${HELM_EFS_ARGS[@]}" "${@:2}"

# ---------------------------------------------------------------------------
# IRSA — run AFTER the application is deployed
# ---------------------------------------------------------------------------
echo "[irsa] configuring least-privilege IAM for terakube-core..."
if [[ -n "${CLUSTER_NAME:-}" && -n "${AWS_REGION:-}" ]]; then
  # Cluster + region already known (from either the provision or existing-EFS
  # path) → run non-interactively.
  CLUSTER_NAME="${CLUSTER_NAME}" AWS_REGION="${AWS_REGION}" NONINTERACTIVE=1 \
    bash "$HERE/scripts/terakube-irsa-setup.sh" || echo "[irsa] WARN: IRSA setup returned non-zero"
else
  echo "[irsa] launching interactive IRSA setup (enter cluster/region when asked)..."
  bash "$HERE/scripts/terakube-irsa-setup.sh" || echo "[irsa] WARN: IRSA setup returned non-zero"
fi

#echo "[deploy] waiting for core rollout..."
#kubectl -n "$NAMESPACE" rollout status deploy/terakube-core --timeout=300s || true
#echo


echo
echo "=============================================="
echo "  Terakube install complete."
echo "  Namespace: $NAMESPACE"
echo "  Check:  kubectl -n $NAMESPACE get pods,svc,pvc"
echo "=============================================="

