#!/usr/bin/env bash
# ============================================================
# deploy.sh — Complete EKS Hub-Spoke Deployment
# Run each section in order. Review outputs between sections.
# ============================================================
set -euo pipefail

export AWS_DEFAULT_REGION="ap-south-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CLUSTER_NAME="prod-eks-cluster"
export ECR_REPO="${ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"

echo "Account: ${ACCOUNT_ID} | Region: ${AWS_DEFAULT_REGION}"

# ─────────────────────────────────────────────────────────────
# PHASE 1: TERRAFORM — Hub VPC + TGW + Firewall
# ─────────────────────────────────────────────────────────────
echo "==> PHASE 1: Deploying Hub VPC infrastructure"

# Create S3 backend bucket first (one-time)
aws s3api create-bucket \
  --bucket "my-terraform-state-bucket" \
  --region "${AWS_DEFAULT_REGION}" \
  --create-bucket-configuration LocationConstraint="${AWS_DEFAULT_REGION}"
aws s3api put-bucket-versioning \
  --bucket "my-terraform-state-bucket" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption \
  --bucket "my-terraform-state-bucket" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Deploy Hub VPC
cd terraform/hub-vpc
terraform init
terraform plan -out=hub.tfplan
terraform apply hub.tfplan

export TGW_ID=$(terraform output -raw transit_gateway_id)
export TGW_SPOKE_RT_ID=$(terraform output -raw tgw_spoke_rt_id)
cd ../..

# ─────────────────────────────────────────────────────────────
# PHASE 2: TERRAFORM — Spoke VPC + EKS + RDS
# ─────────────────────────────────────────────────────────────
echo "==> PHASE 2: Deploying Spoke VPC + EKS + RDS PostgreSQL"

cd terraform/spoke-vpc

# Store DB password in Parameter Store (never in terraform.tfvars)
DB_PASSWORD=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9!@#' | head -c 20)
aws ssm put-parameter \
  --name "/prod/db/password" \
  --value "${DB_PASSWORD}" \
  --type SecureString \
  --overwrite

terraform init
terraform plan \
  -var="db_password=${DB_PASSWORD}" \
  -out=spoke.tfplan
terraform apply spoke.tfplan

export RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
export DB_SECRET_ARN=$(terraform output -raw db_secret_arn)
cd ../..

# ─────────────────────────────────────────────────────────────
# PHASE 3: TERRAFORM — WAF
# ─────────────────────────────────────────────────────────────
echo "==> PHASE 3: Deploying WAF, Bot Control"

cd terraform/waf
terraform init
terraform plan -out=waf.tfplan
terraform apply waf.tfplan
export WAF_ACL_ARN=$(terraform output -raw waf_acl_arn)
cd ../..

# ─────────────────────────────────────────────────────────────
# PHASE 4: EKS Cluster Access + Addons
# ─────────────────────────────────────────────────────────────
echo "==> PHASE 4: Configuring EKS cluster"

aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_DEFAULT_REGION}"

kubectl cluster-info
kubectl get nodes

# Enable OIDC provider (required for IRSA)
eksctl utils associate-iam-oidc-provider \
  --cluster "${CLUSTER_NAME}" \
  --approve

# Install EBS CSI Driver addon
aws eks create-addon \
  --cluster-name "${CLUSTER_NAME}" \
  --addon-name aws-ebs-csi-driver \
  --resolve-conflicts OVERWRITE

# Install VPC CNI addon
aws eks create-addon \
  --cluster-name "${CLUSTER_NAME}" \
  --addon-name vpc-cni \
  --resolve-conflicts OVERWRITE

# Install CoreDNS addon
aws eks create-addon \
  --cluster-name "${CLUSTER_NAME}" \
  --addon-name coredns \
  --resolve-conflicts OVERWRITE

# Install kube-proxy addon
aws eks create-addon \
  --cluster-name "${CLUSTER_NAME}" \
  --addon-name kube-proxy \
  --resolve-conflicts OVERWRITE

# ─────────────────────────────────────────────────────────────
# PHASE 5: Helm addons — ALB Controller, Metrics Server,
#           External Secrets, Karpenter, Prometheus
# ─────────────────────────────────────────────────────────────
echo "==> PHASE 5: Installing Helm addons"

# Add Helm repos
helm repo add eks                  https://aws.github.io/eks-charts
helm repo add external-secrets     https://charts.external-secrets.io
helm repo add karpenter            https://charts.karpenter.sh
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add metrics-server       https://kubernetes-sigs.github.io/metrics-server/
helm repo update

# ── AWS Load Balancer Controller ─────────────────────────────
# Create IAM policy for ALB controller
curl -fsSL https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.0/docs/install/iam_policy.json \
  -o /tmp/alb-iam-policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file:///tmp/alb-iam-policy.json 2>/dev/null || true

eksctl create iamserviceaccount \
  --cluster="${CLUSTER_NAME}" \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn="arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy" \
  --approve \
  --override-existing-serviceaccounts

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="${CLUSTER_NAME}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="${AWS_DEFAULT_REGION}" \
  --set vpcId="$(aws eks describe-cluster --name ${CLUSTER_NAME} --query 'cluster.resourcesVpcConfig.vpcId' --output text)" \
  --wait

# ── Metrics Server ───────────────────────────────────────────
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set args[0]="--kubelet-insecure-tls" \
  --wait

# ── External Secrets Operator ─────────────────────────────────
# IAM policy for External Secrets to read Secrets Manager
cat > /tmp/external-secrets-policy.json << 'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:ListSecrets"
      ],
      "Resource": "*"
    }
  ]
}
POLICY

aws iam create-policy \
  --policy-name ExternalSecretsPolicy \
  --policy-document file:///tmp/external-secrets-policy.json 2>/dev/null || true

kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -

eksctl create iamserviceaccount \
  --cluster="${CLUSTER_NAME}" \
  --namespace=external-secrets \
  --name=external-secrets-sa \
  --attach-policy-arn="arn:aws:iam::${ACCOUNT_ID}:policy/ExternalSecretsPolicy" \
  --approve \
  --override-existing-serviceaccounts

helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --set installCRDs=true \
  --set serviceAccount.create=false \
  --set serviceAccount.name=external-secrets-sa \
  --wait

# ── Prometheus + Grafana stack ───────────────────────────────
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.retention=15d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=gp3 \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi \
  --set grafana.adminPassword="$(openssl rand -base64 16)" \
  --wait

# ─────────────────────────────────────────────────────────────
# PHASE 6: ECR — Build & Push Images
# ─────────────────────────────────────────────────────────────
echo "==> PHASE 6: Building and pushing Docker images"

# Login to ECR
aws ecr get-login-password --region "${AWS_DEFAULT_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REPO}"

# Create ECR repos
for svc in microservice-a microservice-b; do
  aws ecr create-repository --repository-name "${svc}" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 2>/dev/null || true
  # Enable lifecycle policy (keep last 10 images)
  aws ecr put-lifecycle-policy \
    --repository-name "${svc}" \
    --lifecycle-policy-text '{
      "rules":[{"rulePriority":1,"description":"Keep last 10","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":10},"action":{"type":"expire"}}]
    }'
done

# Build and push Microservice A
cd microservice-a
docker buildx build \
  --platform linux/amd64 \
  --tag "${ECR_REPO}/microservice-a:1.0.0" \
  --tag "${ECR_REPO}/microservice-a:latest" \
  --push .
cd ..

# Build and push Microservice B
cd microservice-b
docker buildx build \
  --platform linux/amd64 \
  --tag "${ECR_REPO}/microservice-b:1.0.0" \
  --tag "${ECR_REPO}/microservice-b:latest" \
  --push .
cd ..

# ─────────────────────────────────────────────────────────────
# PHASE 7: IAM Roles for Microservices (IRSA)
# ─────────────────────────────────────────────────────────────
echo "==> PHASE 7: Creating IRSA roles for microservices"

OIDC_PROVIDER=$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --query "cluster.identity.oidc.issuer" \
  --output text | sed 's|https://||')

# Create IAM role + policy for each microservice
for svc in microservice-a microservice-b; do
  cat > /tmp/${svc}-trust.json << TRUST
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_PROVIDER}:sub": "system:serviceaccount:${svc}:${svc}-sa",
        "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
TRUST

  aws iam create-role \
    --role-name "${svc}-role" \
    --assume-role-policy-document file:///tmp/${svc}-trust.json 2>/dev/null || true

  # Attach Secrets Manager read policy
  aws iam attach-role-policy \
    --role-name "${svc}-role" \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/ExternalSecretsPolicy"
done

# ─────────────────────────────────────────────────────────────
# PHASE 8: Deploy Kubernetes Manifests
# ─────────────────────────────────────────────────────────────
echo "==> PHASE 8: Deploying microservices to Kubernetes"

# Update image references in manifests
sed -i "s|123456789.dkr.ecr.ap-south-1.amazonaws.com|${ECR_REPO}|g" \
  k8s/microservice-a/deployment.yaml \
  k8s/microservice-b/deployment.yaml

# Update ACCOUNT_ID placeholders
sed -i "s|ACCOUNT_ID|${ACCOUNT_ID}|g" \
  k8s/microservice-a/deployment.yaml \
  k8s/microservice-b/deployment.yaml \
  k8s/ingress/alb-ingress.yaml

# Apply ClusterSecretStore first
kubectl apply -f k8s/ingress/alb-ingress.yaml

# Deploy microservice namespaces + manifests
kubectl apply -f k8s/microservice-a/deployment.yaml
kubectl apply -f k8s/microservice-b/deployment.yaml

# Wait for rollout
kubectl rollout status deployment/microservice-a -n microservice-a --timeout=300s
kubectl rollout status deployment/microservice-b -n microservice-b --timeout=300s

# ─────────────────────────────────────────────────────────────
# PHASE 9: Verification
# ─────────────────────────────────────────────────────────────
echo "==> PHASE 9: Verifying deployment"

echo "--- Nodes ---"
kubectl get nodes -o wide

echo "--- Pods (microservice-a) ---"
kubectl get pods -n microservice-a -o wide

echo "--- Pods (microservice-b) ---"
kubectl get pods -n microservice-b -o wide

echo "--- Services ---"
kubectl get svc -A

echo "--- Ingresses ---"
kubectl get ingress -A

echo "--- HPA ---"
kubectl get hpa -A

echo "--- External Secrets ---"
kubectl get externalsecret -A

# Get ALB DNS name
ALB_DNS=$(kubectl get ingress microservice-a-ingress -n microservice-a \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo ""
echo "=== DEPLOYMENT COMPLETE ==="
echo "ALB DNS:      ${ALB_DNS}"
echo "RDS Endpoint: ${RDS_ENDPOINT}"
echo "TGW ID:       ${TGW_ID}"
echo ""
echo "Test endpoints:"
echo "  curl -k https://${ALB_DNS}/api/v1/users"
echo "  curl -k https://${ALB_DNS}/api/v2/orders"
echo "  curl -k https://${ALB_DNS}/health/ready"
