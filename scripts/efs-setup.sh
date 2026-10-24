#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Terakube — EFS provisioning for EKS
#
# Provisions everything the chart's EFS StorageClass needs, in order:
#   1. EKS OIDC provider (IRSA prerequisite)
#   2. IAM role for the EFS CSI driver (AmazonEFSCSIDriverPolicy, IRSA trust)
#   3. EKS add-on: aws-efs-csi-driver (bound to that role)
#   4. EFS filesystem
#   5. EFS mount targets on the cluster's node subnets (auto-discovered)
#   6. Prints the filesystem id (FS_ID) for Helm --set storage.fileSystemId
#
# Usage:
#   ./efs-setup.sh <CLUSTER_NAME> <AWS_REGION>
# Writes the resulting fs-id to stdout on the last line as: FS_ID=fs-xxxx
# =============================================================================

CLUSTER_NAME="${1:?cluster name required}"
AWS_REGION="${2:?aws region required}"
# Optional 3rd arg: an EXISTING EFS filesystem id. When given, we validate and
# reuse it (never create a new one) but still ensure the OIDC provider, EFS-CSI
# IAM role, driver add-on and per-AZ mount targets exist for it.
EXISTING_FS_ID="${3:-}"
EFS_NAME="terakube-efs-${CLUSTER_NAME}"
CSI_ROLE_NAME="terakube-efs-csi-role-${CLUSTER_NAME}"
CSI_SA_NS="kube-system"
CSI_SA_NAME="efs-csi-controller-sa"

log() { echo "[efs] $*" >&2; }

for bin in aws kubectl jq; do
  command -v "$bin" >/dev/null 2>&1 || { log "ERROR: '$bin' not found"; exit 1; }
done

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
log "AWS account: $ACCOUNT_ID"

# ---------------------------------------------------------------------------
# 1. OIDC provider
# ---------------------------------------------------------------------------
log "[1/6] Ensuring EKS OIDC provider..."
OIDC_ISSUER="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.identity.oidc.issuer' --output text)"
OIDC_HOST="${OIDC_ISSUER#https://}"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"

if aws iam list-open-id-connect-providers \
     --query "OpenIDConnectProviderList[?Arn=='${OIDC_ARN}'].Arn | [0]" \
     --output text | grep -q "$OIDC_ARN"; then
  log "  OIDC provider exists"
else
  if command -v eksctl >/dev/null 2>&1; then
    eksctl utils associate-iam-oidc-provider --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --approve
  else
    THUMBPRINT="$(echo | openssl s_client -servername "${OIDC_HOST%%/*}" -showcerts \
      -connect "${OIDC_HOST%%/*}:443" 2>/dev/null \
      | awk '/BEGIN CERTIFICATE/{i++} {print > ("/tmp/efs-oidc-" i ".pem")}' \
      && openssl x509 -in "$(ls -1 /tmp/efs-oidc-*.pem | tail -1)" -noout -fingerprint -sha1 \
      | sed 's/.*=//; s/://g' | tr '[:upper:]' '[:lower:]')"
    aws iam create-open-id-connect-provider --url "$OIDC_ISSUER" \
      --client-id-list sts.amazonaws.com --thumbprint-list "$THUMBPRINT" >/dev/null
    log "  OIDC provider created"
  fi
fi

# ---------------------------------------------------------------------------
# 2. IAM role for the EFS CSI driver (IRSA)
# ---------------------------------------------------------------------------
log "[2/6] Ensuring EFS CSI IAM role..."
TRUST="$(mktemp)"
cat > "$TRUST" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_HOST}:aud": "sts.amazonaws.com",
        "${OIDC_HOST}:sub": "system:serviceaccount:${CSI_SA_NS}:${CSI_SA_NAME}"
      }
    }
  }]
}
JSON

if aws iam get-role --role-name "$CSI_ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$CSI_ROLE_NAME" --policy-document "file://$TRUST" >/dev/null
  log "  Role exists (trust refreshed)"
else
  aws iam create-role --role-name "$CSI_ROLE_NAME" --assume-role-policy-document "file://$TRUST" >/dev/null
  log "  Role created"
fi
aws iam attach-role-policy --role-name "$CSI_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy >/dev/null 2>&1 || true
CSI_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CSI_ROLE_NAME}"

# ---------------------------------------------------------------------------
# 3. EKS add-on: aws-efs-csi-driver (bound to the role)
# ---------------------------------------------------------------------------
log "[3/6] Ensuring aws-efs-csi-driver add-on..."
if aws eks describe-addon --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
     --addon-name aws-efs-csi-driver >/dev/null 2>&1; then
  aws eks update-addon --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --addon-name aws-efs-csi-driver --service-account-role-arn "$CSI_ROLE_ARN" \
    --resolve-conflicts OVERWRITE >/dev/null 2>&1 || true
  log "  Add-on exists (role bound)"
else
  aws eks create-addon --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --addon-name aws-efs-csi-driver --service-account-role-arn "$CSI_ROLE_ARN" \
    --resolve-conflicts OVERWRITE >/dev/null
  log "  Add-on created"
fi

# ---------------------------------------------------------------------------
# 4. EFS filesystem (reuse by name tag if it already exists)
# ---------------------------------------------------------------------------
log "[4/6] Ensuring EFS filesystem ($EFS_NAME)..."
if [[ -n "$EXISTING_FS_ID" ]]; then
  # Caller supplied an existing filesystem id — validate it and reuse it.
  # We must NOT create a new filesystem in this mode.
  FS_STATE="$(aws efs describe-file-systems --region "$AWS_REGION" --file-system-id "$EXISTING_FS_ID" \
    --query 'FileSystems[0].LifeCycleState' --output text 2>/dev/null || echo "None")"
  if [[ -z "$FS_STATE" || "$FS_STATE" == "None" ]]; then
    log "ERROR: EFS filesystem '$EXISTING_FS_ID' not found in region $AWS_REGION"; exit 1
  fi
  FS_ID="$EXISTING_FS_ID"
  log "  Using existing filesystem $FS_ID (state=$FS_STATE)"
else
FS_ID="$(aws efs describe-file-systems --region "$AWS_REGION" \
  --query "FileSystems[?Name=='${EFS_NAME}'].FileSystemId | [0]" --output text 2>/dev/null || echo "None")"
if [[ -z "$FS_ID" || "$FS_ID" == "None" ]]; then
  FS_ID="$(aws efs create-file-system --region "$AWS_REGION" \
    --performance-mode generalPurpose --throughput-mode bursting --encrypted \
    --tags "Key=Name,Value=${EFS_NAME}" \
    --query 'FileSystemId' --output text)"
  log "  Created filesystem $FS_ID (waiting for available)"
  for _ in $(seq 1 30); do
    st="$(aws efs describe-file-systems --region "$AWS_REGION" --file-system-id "$FS_ID" \
      --query 'FileSystems[0].LifeCycleState' --output text)"
    [[ "$st" == "available" ]] && break; sleep 5
  done
else
  log "  Reusing filesystem $FS_ID"
fi
fi

# ---------------------------------------------------------------------------
# 5. Mount targets on the cluster's node subnets + a shared SG allowing NFS
# ---------------------------------------------------------------------------
log "[5/6] Discovering cluster subnets + creating mount targets..."
VPC_ID="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)"

# Collect ALL candidate subnets so we cover every availability zone a pod/node
# could land in — not just where a node happens to run right now. EFS allows one
# mount target PER AZ, so we must pick one subnet per distinct AZ.
#
# Candidates = the cluster's configured subnets + the subnets of any running
# nodes (covers Karpenter/nodegroup subnets that aren't in the EKS config).
CLUSTER_SUBNETS="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.subnetIds' --output text 2>/dev/null | tr '\t' '\n' | sort -u || true)"
NODE_RUN_SUBNETS="$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned,shared" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].SubnetId' --output text 2>/dev/null | tr '\t' '\n' | sort -u || true)"
CANDIDATE_SUBNETS="$(printf '%s\n%s\n' "$CLUSTER_SUBNETS" "$NODE_RUN_SUBNETS" | grep -v '^$' | sort -u)"

if [[ -z "$CANDIDATE_SUBNETS" ]]; then
  log "ERROR: could not discover any cluster subnets"; exit 1
fi

# Describe candidates once: subnet id, AZ, and whether it maps public IPs
# (public subnet). Pick exactly ONE subnet per AZ, preferring PRIVATE subnets
# (EFS mount targets belong in private space; public is used only if an AZ has
# no private subnet).
SUBNET_INFO="$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --subnet-ids $CANDIDATE_SUBNETS \
  --query 'Subnets[].[SubnetId,AvailabilityZone,MapPublicIpOnLaunch]' --output text)"
# SUBNET_INFO lines: "<subnet>\t<az>\t<True|False>"

# For each AZ, choose a private subnet if available, else any subnet.
MT_SUBNETS=""   # final: one subnet per AZ
AZS_SEEN=""
# First pass: private subnets (MapPublicIpOnLaunch == False)
while IFS=$'\t' read -r s az pub; do
  [[ -z "$s" ]] && continue
  if [[ "$pub" == "False" ]] && ! echo " $AZS_SEEN " | grep -q " $az "; then
    MT_SUBNETS="$MT_SUBNETS $s"; AZS_SEEN="$AZS_SEEN $az"
  fi
done <<< "$SUBNET_INFO"
# Second pass: fill any AZ still missing (only public subnets exist there)
while IFS=$'\t' read -r s az pub; do
  [[ -z "$s" ]] && continue
  if ! echo " $AZS_SEEN " | grep -q " $az "; then
    MT_SUBNETS="$MT_SUBNETS $s"; AZS_SEEN="$AZS_SEEN $az"
    log "  AZ $az has no private subnet — using public subnet $s for its mount target"
  fi
done <<< "$SUBNET_INFO"

NODE_SUBNETS="$(echo $MT_SUBNETS | tr ' ' '\n' | grep -v '^$' | sort -u)"
log "  Availability zones covered:$AZS_SEEN"
log "  Mount-target subnets (one per AZ): $(echo "$NODE_SUBNETS" | tr '\n' ' ')"

# Security group that allows NFS (2049) from within the VPC CIDR.
SG_NAME="terakube-efs-sg-${CLUSTER_NAME}"
SG_ID="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")"
if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
  SG_ID="$(aws ec2 create-security-group --region "$AWS_REGION" \
    --group-name "$SG_NAME" --description "Terakube EFS NFS access" --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)"
  VPC_CIDR="$(aws ec2 describe-vpcs --region "$AWS_REGION" --vpc-ids "$VPC_ID" \
    --query 'Vpcs[0].CidrBlock' --output text)"
  aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_ID" \
    --protocol tcp --port 2049 --cidr "$VPC_CIDR" >/dev/null 2>&1 || true
  log "  Created EFS security group $SG_ID (NFS 2049 from $VPC_CIDR)"
else
  log "  Reusing EFS security group $SG_ID"
fi

# Existing mount targets — track both subnet and AZ (EFS allows only ONE mount
# target per AZ, so we must not attempt a second one in an AZ already covered).
EXISTING_MT_SUBNETS="$(aws efs describe-mount-targets --region "$AWS_REGION" --file-system-id "$FS_ID" \
  --query 'MountTargets[].SubnetId' --output text 2>/dev/null | tr '\t' '\n' | sort -u || true)"
EXISTING_MT_AZS="$(aws efs describe-mount-targets --region "$AWS_REGION" --file-system-id "$FS_ID" \
  --query 'MountTargets[].AvailabilityZoneName' --output text 2>/dev/null | tr '\t' '\n' | sort -u || true)"

created=0
for SUBNET in $NODE_SUBNETS; do
  # Resolve this subnet's AZ.
  AZ="$(echo "$SUBNET_INFO" | awk -v s="$SUBNET" '$1==s{print $2; exit}')"
  if echo "$EXISTING_MT_SUBNETS" | grep -q "^${SUBNET}$"; then
    log "  mount target already in $SUBNET ($AZ)"
    continue
  fi
  if [[ -n "$AZ" ]] && echo "$EXISTING_MT_AZS" | grep -q "^${AZ}$"; then
    log "  AZ $AZ already has a mount target — skipping $SUBNET"
    continue
  fi
  if aws efs create-mount-target --region "$AWS_REGION" --file-system-id "$FS_ID" \
       --subnet-id "$SUBNET" --security-groups "$SG_ID" >/dev/null 2>&1; then
    log "  created mount target in $SUBNET ($AZ)"
    EXISTING_MT_AZS="$EXISTING_MT_AZS
$AZ"
    created=$((created+1))
  else
    log "  WARN: could not create mount target in $SUBNET ($AZ)"
  fi
done
log "  mount targets created this run: $created (total AZs now: $(echo "$EXISTING_MT_AZS" | grep -cv '^$'))"

# Wait for all mount targets to become available so the first pod can mount.
log "  waiting for mount targets to become available..."
for _ in $(seq 1 24); do
  PENDING="$(aws efs describe-mount-targets --region "$AWS_REGION" --file-system-id "$FS_ID" \
    --query "length(MountTargets[?LifeCycleState!='available'])" --output text 2>/dev/null || echo 1)"
  [[ "$PENDING" == "0" ]] && { log "  all mount targets available"; break; }
  sleep 5
done

# ---------------------------------------------------------------------------
# 6. Done — emit the filesystem id for Helm
# ---------------------------------------------------------------------------
log "[6/6] EFS ready."
echo "FS_ID=${FS_ID}"

