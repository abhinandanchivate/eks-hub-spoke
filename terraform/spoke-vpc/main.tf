# ============================================================
# terraform/spoke-vpc/main.tf
# Spoke VPC: EKS cluster, Node Groups, RDS PostgreSQL, Security Groups
# ============================================================

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws        = { source = "hashicorp/aws",        version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes",  version = "~> 2.0" }
    helm       = { source = "hashicorp/helm",        version = "~> 2.0" }
  }
  backend "s3" {
    bucket = "my-terraform-state-bucket"
    key    = "spoke-vpc/terraform.tfstate"
    region = "ap-south-1"
  }
}

provider "aws" { region = var.aws_region }

data "terraform_remote_state" "hub" {
  backend = "s3"
  config = {
    bucket = "my-terraform-state-bucket"
    key    = "hub-vpc/terraform.tfstate"
    region = "ap-south-1"
  }
}

locals {
  cluster_name = "prod-eks-cluster"
  azs          = data.aws_availability_zones.available.names
  public_cidrs = [for i, az in local.azs : cidrsubnet(var.spoke_vpc_cidr, 8, i)]
  private_cidrs = [for i, az in local.azs : cidrsubnet(var.spoke_vpc_cidr, 8, i + 10)]
  db_cidrs      = [for i, az in local.azs : cidrsubnet(var.spoke_vpc_cidr, 8, i + 20)]
}

variable "aws_region"      { default = "ap-south-1" }
variable "spoke_vpc_cidr"  { default = "10.1.0.0/16" }
variable "db_password" {
  type      = string
  sensitive = true
}

data "aws_availability_zones" "available" { state = "available" }
data "aws_caller_identity" "current" {}

# ── Spoke VPC ────────────────────────────────────────────────
resource "aws_vpc" "spoke" {
  cidr_block           = var.spoke_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "spoke-vpc-prod", "kubernetes.io/cluster/${local.cluster_name}" = "shared" }
}

# ── Subnets ──────────────────────────────────────────────────
resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.spoke.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name                                          = "spoke-public-${count.index + 1}"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }
}

resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.spoke.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags = {
    Name                                          = "spoke-private-${count.index + 1}"
    "kubernetes.io/cluster/${local.cluster_name}" = "owned"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}

resource "aws_subnet" "db" {
  count             = 3
  vpc_id            = aws_vpc.spoke.id
  cidr_block        = local.db_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags = { Name = "spoke-db-${count.index + 1}" }
}

# ── Gateways ─────────────────────────────────────────────────
resource "aws_internet_gateway" "spoke" {
  vpc_id = aws_vpc.spoke.id
  tags   = { Name = "spoke-igw" }
}

resource "aws_eip" "nat" {
  count  = 3
  domain = "vpc"
  tags   = { Name = "nat-eip-${count.index + 1}" }
}

resource "aws_nat_gateway" "main" {
  count         = 3
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.spoke]
  tags          = { Name = "nat-gw-${count.index + 1}" }
}

# ── Route Tables ─────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.spoke.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.spoke.id
  }
  # Route to hub via TGW
  route {
    cidr_block         = "10.0.0.0/8"
    transit_gateway_id = data.terraform_remote_state.hub.outputs.transit_gateway_id
  }
  tags = { Name = "spoke-rt-public" }
}

resource "aws_route_table" "private" {
  count  = 3
  vpc_id = aws_vpc.spoke.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }
  route {
    cidr_block         = "10.0.0.0/8"
    transit_gateway_id = data.terraform_remote_state.hub.outputs.transit_gateway_id
  }
  tags = { Name = "spoke-rt-private-${count.index + 1}" }
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ── TGW Attachment (spoke → hub) ─────────────────────────────
resource "aws_ec2_transit_gateway_vpc_attachment" "spoke" {
  subnet_ids         = aws_subnet.private[*].id
  transit_gateway_id = data.terraform_remote_state.hub.outputs.transit_gateway_id
  vpc_id             = aws_vpc.spoke.id
  tags               = { Name = "tgw-attach-spoke-prod" }
}

resource "aws_ec2_transit_gateway_route_table_association" "spoke" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke.id
  transit_gateway_route_table_id = data.terraform_remote_state.hub.outputs.tgw_spoke_rt_id
}

# ── VPC Endpoints (private access to AWS services) ───────────
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.spoke.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
  tags              = { Name = "spoke-vpce-s3" }
}

resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.spoke.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true
  tags                = { Name = "spoke-vpce-ecr-api" }
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.spoke.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true
  tags                = { Name = "spoke-vpce-ecr-dkr" }
}

# ── Security Groups ───────────────────────────────────────────
resource "aws_security_group" "eks_cluster" {
  name        = "eks-cluster-sg"
  description = "EKS cluster control plane SG"
  vpc_id      = aws_vpc.spoke.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.spoke_vpc_cidr]
    description = "API server from VPC"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "eks-cluster-sg" }
}

resource "aws_security_group" "eks_nodes" {
  name        = "eks-node-sg"
  description = "EKS worker nodes SG"
  vpc_id      = aws_vpc.spoke.id

  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
    description = "Node-to-node"
  }
  ingress {
    from_port       = 1025
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_cluster.id]
    description     = "Control plane to nodes"
  }
  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_cluster.id]
    description     = "Control plane webhook"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "eks-node-sg", "kubernetes.io/cluster/${local.cluster_name}" = "owned" }
}

resource "aws_security_group" "rds" {
  name        = "rds-postgres-sg"
  description = "RDS PostgreSQL - only from EKS nodes"
  vpc_id      = aws_vpc.spoke.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
    description     = "PostgreSQL from EKS"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "rds-postgres-sg" }
}

resource "aws_security_group" "vpce" {
  name        = "vpce-sg"
  description = "VPC Endpoints SG"
  vpc_id      = aws_vpc.spoke.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.spoke_vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "vpce-sg" }
}

# ── IAM for EKS ──────────────────────────────────────────────
data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service"; identifiers = ["eks.amazonaws.com"] }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service"; identifiers = ["ec2.amazonaws.com"] }
  }
}

resource "aws_iam_role" "node" {
  name               = "eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ── EKS Cluster ───────────────────────────────────────────────
resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.30"

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = false  # private only — use VPN or bastion
  }

  encryption_config {
    provider { key_arn = aws_kms_key.eks.arn }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]
  tags = { Name = local.cluster_name }
}

resource "aws_kms_key" "eks" {
  description             = "EKS secrets encryption key"
  deletion_window_in_days = 10
  enable_key_rotation     = true
  tags                    = { Name = "eks-kms" }
}

# ── EKS Node Groups ───────────────────────────────────────────
resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "app-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = ["m5.xlarge"]
  capacity_type   = "ON_DEMAND"

  scaling_config {
    desired_size = 3
    min_size     = 2
    max_size     = 10
  }

  update_config { max_unavailable = 1 }

  labels = { role = "app" }

  taint {
    key    = "dedicated"
    value  = "app"
    effect = "NO_SCHEDULE"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
  tags = { Name = "app-node-group" }
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "system-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = ["m5.large"]
  capacity_type   = "ON_DEMAND"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }

  labels = { role = "system" }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
  tags = { Name = "system-node-group" }
}

# ── RDS PostgreSQL ────────────────────────────────────────────
resource "aws_db_subnet_group" "postgres" {
  name       = "postgres-subnet-group"
  subnet_ids = aws_subnet.db[*].id
  tags       = { Name = "postgres-subnet-group" }
}

resource "aws_db_parameter_group" "postgres" {
  name   = "postgres15-params"
  family = "postgres15"

  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"  # log queries > 1s
  }
  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
  }
}

resource "aws_db_instance" "postgres" {
  identifier              = "prod-postgres"
  engine                  = "postgres"
  engine_version          = "15.6"
  instance_class          = "db.r6g.large"
  allocated_storage       = 100
  max_allocated_storage   = 1000
  storage_type            = "gp3"
  storage_encrypted       = true

  db_name  = "appdb"
  username = "dbadmin"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.postgres.name

  multi_az               = true
  publicly_accessible    = false
  deletion_protection    = true
  skip_final_snapshot    = false
  final_snapshot_identifier = "prod-postgres-final-snap"

  backup_retention_period = 14
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn

  tags = { Name = "prod-postgres" }
}

resource "aws_iam_role" "rds_monitoring" {
  name = "rds-monitoring-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ── Secrets Manager for DB credentials ───────────────────────
resource "aws_secretsmanager_secret" "db_creds" {
  name                    = "prod/postgres/credentials"
  recovery_window_in_days = 7
  tags                    = { Name = "prod-postgres-creds" }
}

resource "aws_secretsmanager_secret_version" "db_creds" {
  secret_id = aws_secretsmanager_secret.db_creds.id
  secret_string = jsonencode({
    username = "dbadmin"
    password = var.db_password
    host     = aws_db_instance.postgres.address
    port     = 5432
    dbname   = "appdb"
  })
}

# ── Outputs ──────────────────────────────────────────────────
output "cluster_name"       { value = aws_eks_cluster.main.name }
output "cluster_endpoint"   { value = aws_eks_cluster.main.endpoint }
output "rds_endpoint"       { value = aws_db_instance.postgres.address }
output "db_secret_arn"      { value = aws_secretsmanager_secret.db_creds.arn }
output "spoke_vpc_id"       { value = aws_vpc.spoke.id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
