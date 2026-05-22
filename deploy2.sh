#!/usr/bin/env bash
# ================================================================
# deploy.sh — EKS Hub-Spoke Full Deployment (AWS CLI only)
# No Terraform. Provisions: Hub VPC, Spoke VPC, TGW, Network
# Firewall, WAF, NAT, EKS, RDS PostgreSQL, ECR, K8s manifests.
#
# Usage:
#   chmod +x deploy.sh
#   export AWS_DEFAULT_REGION=ap-south-1   # change if needed
#   export DB_PASSWORD="YourStrong@Pass1"  # set before running
#   ./deploy.sh
# ================================================================
set -euo pipefail

# ── Config — edit these before running ───────────────────────
REGION="${AWS_DEFAULT_REGION:-ap-south-1}"
CLUSTER_NAME="prod-eks-cluster"
K8S_VERSION="1.30"
HUB_VPC_CIDR="10.0.0.0/16"
SPOKE_VPC_CIDR="10.1.0.0/16"
DB_INSTANCE_CLASS="db.r6g.large"
DB_NAME="appdb"
DB_USER="dbadmin"
DB_PASSWORD="${DB_PASSWORD:?Set DB_PASSWORD env var before running}"
NODE_TYPE="m5.xlarge"
NODE_MIN=2
NODE_MAX=10
NODE_DESIRED=3

# ── Derived values ────────────────────────────────────────────
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "\033[1;32m    ✓ $*\033[0m"; }
info() { echo -e "\033[0;33m    • $*\033[0m"; }

log "Starting deployment | Account: ${ACCOUNT_ID} | Region: ${REGION}"

# ================================================================
# PHASE 1 — HUB VPC
# ================================================================
log "PHASE 1: Creating Hub VPC (${HUB_VPC_CIDR})"

HUB_VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "${HUB_VPC_CIDR}" \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id "${HUB_VPC_ID}" --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id "${HUB_VPC_ID}" --enable-dns-support
aws ec2 create-tags --resources "${HUB_VPC_ID}" \
  --tags Key=Name,Value=hub-vpc Key=Project,Value=eks-hub-spoke
ok "Hub VPC: ${HUB_VPC_ID}"

# Hub subnets — 3 AZs for firewall, 3 for TGW
AZS=($(aws ec2 describe-availability-zones \
  --query 'AvailabilityZones[?State==`available`].ZoneName' \
  --output text | tr '\t' ' ' | awk '{print $1, $2, $3}'))
info "Using AZs: ${AZS[*]}"

HUB_FW_SUBNETS=()
HUB_TGW_SUBNETS=()

for i in 0 1 2; do
  FW_CIDR="10.0.$((i)).0/24"
  TGW_CIDR="10.0.$((i+10)).0/24"

  FW_SN=$(aws ec2 create-subnet \
    --vpc-id "${HUB_VPC_ID}" \
    --cidr-block "${FW_CIDR}" \
    --availability-zone "${AZS[$i]}" \
    --query 'Subnet.SubnetId' --output text)
  aws ec2 create-tags --resources "${FW_SN}" \
    --tags Key=Name,Value="hub-firewall-$((i+1))"
  HUB_FW_SUBNETS+=("${FW_SN}")

  TGW_SN=$(aws ec2 create-subnet \
    --vpc-id "${HUB_VPC_ID}" \
    --cidr-block "${TGW_CIDR}" \
    --availability-zone "${AZS[$i]}" \
    --query 'Subnet.SubnetId' --output text)
  aws ec2 create-tags --resources "${TGW_SN}" \
    --tags Key=Name,Value="hub-tgw-$((i+1))"
  HUB_TGW_SUBNETS+=("${TGW_SN}")
done

ok "Hub subnets created"

# Hub Internet Gateway
HUB_IGW=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway \
  --vpc-id "${HUB_VPC_ID}" \
  --internet-gateway-id "${HUB_IGW}"
aws ec2 create-tags --resources "${HUB_IGW}" \
  --tags Key=Name,Value=hub-igw
ok "Hub IGW: ${HUB_IGW}"

# ================================================================
# PHASE 2 — TRANSIT GATEWAY
# ================================================================
log "PHASE 2: Creating Transit Gateway"

TGW_ID=$(aws ec2 create-transit-gateway \
  --description "Central TGW for hub-spoke" \
  --options \
    AmazonSideAsn=64512,\
DefaultRouteTableAssociation=disable,\
DefaultRouteTablePropagation=disable,\
AutoAcceptSharedAttachments=enable \
  --query 'TransitGateway.TransitGatewayId' --output text)
aws ec2 create-tags --resources "${TGW_ID}" \
  --tags Key=Name,Value=main-tgw
info "TGW ${TGW_ID} — waiting for available state (~30s)"
aws ec2 wait transit-gateway-available --filters \
  Name=transit-gateway-id,Values="${TGW_ID}" 2>/dev/null \
  || sleep 45   # fallback wait if waiter not available
ok "Transit Gateway ready: ${TGW_ID}"

# TGW Route Tables
TGW_HUB_RT=$(aws ec2 create-transit-gateway-route-table \
  --transit-gateway-id "${TGW_ID}" \
  --query 'TransitGatewayRouteTable.TransitGatewayRouteTableId' --output text)
aws ec2 create-tags --resources "${TGW_HUB_RT}" \
  --tags Key=Name,Value=tgw-rt-hub

TGW_SPOKE_RT=$(aws ec2 create-transit-gateway-route-table \
  --transit-gateway-id "${TGW_ID}" \
  --query 'TransitGatewayRouteTable.TransitGatewayRouteTableId' --output text)
aws ec2 create-tags --resources "${TGW_SPOKE_RT}" \
  --tags Key=Name,Value=tgw-rt-spoke
ok "TGW route tables: hub=${TGW_HUB_RT} spoke=${TGW_SPOKE_RT}"

# Attach Hub VPC to TGW
HUB_TGW_ATTACH=$(aws ec2 create-transit-gateway-vpc-attachment \
  --transit-gateway-id "${TGW_ID}" \
  --vpc-id "${HUB_VPC_ID}" \
  --subnet-ids "${HUB_TGW_SUBNETS[@]}" \
  --query 'TransitGatewayVpcAttachment.TransitGatewayAttachmentId' --output text)
aws ec2 create-tags --resources "${HUB_TGW_ATTACH}" \
  --tags Key=Name,Value=tgw-attach-hub
info "Waiting for Hub TGW attachment (~20s)"
sleep 20
aws ec2 associate-transit-gateway-route-table \
  --transit-gateway-attachment-id "${HUB_TGW_ATTACH}" \
  --transit-gateway-route-table-id "${TGW_HUB_RT}"
ok "Hub VPC attached to TGW"

# ================================================================
# PHASE 3 — AWS NETWORK FIREWALL (Hub VPC)
# ================================================================
log "PHASE 3: Creating AWS Network Firewall"

# Stateless rule group — pass spoke traffic to stateful engine
aws network-firewall create-rule-group \
  --rule-group-name stateless-pass-spoke \
  --type STATELESS \
  --capacity 100 \
  --rule-group '{
    "RulesSource": {
      "StatelessRulesAndCustomActions": {
        "StatelessRules": [
          {
            "Priority": 1,
            "RuleDefinition": {
              "MatchAttributes": {
                "Sources": [{"AddressDefinition": "10.1.0.0/16"}],
                "Protocols": [6, 17]
              },
              "Actions": ["aws:forward_to_sfe"]
            }
          },
          {
            "Priority": 10,
            "RuleDefinition": {
              "MatchAttributes": {"Sources": [{"AddressDefinition": "0.0.0.0/0"}]},
              "Actions": ["aws:forward_to_sfe"]
            }
          }
        ]
      }
    }
  }' \
  --region "${REGION}" \
  --tags Key=Name,Value=stateless-pass-spoke \
  --no-cli-pager

STATELESS_ARN="arn:aws:network-firewall:${REGION}:${ACCOUNT_ID}:stateless-rulegroup/stateless-pass-spoke"

# Stateful Suricata rule group — block known bad, allow spoke↔spoke
aws network-firewall create-rule-group \
  --rule-group-name stateful-east-west \
  --type STATEFUL \
  --capacity 100 \
  --rule-group '{
    "RulesSource": {
      "RulesString": "pass tcp 10.1.0.0/16 any -> 10.1.0.0/16 any (msg:\"Allow spoke internal\"; sid:1; rev:1;)\npass tcp any any -> any 443 (msg:\"Allow HTTPS egress\"; sid:2; rev:1;)\ndrop tcp any any -> any any (msg:\"Default deny\"; sid:999; rev:1;)"
    },
    "StatefulRuleOptions": {"RuleOrder": "STRICT_ORDER"}
  }' \
  --region "${REGION}" \
  --tags Key=Name,Value=stateful-east-west \
  --no-cli-pager

STATEFUL_ARN="arn:aws:network-firewall:${REGION}:${ACCOUNT_ID}:stateful-rulegroup/stateful-east-west"

# Firewall policy
aws network-firewall create-firewall-policy \
  --firewall-policy-name hub-firewall-policy \
  --firewall-policy "{
    \"StatelessDefaultActions\": [\"aws:forward_to_sfe\"],
    \"StatelessFragmentDefaultActions\": [\"aws:forward_to_sfe\"],
    \"StatelessRuleGroupReferences\": [
      {\"ResourceArn\": \"${STATELESS_ARN}\", \"Priority\": 1}
    ],
    \"StatefulEngineOptions\": {\"RuleOrder\": \"STRICT_ORDER\"},
    \"StatefulRuleGroupReferences\": [
      {\"ResourceArn\": \"${STATEFUL_ARN}\", \"Priority\": 1}
    ]
  }" \
  --region "${REGION}" \
  --tags Key=Name,Value=hub-firewall-policy \
  --no-cli-pager

FW_POLICY_ARN="arn:aws:network-firewall:${REGION}:${ACCOUNT_ID}:firewall-policy/hub-firewall-policy"

# Create the firewall (one subnet per AZ)
FW_SUBNET_MAPPINGS=$(printf '{"SubnetId":"%s"} ' "${HUB_FW_SUBNETS[@]}" | sed 's/ $//' | tr ' ' '\n' | paste -sd ',' | sed 's/^/[/;s/$/]/')
FW_RESULT=$(aws network-firewall create-firewall \
  --firewall-name hub-network-firewall \
  --vpc-id "${HUB_VPC_ID}" \
  --firewall-policy-arn "${FW_POLICY_ARN}" \
  --subnet-mappings $(for sn in "${HUB_FW_SUBNETS[@]}"; do echo "SubnetId=${sn}"; done | tr '\n' ' ') \
  --tags Key=Name,Value=hub-network-firewall \
  --region "${REGION}" \
  --no-cli-pager \
  --query 'Firewall.FirewallArn' --output text)
ok "Network Firewall created: ${FW_RESULT}"
info "Firewall provisioning takes ~5 min — continuing other setup in parallel"

# ================================================================
# PHASE 4 — SPOKE VPC
# ================================================================
log "PHASE 4: Creating Spoke VPC (${SPOKE_VPC_CIDR})"

SPOKE_VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "${SPOKE_VPC_CIDR}" \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id "${SPOKE_VPC_ID}" --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id "${SPOKE_VPC_ID}" --enable-dns-support
aws ec2 create-tags --resources "${SPOKE_VPC_ID}" \
  --tags \
    Key=Name,Value=spoke-vpc-prod \
    Key="kubernetes.io/cluster/${CLUSTER_NAME}",Value=shared
ok "Spoke VPC: ${SPOKE_VPC_ID}"

# Create subnets — public, private (EKS), db
SPOKE_PUBLIC_SUBNETS=()
SPOKE_PRIVATE_SUBNETS=()
SPOKE_DB_SUBNETS=()

for i in 0 1 2; do
  PUB_CIDR="10.1.$((i)).0/24"
  PRI_CIDR="10.1.$((i+10)).0/24"
  DB_CIDR="10.1.$((i+20)).0/24"

  PUB=$(aws ec2 create-subnet \
    --vpc-id "${SPOKE_VPC_ID}" \
    --cidr-block "${PUB_CIDR}" \
    --availability-zone "${AZS[$i]}" \
    --query 'Subnet.SubnetId' --output text)
  aws ec2 modify-subnet-attribute --subnet-id "${PUB}" \
    --map-public-ip-on-launch
  aws ec2 create-tags --resources "${PUB}" --tags \
    Key=Name,Value="spoke-public-$((i+1))" \
    Key="kubernetes.io/cluster/${CLUSTER_NAME}",Value=shared \
    Key="kubernetes.io/role/elb",Value=1
  SPOKE_PUBLIC_SUBNETS+=("${PUB}")

  PRI=$(aws ec2 create-subnet \
    --vpc-id "${SPOKE_VPC_ID}" \
    --cidr-block "${PRI_CIDR}" \
    --availability-zone "${AZS[$i]}" \
    --query 'Subnet.SubnetId' --output text)
  aws ec2 create-tags --resources "${PRI}" --tags \
    Key=Name,Value="spoke-private-$((i+1))" \
    Key="kubernetes.io/cluster/${CLUSTER_NAME}",Value=owned \
    Key="kubernetes.io/role/internal-elb",Value=1
  SPOKE_PRIVATE_SUBNETS+=("${PRI}")

  DB=$(aws ec2 create-subnet \
    --vpc-id "${SPOKE_VPC_ID}" \
    --cidr-block "${DB_CIDR}" \
    --availability-zone "${AZS[$i]}" \
    --query 'Subnet.SubnetId' --output text)
  aws ec2 create-tags --resources "${DB}" \
    --tags Key=Name,Value="spoke-db-$((i+1))"
  SPOKE_DB_SUBNETS+=("${DB}")
done
ok "Spoke subnets created (public/private/db)"

# Internet Gateway for Spoke
SPOKE_IGW=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway \
  --vpc-id "${SPOKE_VPC_ID}" \
  --internet-gateway-id "${SPOKE_IGW}"
aws ec2 create-tags --resources "${SPOKE_IGW}" \
  --tags Key=Name,Value=spoke-igw
ok "Spoke IGW: ${SPOKE_IGW}"

# NAT Gateways — one per AZ (high availability)
NAT_GW_IDS=()
for i in 0 1 2; do
  EIP=$(aws ec2 allocate-address --domain vpc \
    --query 'AllocationId' --output text)
  aws ec2 create-tags --resources "${EIP}" \
    --tags Key=Name,Value="nat-eip-$((i+1))"

  NAT=$(aws ec2 create-nat-gateway \
    --subnet-id "${SPOKE_PUBLIC_SUBNETS[$i]}" \
    --allocation-id "${EIP}" \
    --query 'NatGateway.NatGatewayId' --output text)
  aws ec2 create-tags --resources "${NAT}" \
    --tags Key=Name,Value="nat-gw-$((i+1))"
  NAT_GW_IDS+=("${NAT}")
done
info "NAT Gateways creating — waiting for available (~90s)"
for NAT in "${NAT_GW_IDS[@]}"; do
  aws ec2 wait nat-gateway-available --nat-gateway-ids "${NAT}"
done
ok "NAT Gateways ready: ${NAT_GW_IDS[*]}"

# ── Route Tables ──────────────────────────────────────────────
# Public RT
PUB_RT=$(aws ec2 create-route-table \
  --vpc-id "${SPOKE_VPC_ID}" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-tags --resources "${PUB_RT}" \
  --tags Key=Name,Value=spoke-rt-public
aws ec2 create-route --route-table-id "${PUB_RT}" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "${SPOKE_IGW}"
aws ec2 create-route --route-table-id "${PUB_RT}" \
  --destination-cidr-block "10.0.0.0/8" \
  --transit-gateway-id "${TGW_ID}"
for SN in "${SPOKE_PUBLIC_SUBNETS[@]}"; do
  aws ec2 associate-route-table \
    --subnet-id "${SN}" --route-table-id "${PUB_RT}"
done

# Private RTs — one per AZ with its own NAT
for i in 0 1 2; do
  PRI_RT=$(aws ec2 create-route-table \
    --vpc-id "${SPOKE_VPC_ID}" \
    --query 'RouteTable.RouteTableId' --output text)
  aws ec2 create-tags --resources "${PRI_RT}" \
    --tags Key=Name,Value="spoke-rt-private-$((i+1))"
  aws ec2 create-route --route-table-id "${PRI_RT}" \
    --destination-cidr-block "0.0.0.0/0" \
    --nat-gateway-id "${NAT_GW_IDS[$i]}"
  aws ec2 create-route --route-table-id "${PRI_RT}" \
    --destination-cidr-block "10.0.0.0/8" \
    --transit-gateway-id "${TGW_ID}"
  aws ec2 associate-route-table \
    --subnet-id "${SPOKE_PRIVATE_SUBNETS[$i]}" \
    --route-table-id "${PRI_RT}"
done
ok "Spoke route tables configured"

# ── Attach Spoke VPC to TGW ───────────────────────────────────
SPOKE_TGW_ATTACH=$(aws ec2 create-transit-gateway-vpc-attachment \
  --transit-gateway-id "${TGW_ID}" \
  --vpc-id "${SPOKE_VPC_ID}" \
  --subnet-ids "${SPOKE_PRIVATE_SUBNETS[@]}" \
  --query 'TransitGatewayVpcAttachment.TransitGatewayAttachmentId' --output text)
aws ec2 create-tags --resources "${SPOKE_TGW_ATTACH}" \
  --tags Key=Name,Value=tgw-attach-spoke-prod
info "Waiting for spoke TGW attachment (~20s)"
sleep 20
aws ec2 associate-transit-gateway-route-table \
  --transit-gateway-attachment-id "${SPOKE_TGW_ATTACH}" \
  --transit-gateway-route-table-id "${TGW_SPOKE_RT}"

# Default route in spoke RT: send all traffic to Hub via TGW
aws ec2 create-transit-gateway-route \
  --destination-cidr-block "0.0.0.0/0" \
  --transit-gateway-route-table-id "${TGW_SPOKE_RT}" \
  --transit-gateway-attachment-id "${HUB_TGW_ATTACH}"
ok "Spoke attached to TGW and routed through Hub"

# ── VPC Endpoints — private access to AWS services ───────────
# S3 Gateway endpoint (free)
S3_VPCE=$(aws ec2 create-vpc-endpoint \
  --vpc-id "${SPOKE_VPC_ID}" \
  --service-name "com.amazonaws.${REGION}.s3" \
  --vpc-endpoint-type Gateway \
  --query 'VpcEndpoint.VpcEndpointId' --output text)
ok "S3 VPC endpoint: ${S3_VPCE}"

# Security group for Interface endpoints
VPCE_SG=$(aws ec2 create-security-group \
  --group-name vpce-sg \
  --description "VPC Endpoints SG" \
  --vpc-id "${SPOKE_VPC_ID}" \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
  --group-id "${VPCE_SG}" \
  --protocol tcp --port 443 \
  --cidr "${SPOKE_VPC_CIDR}"

for SVC in ecr.api ecr.dkr sts secretsmanager ssm; do
  aws ec2 create-vpc-endpoint \
    --vpc-id "${SPOKE_VPC_ID}" \
    --service-name "com.amazonaws.${REGION}.${SVC}" \
    --vpc-endpoint-type Interface \
    --subnet-ids "${SPOKE_PRIVATE_SUBNETS[@]}" \
    --security-group-ids "${VPCE_SG}" \
    --private-dns-enabled \
    --no-cli-pager >/dev/null
  info "VPC endpoint created: ${SVC}"
done
ok "VPC Interface endpoints ready"

# ================================================================
# PHASE 5 — SECURITY GROUPS
# ================================================================
log "PHASE 5: Creating Security Groups"

# EKS Cluster SG
EKS_CLUSTER_SG=$(aws ec2 create-security-group \
  --group-name eks-cluster-sg \
  --description "EKS control plane SG" \
  --vpc-id "${SPOKE_VPC_ID}" \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
  --group-id "${EKS_CLUSTER_SG}" \
  --protocol tcp --port 443 --cidr "${SPOKE_VPC_CIDR}"
aws ec2 create-tags --resources "${EKS_CLUSTER_SG}" \
  --tags Key=Name,Value=eks-cluster-sg

# EKS Nodes SG
EKS_NODE_SG=$(aws ec2 create-security-group \
  --group-name eks-node-sg \
  --description "EKS worker node SG" \
  --vpc-id "${SPOKE_VPC_ID}" \
  --query 'GroupId' --output text)
# Node-to-node all traffic
aws ec2 authorize-security-group-ingress \
  --group-id "${EKS_NODE_SG}" \
  --protocol "-1" \
  --source-group "${EKS_NODE_SG}"
# Control plane → nodes (ephemeral ports)
aws ec2 authorize-security-group-ingress \
  --group-id "${EKS_NODE_SG}" \
  --protocol tcp --port 1025 --port 65535 \
  --source-group "${EKS_CLUSTER_SG}" 2>/dev/null || \
aws ec2 authorize-security-group-ingress \
  --group-id "${EKS_NODE_SG}" \
  --ip-permissions \
    "IpProtocol=tcp,FromPort=1025,ToPort=65535,UserIdGroupPairs=[{GroupId=${EKS_CLUSTER_SG}}]"
aws ec2 authorize-security-group-egress \
  --group-id "${EKS_NODE_SG}" \
  --protocol "-1" --cidr "0.0.0.0/0" 2>/dev/null || true
aws ec2 create-tags --resources "${EKS_NODE_SG}" \
  --tags \
    Key=Name,Value=eks-node-sg \
    Key="kubernetes.io/cluster/${CLUSTER_NAME}",Value=owned

# RDS SG — only from EKS nodes
RDS_SG=$(aws ec2 create-security-group \
  --group-name rds-postgres-sg \
  --description "RDS PostgreSQL — EKS only" \
  --vpc-id "${SPOKE_VPC_ID}" \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
  --group-id "${RDS_SG}" \
  --ip-permissions \
    "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=${EKS_NODE_SG}}]"
aws ec2 create-tags --resources "${RDS_SG}" \
  --tags Key=Name,Value=rds-postgres-sg
ok "Security groups: cluster=${EKS_CLUSTER_SG} nodes=${EKS_NODE_SG} rds=${RDS_SG}"

# ================================================================
# PHASE 6 — IAM ROLES
# ================================================================
log "PHASE 6: Creating IAM roles"

# EKS Cluster role
aws iam create-role \
  --role-name eks-cluster-role \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{
      "Effect":"Allow",
      "Principal":{"Service":"eks.amazonaws.com"},
      "Action":"sts:AssumeRole"
    }]
  }' --no-cli-pager 2>/dev/null || true
aws iam attach-role-policy \
  --role-name eks-cluster-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

# EKS Node role
aws iam create-role \
  --role-name eks-node-role \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{
      "Effect":"Allow",
      "Principal":{"Service":"ec2.amazonaws.com"},
      "Action":"sts:AssumeRole"
    }]
  }' --no-cli-pager 2>/dev/null || true
for POL in \
  AmazonEKSWorkerNodePolicy \
  AmazonEKS_CNI_Policy \
  AmazonEC2ContainerRegistryReadOnly \
  AmazonSSMManagedInstanceCore; do
  aws iam attach-role-policy \
    --role-name eks-node-role \
    --policy-arn "arn:aws:iam::aws:policy/${POL}"
done

# External Secrets / Secrets Manager policy
aws iam create-policy \
  --policy-name ExternalSecretsPolicy \
  --policy-document '{
    "Version":"2012-10-17",
    "Statement":[{
      "Effect":"Allow",
      "Action":["secretsmanager:GetSecretValue","secretsmanager:DescribeSecret"],
      "Resource":"*"
    }]
  }' --no-cli-pager 2>/dev/null || true

# ALB Controller policy
curl -fsSLo /tmp/alb-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.0/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file:///tmp/alb-policy.json \
  --no-cli-pager 2>/dev/null || true

# RDS monitoring role
aws iam create-role \
  --role-name rds-monitoring-role \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{
      "Effect":"Allow",
      "Principal":{"Service":"monitoring.rds.amazonaws.com"},
      "Action":"sts:AssumeRole"
    }]
  }' --no-cli-pager 2>/dev/null || true
aws iam attach-role-policy \
  --role-name rds-monitoring-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole
ok "IAM roles created"

# ================================================================
# PHASE 7 — KMS KEY for EKS secrets encryption
# ================================================================
log "PHASE 7: Creating KMS key for EKS"

KMS_KEY_ARN=$(aws kms create-key \
  --description "EKS secrets encryption" \
  --enable-key-rotation \
  --query 'KeyMetadata.Arn' --output text)
aws kms create-alias \
  --alias-name "alias/eks-${CLUSTER_NAME}" \
  --target-key-id "${KMS_KEY_ARN}" 2>/dev/null || true
ok "KMS key: ${KMS_KEY_ARN}"

# ================================================================
# PHASE 8 — EKS CLUSTER
# ================================================================
log "PHASE 8: Creating EKS cluster (this takes ~12 min)"

CLUSTER_SUBNET_IDS="${SPOKE_PRIVATE_SUBNETS[*]} ${SPOKE_PUBLIC_SUBNETS[*]}"

aws eks create-cluster \
  --name "${CLUSTER_NAME}" \
  --version "${K8S_VERSION}" \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/eks-cluster-role" \
  --resources-vpc-config \
    subnetIds="$(echo ${CLUSTER_SUBNET_IDS} | tr ' ' ',')",\
securityGroupIds="${EKS_CLUSTER_SG}",\
endpointPrivateAccess=true,\
endpointPublicAccess=false \
  --encryption-config \
    "resources=secrets,provider={keyArn=${KMS_KEY_ARN}}" \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}' \
  --tags Project=eks-hub-spoke,Environment=production \
  --no-cli-pager

info "Waiting for EKS cluster ACTIVE state (~12 min)"
aws eks wait cluster-active --name "${CLUSTER_NAME}"
ok "EKS cluster active: ${CLUSTER_NAME}"

# Update kubeconfig
aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${REGION}"

# ================================================================
# PHASE 9 — EKS NODE GROUPS
# ================================================================
log "PHASE 9: Creating EKS node groups"

NODE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/eks-node-role"
PRIVATE_SUBNET_CSV=$(IFS=','; echo "${SPOKE_PRIVATE_SUBNETS[*]}")

# System node group (for addons)
aws eks create-nodegroup \
  --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name system-nodes \
  --node-role "${NODE_ROLE_ARN}" \
  --subnets ${SPOKE_PRIVATE_SUBNETS[@]} \
  --instance-types m5.large \
  --scaling-config minSize=2,maxSize=4,desiredSize=2 \
  --ami-type AL2_x86_64 \
  --capacity-type ON_DEMAND \
  --update-config maxUnavailable=1 \
  --labels role=system \
  --tags Project=eks-hub-spoke \
  --no-cli-pager

# App node group (dedicated to microservices)
aws eks create-nodegroup \
  --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name app-nodes \
  --node-role "${NODE_ROLE_ARN}" \
  --subnets ${SPOKE_PRIVATE_SUBNETS[@]} \
  --instance-types "${NODE_TYPE}" \
  --scaling-config minSize=${NODE_MIN},maxSize=${NODE_MAX},desiredSize=${NODE_DESIRED} \
  --ami-type AL2_x86_64 \
  --capacity-type ON_DEMAND \
  --update-config maxUnavailable=1 \
  --labels role=app \
  --taints "key=dedicated,value=app,effect=NO_SCHEDULE" \
  --tags Project=eks-hub-spoke \
  --no-cli-pager

info "Waiting for node groups ACTIVE (~5 min)"
aws eks wait nodegroup-active \
  --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name system-nodes
aws eks wait nodegroup-active \
  --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name app-nodes
ok "Node groups ready"
kubectl get nodes

# ================================================================
# PHASE 10 — EKS ADDONS
# ================================================================
log "PHASE 10: Installing EKS managed addons"

for ADDON in vpc-cni coredns kube-proxy aws-ebs-csi-driver; do
  aws eks create-addon \
    --cluster-name "${CLUSTER_NAME}" \
    --addon-name "${ADDON}" \
    --resolve-conflicts OVERWRITE \
    --no-cli-pager 2>/dev/null || \
  aws eks update-addon \
    --cluster-name "${CLUSTER_NAME}" \
    --addon-name "${ADDON}" \
    --resolve-conflicts OVERWRITE \
    --no-cli-pager
  info "Addon installed: ${ADDON}"
done

# Enable OIDC provider (required for IRSA)
OIDC_URL=$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --query "cluster.identity.oidc.issuer" --output text)
OIDC_ID=$(echo "${OIDC_URL}" | awk -F/ '{print $NF}')

aws iam create-open-id-connect-provider \
  --url "${OIDC_URL}" \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list "9e99a48a9960b14926bb7f3b02e22da2b0ab7280" \
  --no-cli-pager 2>/dev/null || true
OIDC_PROVIDER="oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}"
ok "OIDC provider: ${OIDC_PROVIDER}"

# ================================================================
# PHASE 11 — HELM ADDONS (ALB, External Secrets, Prometheus)
# ================================================================
log "PHASE 11: Installing Helm addons"

helm repo add eks                  https://aws.github.io/eks-charts
helm repo add external-secrets     https://charts.external-secrets.io
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add metrics-server       https://kubernetes-sigs.github.io/metrics-server/
helm repo update

# ── IRSA for ALB controller ───────────────────────────────────
kubectl create namespace kube-system --dry-run=client -o yaml | kubectl apply -f -

aws iam create-role \
  --role-name aws-load-balancer-controller-role \
  --assume-role-policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Effect\":\"Allow\",
      \"Principal\":{\"Federated\":\"arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}\"},
      \"Action\":\"sts:AssumeRoleWithWebIdentity\",
      \"Condition\":{\"StringEquals\":{
        \"${OIDC_PROVIDER}:sub\":\"system:serviceaccount:kube-system:aws-load-balancer-controller\",
        \"${OIDC_PROVIDER}:aud\":\"sts.amazonaws.com\"
      }}
    }]
  }" --no-cli-pager 2>/dev/null || true

aws iam attach-role-policy \
  --role-name aws-load-balancer-controller-role \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"

kubectl create serviceaccount aws-load-balancer-controller \
  -n kube-system --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount aws-load-balancer-controller \
  -n kube-system \
  "eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/aws-load-balancer-controller-role" \
  --overwrite

SPOKE_VPC_ACTUAL=$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

helm upgrade --install aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="${CLUSTER_NAME}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="${REGION}" \
  --set vpcId="${SPOKE_VPC_ACTUAL}" \
  --wait
ok "ALB Ingress Controller installed"

# ── Metrics Server ────────────────────────────────────────────
helm upgrade --install metrics-server \
  metrics-server/metrics-server \
  --namespace kube-system \
  --set args[0]="--kubelet-insecure-tls" \
  --wait
ok "Metrics Server installed"

# ── External Secrets Operator ─────────────────────────────────
kubectl create namespace external-secrets \
  --dry-run=client -o yaml | kubectl apply -f -

aws iam create-role \
  --role-name external-secrets-role \
  --assume-role-policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Effect\":\"Allow\",
      \"Principal\":{\"Federated\":\"arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}\"},
      \"Action\":\"sts:AssumeRoleWithWebIdentity\",
      \"Condition\":{\"StringEquals\":{
        \"${OIDC_PROVIDER}:sub\":\"system:serviceaccount:external-secrets:external-secrets-sa\",
        \"${OIDC_PROVIDER}:aud\":\"sts.amazonaws.com\"
      }}
    }]
  }" --no-cli-pager 2>/dev/null || true
aws iam attach-role-policy \
  --role-name external-secrets-role \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/ExternalSecretsPolicy"

helm upgrade --install external-secrets \
  external-secrets/external-secrets \
  --namespace external-secrets \
  --set installCRDs=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="arn:aws:iam::${ACCOUNT_ID}:role/external-secrets-role" \
  --wait
ok "External Secrets Operator installed"

# ── Prometheus + Grafana ──────────────────────────────────────
kubectl create namespace monitoring \
  --dry-run=client -o yaml | kubectl apply -f -
GRAFANA_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 16)
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.adminPassword="${GRAFANA_PASS}" \
  --set prometheus.prometheusSpec.retention=15d \
  --wait
info "Grafana password: ${GRAFANA_PASS} — save this!"
ok "Prometheus + Grafana installed"

# ================================================================
# PHASE 12 — WAF (AWS CLI)
# ================================================================
log "PHASE 12: Creating WAF v2 Web ACL"

WAF_ACL=$(aws wafv2 create-web-acl \
  --name alb-waf-acl \
  --scope REGIONAL \
  --default-action Allow={} \
  --visibility-config \
    SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=alb-waf-acl \
  --rules '[
    {
      "Name":"AWSManagedRulesCommonRuleSet","Priority":1,
      "OverrideAction":{"None":{}},
      "Statement":{"ManagedRuleGroupStatement":{"VendorName":"AWS","Name":"AWSManagedRulesCommonRuleSet"}},
      "VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"CommonRuleSet"}
    },
    {
      "Name":"AWSManagedRulesSQLiRuleSet","Priority":2,
      "OverrideAction":{"None":{}},
      "Statement":{"ManagedRuleGroupStatement":{"VendorName":"AWS","Name":"AWSManagedRulesSQLiRuleSet"}},
      "VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"SQLiRuleSet"}
    },
    {
      "Name":"AWSManagedRulesBotControlRuleSet","Priority":3,
      "OverrideAction":{"None":{}},
      "Statement":{"ManagedRuleGroupStatement":{"VendorName":"AWS","Name":"AWSManagedRulesBotControlRuleSet","ManagedRuleGroupConfigs":[{"AWSManagedRulesBotControlRuleSet":{"InspectionLevel":"TARGETED"}}]}},
      "VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"BotControlRuleSet"}
    },
    {
      "Name":"RateLimitPerIP","Priority":4,
      "Action":{"Block":{}},
      "Statement":{"RateBasedStatement":{"Limit":500,"AggregateKeyType":"IP"}},
      "VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"RateLimitPerIP"}
    },
    {
      "Name":"AWSManagedRulesKnownBadInputsRuleSet","Priority":5,
      "OverrideAction":{"None":{}},
      "Statement":{"ManagedRuleGroupStatement":{"VendorName":"AWS","Name":"AWSManagedRulesKnownBadInputsRuleSet"}},
      "VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"BadInputsRuleSet"}
    }
  ]' \
  --region "${REGION}" \
  --query 'Summary.ARN' --output text)
ok "WAF Web ACL: ${WAF_ACL}"

# ================================================================
# PHASE 13 — RDS POSTGRESQL
# ================================================================
log "PHASE 13: Creating RDS PostgreSQL (Multi-AZ)"

# DB subnet group
aws rds create-db-subnet-group \
  --db-subnet-group-name postgres-subnet-group \
  --db-subnet-group-description "PostgreSQL subnet group" \
  --subnet-ids "${SPOKE_DB_SUBNETS[@]}" \
  --tags Key=Name,Value=postgres-subnet-group \
  --no-cli-pager

# DB parameter group
aws rds create-db-parameter-group \
  --db-parameter-group-name postgres15-params \
  --db-parameter-group-family postgres15 \
  --description "PostgreSQL 15 custom params" \
  --no-cli-pager 2>/dev/null || true
aws rds modify-db-parameter-group \
  --db-parameter-group-name postgres15-params \
  --parameters \
    "ParameterName=log_connections,ParameterValue=1,ApplyMethod=immediate" \
    "ParameterName=log_min_duration_statement,ParameterValue=1000,ApplyMethod=immediate" \
  --no-cli-pager

# Store DB password in Secrets Manager
aws secretsmanager create-secret \
  --name "prod/postgres/credentials" \
  --description "RDS PostgreSQL credentials" \
  --secret-string "{
    \"username\":\"${DB_USER}\",
    \"password\":\"${DB_PASSWORD}\",
    \"dbname\":\"${DB_NAME}\",
    \"port\":5432
  }" \
  --region "${REGION}" \
  --no-cli-pager 2>/dev/null || \
aws secretsmanager update-secret \
  --secret-id "prod/postgres/credentials" \
  --secret-string "{
    \"username\":\"${DB_USER}\",
    \"password\":\"${DB_PASSWORD}\",
    \"dbname\":\"${DB_NAME}\",
    \"port\":5432
  }" --no-cli-pager
ok "DB credentials stored in Secrets Manager"

aws rds create-db-instance \
  --db-instance-identifier prod-postgres \
  --db-instance-class "${DB_INSTANCE_CLASS}" \
  --engine postgres \
  --engine-version "15.6" \
  --master-username "${DB_USER}" \
  --master-user-password "${DB_PASSWORD}" \
  --db-name "${DB_NAME}" \
  --allocated-storage 100 \
  --max-allocated-storage 1000 \
  --storage-type gp3 \
  --storage-encrypted \
  --multi-az \
  --db-subnet-group-name postgres-subnet-group \
  --vpc-security-group-ids "${RDS_SG}" \
  --db-parameter-group-name postgres15-params \
  --backup-retention-period 14 \
  --preferred-backup-window "03:00-04:00" \
  --preferred-maintenance-window "sun:04:00-sun:05:00" \
  --enable-performance-insights \
  --performance-insights-retention-period 7 \
  --monitoring-interval 60 \
  --monitoring-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/rds-monitoring-role" \
  --deletion-protection \
  --no-publicly-accessible \
  --no-cli-pager \
  --tags Key=Name,Value=prod-postgres

info "Waiting for RDS available (~15 min) — continuing other setup"
# Don't block — RDS takes long; we'll wait before applying k8s manifests

# ================================================================
# PHASE 14 — ECR REPOSITORIES
# ================================================================
log "PHASE 14: Creating ECR repositories"

for SVC in microservice-a microservice-b; do
  aws ecr create-repository \
    --repository-name "${SVC}" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    --region "${REGION}" \
    --no-cli-pager 2>/dev/null || true

  aws ecr put-lifecycle-policy \
    --repository-name "${SVC}" \
    --lifecycle-policy '{
      "rules":[{
        "rulePriority":1,
        "description":"Keep last 10 images",
        "selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":10},
        "action":{"type":"expire"}
      }]
    }' --region "${REGION}" --no-cli-pager
  info "ECR repo ready: ${SVC}"
done
ok "ECR repos created"

# Build + push images if Docker is available
if command -v docker &>/dev/null; then
  aws ecr get-login-password --region "${REGION}" \
    | docker login --username AWS --password-stdin "${ECR}"

  for SVC in microservice-a microservice-b; do
    if [ -d "./${SVC}" ]; then
      docker buildx build \
        --platform linux/amd64 \
        --tag "${ECR}/${SVC}:1.0.0" \
        --tag "${ECR}/${SVC}:latest" \
        --push "./${SVC}"
      ok "Pushed ${SVC}"
    else
      info "Directory ./${SVC} not found — skipping build (push manually)"
    fi
  done
fi

# ================================================================
# PHASE 15 — IRSA ROLES FOR MICROSERVICES
# ================================================================
log "PHASE 15: Creating IRSA roles for microservices"

for SVC in microservice-a microservice-b; do
  NS="${SVC}"
  aws iam create-role \
    --role-name "${SVC}-role" \
    --assume-role-policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[{
        \"Effect\":\"Allow\",
        \"Principal\":{\"Federated\":\"arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}\"},
        \"Action\":\"sts:AssumeRoleWithWebIdentity\",
        \"Condition\":{\"StringEquals\":{
          \"${OIDC_PROVIDER}:sub\":\"system:serviceaccount:${NS}:${SVC}-sa\",
          \"${OIDC_PROVIDER}:aud\":\"sts.amazonaws.com\"
        }}
      }]
    }" --no-cli-pager 2>/dev/null || true

  aws iam attach-role-policy \
    --role-name "${SVC}-role" \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/ExternalSecretsPolicy"
  ok "IRSA role created: ${SVC}-role"
done

# ================================================================
# PHASE 16 — KUBERNETES MANIFESTS (inline via heredoc)
# ================================================================
log "PHASE 16: Applying Kubernetes manifests"

# Wait for RDS now that we need the endpoint
info "Waiting for RDS to be available (if not already)"
aws rds wait db-instance-available \
  --db-instance-identifier prod-postgres
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier prod-postgres \
  --query 'DBInstances[0].Endpoint.Address' --output text)

# Update Secrets Manager with RDS host
aws secretsmanager update-secret \
  --secret-id "prod/postgres/credentials" \
  --secret-string "{
    \"username\":\"${DB_USER}\",
    \"password\":\"${DB_PASSWORD}\",
    \"host\":\"${RDS_ENDPOINT}\",
    \"dbname\":\"${DB_NAME}\",
    \"port\":5432
  }" --no-cli-pager
ok "RDS endpoint: ${RDS_ENDPOINT} — stored in Secrets Manager"

# ── ClusterSecretStore ────────────────────────────────────────
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${REGION}
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
EOF

# ── Namespace: microservice-a ─────────────────────────────────
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: microservice-a
  labels:
    name: microservice-a
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: microservice-a-sa
  namespace: microservice-a
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${ACCOUNT_ID}:role/microservice-a-role
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: postgres-credentials
  namespace: microservice-a
spec:
  refreshInterval: "1h"
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: postgres-credentials
    creationPolicy: Owner
  data:
    - secretKey: DB_HOST
      remoteRef:
        key: prod/postgres/credentials
        property: host
    - secretKey: DB_PORT
      remoteRef:
        key: prod/postgres/credentials
        property: port
    - secretKey: DB_NAME
      remoteRef:
        key: prod/postgres/credentials
        property: dbname
    - secretKey: DB_USER
      remoteRef:
        key: prod/postgres/credentials
        property: username
    - secretKey: DB_PASSWORD
      remoteRef:
        key: prod/postgres/credentials
        property: password
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: microservice-a
  namespace: microservice-a
  labels:
    app: microservice-a
spec:
  replicas: 3
  selector:
    matchLabels:
      app: microservice-a
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: microservice-a
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "3000"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: microservice-a-sa
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: microservice-a
      tolerations:
        - key: dedicated
          value: app
          effect: NoSchedule
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: microservice-a
          image: ${ECR}/microservice-a:1.0.0
          imagePullPolicy: Always
          ports:
            - containerPort: 3000
              name: http
          envFrom:
            - secretRef:
                name: postgres-credentials
          env:
            - name: NODE_ENV
              value: production
            - name: PORT
              value: "3000"
            - name: DB_SSL
              value: "true"
            - name: DB_POOL_MIN
              value: "2"
            - name: DB_POOL_MAX
              value: "10"
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /health/live
              port: 3000
            initialDelaySeconds: 15
            periodSeconds: 20
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 1000
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: microservice-a
  namespace: microservice-a
spec:
  type: ClusterIP
  selector:
    app: microservice-a
  ports:
    - port: 80
      targetPort: 3000
      name: http
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: microservice-a-hpa
  namespace: microservice-a
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: microservice-a
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: microservice-a-pdb
  namespace: microservice-a
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: microservice-a
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: microservice-a-netpol
  namespace: microservice-a
spec:
  podSelector:
    matchLabels:
      app: microservice-a
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
        - namespaceSelector:
            matchLabels:
              name: microservice-b
      ports:
        - port: 3000
  egress:
    - ports:
        - port: 5432
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    - ports:
        - port: 443
EOF

# ── Namespace: microservice-b ─────────────────────────────────
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: microservice-b
  labels:
    name: microservice-b
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: microservice-b-sa
  namespace: microservice-b
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${ACCOUNT_ID}:role/microservice-b-role
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: postgres-credentials
  namespace: microservice-b
spec:
  refreshInterval: "1h"
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: postgres-credentials
    creationPolicy: Owner
  data:
    - secretKey: DB_HOST
      remoteRef:
        key: prod/postgres/credentials
        property: host
    - secretKey: DB_PORT
      remoteRef:
        key: prod/postgres/credentials
        property: port
    - secretKey: DB_NAME
      remoteRef:
        key: prod/postgres/credentials
        property: dbname
    - secretKey: DB_USER
      remoteRef:
        key: prod/postgres/credentials
        property: username
    - secretKey: DB_PASSWORD
      remoteRef:
        key: prod/postgres/credentials
        property: password
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: microservice-b
  namespace: microservice-b
  labels:
    app: microservice-b
spec:
  replicas: 2
  selector:
    matchLabels:
      app: microservice-b
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: microservice-b
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8000"
    spec:
      serviceAccountName: microservice-b-sa
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: microservice-b
      tolerations:
        - key: dedicated
          value: app
          effect: NoSchedule
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        fsGroup: 1001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: microservice-b
          image: ${ECR}/microservice-b:1.0.0
          imagePullPolicy: Always
          ports:
            - containerPort: 8000
              name: http
          envFrom:
            - secretRef:
                name: postgres-credentials
          env:
            - name: ENV
              value: production
            - name: PORT
              value: "8000"
            - name: SERVICE_A_URL
              value: "http://microservice-a.microservice-a.svc.cluster.local"
            - name: DB_SSL_MODE
              value: require
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: 800m
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 20
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /ready
              port: 8000
            initialDelaySeconds: 10
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 1001
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: microservice-b
  namespace: microservice-b
spec:
  type: ClusterIP
  selector:
    app: microservice-b
  ports:
    - port: 80
      targetPort: 8000
      name: http
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: microservice-b-hpa
  namespace: microservice-b
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: microservice-b
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 75
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: microservice-b-pdb
  namespace: microservice-b
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: microservice-b
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: microservice-b-netpol
  namespace: microservice-b
spec:
  podSelector:
    matchLabels:
      app: microservice-b
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 8000
  egress:
    - ports:
        - port: 5432
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    - ports:
        - port: 443
    - to:
        - namespaceSelector:
            matchLabels:
              name: microservice-a
      ports:
        - port: 80
EOF

# ── ALB Ingress ───────────────────────────────────────────────
# NOTE: Replace CERT_ARN with your ACM certificate ARN
CERT_ARN="${ACM_CERT_ARN:-arn:aws:acm:${REGION}:${ACCOUNT_ID}:certificate/REPLACE_ME}"

kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: microservices-ingress
  namespace: microservice-a
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443},{"HTTP":80}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/certificate-arn: "${CERT_ARN}"
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    alb.ingress.kubernetes.io/healthcheck-path: /health/ready
    alb.ingress.kubernetes.io/load-balancer-attributes: "access_logs.s3.enabled=false,deletion_protection.enabled=true,routing.http.drop_invalid_header_fields.enabled=true"
    alb.ingress.kubernetes.io/wafv2-acl-arn: "${WAF_ACL}"
    alb.ingress.kubernetes.io/group.name: prod-alb
    alb.ingress.kubernetes.io/group.order: "10"
spec:
  rules:
    - http:
        paths:
          - path: /api/v1
            pathType: Prefix
            backend:
              service:
                name: microservice-a
                port:
                  number: 80
          - path: /api/v2
            pathType: Prefix
            backend:
              service:
                name: microservice-b.microservice-b.svc.cluster.local
                port:
                  number: 80
EOF

# ================================================================
# PHASE 17 — WAIT + VERIFY
# ================================================================
log "PHASE 17: Waiting for rollouts and verifying"

kubectl rollout status deployment/microservice-a \
  -n microservice-a --timeout=300s
kubectl rollout status deployment/microservice-b \
  -n microservice-b --timeout=300s

ALB_DNS=$(kubectl get ingress microservices-ingress \
  -n microservice-a \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

echo ""
echo "================================================================"
echo " DEPLOYMENT COMPLETE"
echo "================================================================"
echo " Cluster:       ${CLUSTER_NAME}"
echo " Region:        ${REGION}"
echo " Hub VPC:       ${HUB_VPC_ID}"
echo " Spoke VPC:     ${SPOKE_VPC_ID}"
echo " TGW:           ${TGW_ID}"
echo " RDS:           ${RDS_ENDPOINT}"
echo " WAF ACL:       ${WAF_ACL}"
echo " ECR:           ${ECR}"
echo " ALB DNS:       ${ALB_DNS}"
echo " Grafana pass:  ${GRAFANA_PASS}"
echo "================================================================"
echo ""
echo " Useful commands:"
echo "   kubectl get nodes"
echo "   kubectl get pods -A"
echo "   kubectl get hpa -A"
echo "   kubectl get externalsecret -A"
echo "   curl -k https://${ALB_DNS}/api/v1/users"
echo "   curl -k https://${ALB_DNS}/api/v2/orders"
echo ""
echo " WAF test:"
echo "   aws wafv2 get-sampled-requests \\"
echo "     --web-acl-arn '${WAF_ACL}' \\"
echo "     --rule-metric-name RateLimitPerIP \\"
echo "     --scope REGIONAL \\"
echo "     --time-window StartTime=\$(date -d '1 hour ago' +%s),EndTime=\$(date +%s) \\"
echo "     --max-items 10"
echo "================================================================"
