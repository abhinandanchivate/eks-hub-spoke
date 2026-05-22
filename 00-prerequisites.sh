#!/usr/bin/env bash
# ============================================================
# 00-prerequisites.sh
# Install and configure all required CLI tools
# ============================================================
set -euo pipefail

AWS_REGION="ap-south-1"          # Mumbai – nearest to Pune
CLUSTER_NAME="prod-eks-cluster"
TF_VERSION="1.8.0"

echo "==> Installing AWS CLI v2"
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install --update
aws --version

echo "==> Installing kubectl"
KUBECTL_VER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
kubectl version --client

echo "==> Installing eksctl"
ARCH=$(uname -m)
curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" \
  | tar -xz && sudo mv eksctl /usr/local/bin/
eksctl version

echo "==> Installing Helm"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

echo "==> Installing Terraform ${TF_VERSION}"
curl -fsSL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" \
  -o /tmp/tf.zip
unzip -q /tmp/tf.zip -d /tmp && sudo mv /tmp/terraform /usr/local/bin/
terraform version

echo "==> Configuring AWS credentials"
# Set via environment or run: aws configure
export AWS_DEFAULT_REGION="${AWS_REGION}"
aws sts get-caller-identity   # verify credentials work

echo "==> All prerequisites installed successfully"
