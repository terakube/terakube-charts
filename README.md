# Terakube Helm chart (core + UI + EFS)

Deploys Terakube **core** and **UI** into EKS with **EFS persistence**,
provisions all EFS/IAM prerequisites, and wires the core's least-privilege IAM
(IRSA) — in one command.

## What the installer does (`install.sh`)
1. **Asks whether to provision EFS (yes/no).**
   - **yes** → asks for AWS **region** + **cluster name**, then runs
     `scripts/efs-setup.sh`, which creates, in order:
     - EKS **OIDC provider**
     - **EFS-CSI IAM role** (AmazonEFSCSIDriverPolicy, IRSA trust)
     - EKS add-on **`aws-efs-csi-driver`** (bound to that role)
     - **EFS filesystem**
     - **EFS mount targets** on the cluster's node **subnets (auto-discovered)**,
       with a security group allowing NFS (2049) from the VPC
     - returns the `fs-id`, passed to Helm as `storage.fileSystemId`
   - **no** → continues; you provide an existing `fs-id` or manage the
     StorageClass yourself.
2. **`helm upgrade --install`** the chart (namespace `terakube-core`).
3. **After** the app is deployed, runs `scripts/terakube-irsa-setup.sh` to create
   the core's scoped IAM role (nodegroups and/or Karpenter) and annotate the
   ServiceAccount.

## Install
```bash
./install.sh                 # interactive (recommended) make sure to update the HELMURL with the latest helm package version
# or a named release:
./install.sh my-release
```

## Manual Helm (if you already have EFS)
```bash
helm upgrade --install terakube . \
  --namespace terakube-core --create-namespace \
  --set storage.fileSystemId=fs-xxxxxxxx
```

## Components & requirements honored
- **core** (`terakube-core`, Go, MongoDB embedded): EFS-backed at `/data/db`,
  `Recreate` strategy (single writer), **no environment variables**.

## Prerequisites
`helm`, `kubectl`; for EFS setup also `aws`, `jq` (and `eksctl` optional).
The aws-efs-csi-driver add-on is installed by the EFS step.


## Uninstall
```bash
./uninstall.sh            # guided: helm uninstall + optional AWS/EFS teardown
# or just the release:
helm uninstall terakube -n terakube-core
```
`uninstall.sh` removes the release, then (after an explicit, typed confirmation)
can tear down the EFS filesystem + mount targets, the NFS security group, the
aws-efs-csi-driver add-on + its IAM role, and the core IRSA role/policy. EFS
teardown is DESTRUCTIVE (deletes data); it is skipped unless you confirm.
EFS StorageClass uses `reclaimPolicy: Retain` — the EFS filesystem and data are
kept; delete the filesystem/mount targets manually if you want them gone.
