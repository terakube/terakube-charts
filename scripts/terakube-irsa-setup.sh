#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Terakube Core - EKS IRSA Setup (Karpenter-compatible)
#
# Works with BOTH cluster node-provisioning models:
#   - Managed nodegroups (one or MANY)
#   - Karpenter (nodes come from a Karpenter NodeRole / instance profile)
#   - BOTH at once (collects every nodegroup role + the Karpenter role)
#
# It auto-detects which model the cluster uses and restricts iam:PassRole to the
# correct node role in each case. The security model is unchanged: PassRole is
# scoped to exactly the node role(s) the cluster actually uses, and only to
# ec2.amazonaws.com / eks.amazonaws.com.
# =============================================================================

echo "=============================="
echo "Terakube Core - EKS IRSA Setup (Karpenter-compatible)"
echo "=============================="
echo

NAMESPACE="terakube-core"
SERVICE_ACCOUNT="terakube-app-service-account"
DEPLOYMENT_NAME="terakube-core"

if [[ -z "${CLUSTER_NAME:-}" ]]; then read -r -p "Enter EKS Cluster Name (e.g. client-eks-prod): " CLUSTER_NAME; fi
if [[ -z "${AWS_REGION:-}" ]]; then read -r -p "Enter AWS Region (e.g. us-east-1): " AWS_REGION; fi
if [[ -z "${POLICY_NAME:-}" ]]; then read -r -p "Enter IAM Policy Name (default: terakube-core-policy): " POLICY_NAME; fi
POLICY_NAME="${POLICY_NAME:-terakube-core-policy}"
if [[ -z "${ROLE_NAME:-}" ]]; then read -r -p "Enter IAM Role Name for IRSA (default: terakube-core-irsa-role): " ROLE_NAME; fi
ROLE_NAME="${ROLE_NAME:-terakube-core-irsa-role}"

# Optional: if auto-detection can't find the Karpenter node role, the operator
# can supply it explicitly.
if [[ -z "${KARPENTER_NODE_ROLE_NAME:-}" && "${NONINTERACTIVE:-}" != "1" ]]; then read -r -p "Karpenter Node Role name (leave blank to auto-detect): " KARPENTER_NODE_ROLE_NAME || true; fi

echo
echo "Using:"
echo "  Cluster:     $CLUSTER_NAME"
echo "  Region:      $AWS_REGION"
echo "  Namespace:   $NAMESPACE"
echo "  SA:          $SERVICE_ACCOUNT"
echo "  PolicyName:  $POLICY_NAME"
echo "  RoleName:    $ROLE_NAME"
echo

for bin in aws kubectl openssl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found"; exit 1; }
done

echo "[0/12] Getting AWS Account ID..."
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "AWS Account: $AWS_ACCOUNT_ID"
echo

# ------------------------------------------------------------------
# DISCOVER NODE ROLE(S) — nodegroup and/or Karpenter
# ------------------------------------------------------------------
echo "[1/12] Detecting node provisioning model + node role(s)..."

NODE_ROLE_ARNS=()   # collect every node role we must be able to PassRole

# 1) Managed nodegroups — collect the node role of EVERY nodegroup (a cluster
#    can have several, possibly with different roles). Supports clusters that
#    use nodegroups, Karpenter, or BOTH at the same time.
ALL_NODEGROUPS="$(
  aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'nodegroups[]' --output text 2>/dev/null || echo ""
)"
if [[ -n "$ALL_NODEGROUPS" && "$ALL_NODEGROUPS" != "None" ]]; then
  for NG in $ALL_NODEGROUPS; do
    echo "  Found managed nodegroup: $NG"
    NG_ROLE_ARN="$(
      aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" \
        --nodegroup-name "$NG" --region "$AWS_REGION" \
        --query 'nodegroup.nodeRole' --output text 2>/dev/null || echo "None"
    )"
    if [[ -n "$NG_ROLE_ARN" && "$NG_ROLE_ARN" != "None" ]]; then
      NODE_ROLE_ARNS+=("$NG_ROLE_ARN")
      echo "    node role: $NG_ROLE_ARN"
    fi
  done
else
  echo "  No managed nodegroups (expected on a Karpenter-only cluster)."
fi

# 2) Karpenter node role.
#    Try, in order: explicit input; the conventional KarpenterNodeRole-<cluster>;
#    then infer from the instance profile on a running node's providerID.
KARPENTER_ROLE_ARN=""
if [[ -n "${KARPENTER_NODE_ROLE_NAME:-}" ]]; then
  KARPENTER_ROLE_ARN="$(aws iam get-role --role-name "$KARPENTER_NODE_ROLE_NAME" \
      --query 'Role.Arn' --output text 2>/dev/null || echo "")"
fi

if [[ -z "$KARPENTER_ROLE_ARN" ]]; then
  CONV="KarpenterNodeRole-${CLUSTER_NAME}"
  KARPENTER_ROLE_ARN="$(aws iam get-role --role-name "$CONV" \
      --query 'Role.Arn' --output text 2>/dev/null || echo "")"
  [[ -n "$KARPENTER_ROLE_ARN" ]] && echo "  Found Karpenter node role by convention: $CONV"
fi

if [[ -z "$KARPENTER_ROLE_ARN" ]]; then
  # Infer from a node's instance profile: look for a node with a karpenter label.
  KNODE="$(kubectl get nodes -l karpenter.sh/nodepool -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")"
  [[ -z "$KNODE" ]] && KNODE="$(kubectl get nodes -l karpenter.sh/provisioner-name -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")"
  if [[ -n "$KNODE" ]]; then
    INSTANCE_ID="$(kubectl get node "$KNODE" -o jsonpath='{.spec.providerID}' 2>/dev/null | sed 's|.*/||')"
    if [[ -n "$INSTANCE_ID" ]]; then
      PROFILE_ARN="$(aws ec2 describe-instances --region "$AWS_REGION" \
          --instance-ids "$INSTANCE_ID" \
          --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text 2>/dev/null || echo "")"
      if [[ -n "$PROFILE_ARN" && "$PROFILE_ARN" != "None" ]]; then
        PROFILE_NAME="${PROFILE_ARN##*/}"
        ROLE_IN_PROFILE="$(aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" \
            --query 'InstanceProfile.Roles[0].Arn' --output text 2>/dev/null || echo "")"
        if [[ -n "$ROLE_IN_PROFILE" && "$ROLE_IN_PROFILE" != "None" ]]; then
          KARPENTER_ROLE_ARN="$ROLE_IN_PROFILE"
          echo "  Inferred Karpenter node role from running node: $KARPENTER_ROLE_ARN"
        fi
      fi
    fi
  fi
fi

[[ -n "$KARPENTER_ROLE_ARN" ]] && NODE_ROLE_ARNS+=("$KARPENTER_ROLE_ARN")

# Deduplicate node roles (a nodegroup and Karpenter may share a role; multiple
# nodegroups may reuse one role). Keeps the PassRole resource list minimal.
if [[ ${#NODE_ROLE_ARNS[@]} -gt 0 ]]; then
  readarray -t NODE_ROLE_ARNS < <(printf '%s\n' "${NODE_ROLE_ARNS[@]}" | awk 'NF && !seen[$0]++')
fi

if [[ ${#NODE_ROLE_ARNS[@]} -eq 0 ]]; then
  echo "ERROR: Could not find any node role (neither managed nodegroup nor Karpenter)."
  echo "Re-run and provide the Karpenter Node Role name explicitly."
  exit 1
fi

echo "  Node role(s) that will be PassRole-able:"
for r in "${NODE_ROLE_ARNS[@]}"; do echo "    $r"; done
echo

# ------------------------------------------------------------------
# OIDC issuer + provider (same as before)
# ------------------------------------------------------------------
echo "[2/12] Reading EKS OIDC issuer..."
OIDC_ISSUER="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" \
  --query "cluster.identity.oidc.issuer" --output text)"
[[ -z "$OIDC_ISSUER" || "$OIDC_ISSUER" == "None" ]] && { echo "ERROR: no OIDC issuer"; exit 1; }
OIDC_PROVIDER="${OIDC_ISSUER#https://}"
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
echo "  OIDC: $OIDC_PROVIDER_ARN"
echo

echo "[3/12] Ensuring IAM OIDC provider..."
OIDC_EXISTS="$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?Arn=='${OIDC_PROVIDER_ARN}'].Arn | [0]" --output text || true)"
if [[ -n "$OIDC_EXISTS" && "$OIDC_EXISTS" != "None" ]]; then
  echo "  OIDC provider exists"
else
  if command -v eksctl >/dev/null 2>&1; then
    eksctl utils associate-iam-oidc-provider --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --approve
  else
    ISSUER_HOST="$(echo "$OIDC_PROVIDER" | cut -d'/' -f1)"
    THUMBPRINT="$(echo | openssl s_client -servername "$ISSUER_HOST" -showcerts -connect "$ISSUER_HOST:443" 2>/dev/null \
      | awk '/BEGIN CERTIFICATE/{i++} {print > ("/tmp/oidc-cert-" i ".pem")}' \
      && openssl x509 -in /tmp/oidc-cert-*.pem -noout -fingerprint -sha1 | tail -n 1 \
      | sed 's/.*=//; s/://g' | tr '[:upper:]' '[:lower:]')"
    aws iam create-open-id-connect-provider --url "$OIDC_ISSUER" \
      --client-id-list "sts.amazonaws.com" --thumbprint-list "$THUMBPRINT" >/dev/null
  fi
fi
echo

echo "[4/12] Namespace + ServiceAccount..."
kubectl create ns "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" create sa "$SERVICE_ACCOUNT" --dry-run=client -o yaml | kubectl apply -f -
echo

# ------------------------------------------------------------------
# IAM policy — Karpenter-aware
#   - PassRole scoped to ALL detected node roles, allowed to BOTH
#     ec2.amazonaws.com (Karpenter launches EC2 directly) and
#     eks.amazonaws.com (managed nodegroups).
#   - Karpenter clusters: terakube reads/describes; Karpenter itself owns
#     instance lifecycle, but describe permissions remain.
# ------------------------------------------------------------------
echo "[5/12] Writing Karpenter-aware IAM policy..."
POLICY_FILE="$(mktemp /tmp/terakube-core-policy.XXXXXX.json)"

# Build the PassRole resource list JSON array.
PASS_RESOURCES=""
for r in "${NODE_ROLE_ARNS[@]}"; do
  PASS_RESOURCES="${PASS_RESOURCES}\"${r}\","
done
PASS_RESOURCES="${PASS_RESOURCES%,}"  # strip trailing comma

cat > "$POLICY_FILE" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EksAndComputeReadWrite",
      "Effect": "Allow",
      "Action": [
        "pricing:GetProducts",
        "iam:GetRole",
        "ec2:DescribeSpotPriceHistory",
        "elasticfilesystem:DescribeFileSystems",
        "elasticfilesystem:DescribeMountTargets",
        "elasticfilesystem:DescribeAccessPoints",
        "ec2:RunInstances",
        "ec2:DescribeInstances",
        "ec2:DescribeAvailabilityZones",
        "ec2:CreateTags",
        "ec2:DescribeImages",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:DescribeReservedInstances",
        "ec2:GetLaunchTemplateData",
        "ec2:DescribeRegions",
        "ec2:DescribeInstanceTypes",
        "ec2:TerminateInstances",
        "ec2:GetSpotPlacementScores",
        "ec2:DescribeInstanceTypeOfferings",

        "eks:DescribeNodegroup",
        "eks:DescribeCluster",
        "eks:ListClusters",
        "eks:ListNodegroups",
        "eks:UpdateNodegroupVersion",
        "eks:UpdateNodegroupConfig",
        "eks:UpdateClusterVersion",
        "eks:DescribeAddon",
        "eks:ListAddons",
        "eks:DescribeClusterVersions",
        "eks:UpdateAddon",
        "eks:DescribeAddonVersions",
        "eks:CreateNodegroup",
        "eks:DeleteNodegroup",
        "eks:TagResource",

        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:UpdateAutoScalingGroup",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:TerminateInstanceInAutoScalingGroup"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ReadClusterRoles",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole",
        "iam:GetInstanceProfile",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies"
      ],
      "Resource": [
        "arn:aws:iam::${AWS_ACCOUNT_ID}:role/eksctl-*",
        "arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-*",
        "arn:aws:iam::${AWS_ACCOUNT_ID}:role/aws-service-role/eks-nodegroup.amazonaws.com/*",
        "arn:aws:iam::${AWS_ACCOUNT_ID}:instance-profile/*"
      ]
    },
    {
      "Sid": "PassNodeRolesOnly",
      "Effect": "Allow",
      "Action": [ "iam:PassRole" ],
      "Resource": [ ${PASS_RESOURCES} ],
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": [ "eks.amazonaws.com", "ec2.amazonaws.com" ]
        }
      }
    }
  ]
}
JSON

echo "  Policy file: $POLICY_FILE"
echo

echo "[6/12] Ensuring IAM policy..."
EXISTING_POLICY_ARN="$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn | [0]" --output text || true)"
if [[ -n "$EXISTING_POLICY_ARN" && "$EXISTING_POLICY_ARN" != "None" ]]; then
  POLICY_ARN="$EXISTING_POLICY_ARN"
  # Update to a new default version so Karpenter changes take effect on re-run.
  aws iam create-policy-version --policy-arn "$POLICY_ARN" \
    --policy-document "file://$POLICY_FILE" --set-as-default >/dev/null 2>&1 || true
  echo "  Reusing policy: $POLICY_ARN (updated default version)"
else
  POLICY_ARN="$(aws iam create-policy --policy-name "$POLICY_NAME" \
    --policy-document "file://$POLICY_FILE" --query 'Policy.Arn' --output text)"
  echo "  Created policy: $POLICY_ARN"
fi
echo

echo "[7/12] Trust policy..."
TRUST_FILE="$(mktemp /tmp/terakube-core-trust.XXXXXX.json)"
cat > "$TRUST_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${OIDC_PROVIDER_ARN}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT}"
        }
      }
    }
  ]
}
EOF
echo

echo "[8/12] Ensuring IRSA role..."
ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || true)"
if [[ -z "$ROLE_ARN" || "$ROLE_ARN" == "None" ]]; then
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "file://$TRUST_FILE" >/dev/null
  ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)"
  echo "  Created role: $ROLE_ARN"
else
  echo "  Found role: $ROLE_ARN"
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "file://$TRUST_FILE" >/dev/null
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" >/dev/null || true
echo

echo "[9/12] Annotating ServiceAccount..."
kubectl -n "$NAMESPACE" annotate sa "$SERVICE_ACCOUNT" \
  eks.amazonaws.com/role-arn="$ROLE_ARN" --overwrite
echo

echo "[10/12] Patching deployment (if present)..."
if kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT_NAME" >/dev/null 2>&1; then
  kubectl -n "$NAMESPACE" patch deployment "$DEPLOYMENT_NAME" \
    -p "{\"spec\":{\"template\":{\"spec\":{\"serviceAccountName\":\"$SERVICE_ACCOUNT\"}}}}"
  kubectl -n "$NAMESPACE" rollout restart deployment "$DEPLOYMENT_NAME"
  kubectl -n "$NAMESPACE" rollout status deployment "$DEPLOYMENT_NAME"
elif kubectl -n "$NAMESPACE" get statefulset "$DEPLOYMENT_NAME" >/dev/null 2>&1; then
  kubectl -n "$NAMESPACE" patch statefulset "$DEPLOYMENT_NAME" \
    -p "{\"spec\":{\"template\":{\"spec\":{\"serviceAccountName\":\"$SERVICE_ACCOUNT\"}}}}"
  kubectl -n "$NAMESPACE" rollout restart statefulset "$DEPLOYMENT_NAME"
  kubectl -n "$NAMESPACE" rollout status statefulset "$DEPLOYMENT_NAME"
else
  echo "  No terakube-core Deployment/StatefulSet yet — annotation is in place for when you deploy."
fi
echo

echo "[11/12] Done wiring IRSA."
echo
echo "[12/12] SUCCESS"
echo
echo "Security model:"
echo "  - iam:PassRole restricted to the detected node role(s):"
for r in "${NODE_ROLE_ARNS[@]}"; do echo "      $r"; done
echo "  - PassedToService limited to eks.amazonaws.com + ec2.amazonaws.com"
echo "  - Works with managed nodegroups AND Karpenter"
echo
echo "NOTE (Karpenter): Karpenter owns node lifecycle via its OWN controller role."
echo "This script does NOT grant terakube Karpenter's controller permissions — it"
echo "only lets terakube read cluster state and PassRole the node role. Terakube's"
echo "node scheduler features that create managed nodegroups do not apply on a"
echo "Karpenter-only cluster; use Karpenter NodePools/limits for those instead."
echo "DONE"
