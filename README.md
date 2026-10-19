### Terakube

Terakube is an autonomous Kubernetes cost optimization platform (Core + UI) designed with advanced ML/AI capabilities for cloud financial management (FinOps). It automatically handles workloads, node right-sizing, and GPU optimizations while leveraging AWS EFS for shared, persistent storage. 

### Key Features

* **Autonomous Cost Optimization:** Real-time right-sizing for Kubernetes workloads and nodes.
* **AI/ML Driven:** Smart forecasting and autoscaling policies.
* **GPU Optimization:** Cost-effective management for AI/ML compute workloads.
* **Built for FinOps:** Full transparency over infrastructure spend across EKS, AKS, and custom Kubernetes clusters.
* **EFS Persistence:** Native support for AWS Elastic File System to handle distributed state.

### Prerequisites

Before deploying Terakube, ensure you have: 

* A Kubernetes cluster (v1.22+) up and running.
* helm CLI installed (v3.8+ required for OCI support).
* An active AWS EFS system (if deploying with persistence enabled).

### Installation

Terakube is distributed via GitHub Container Registry (GHCR) as an OCI artifact. Anyone can deploy or upgrade it using the official remote Helm registry without cloning the repository. 

Run the following command to deploy or upgrade your release: 

bash

# 1. Define deployment parameters
export HERE="oci://ghcr.io/terakube/charts/terakube"
export RELEASE="terakube-prod"
export NAMESPACE="terakube"
export VERSION="1.0.0"

# 2. (Optional) Define your AWS EFS parameters
# Example: export HELM_EFS_ARGS=(--set persistence.efs.enabled=true --set persistence.efs.id=fs-123456)
export HELM_EFS_ARGS=()

# 3. Execute the standard installation/upgrade command
helm upgrade --install "$RELEASE" "$HERE" \
  --version "$VERSION" \
  --namespace "$NAMESPACE" --create-namespace \
  "${HELM_EFS_ARGS[@]}" "${@:2}"

Utilisez le code avec précaution.

### Configuration Parameters

To pass custom parameters on the fly, you can append standard Helm arguments directly to your execution command (via the "${@:2}" option), like this: 


Utilisez le code avec précaution.

### Maintainers

* **Terakube Team** - [GitHub](/goto?url=CAESUwHrOzAVsiebLVMFYjgsaTOy6TM5bfvYXvtzLLWhJlw1s7nHp2dg596XAmJ78BjSHTIybLMPNQ-8sG6XkREa9y_voIfYh0EOZFR7bY6T2S17IZm9)

### License

This project is licensed under the Apache License 2.0.
