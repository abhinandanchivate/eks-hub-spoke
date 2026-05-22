# ============================================================
# terraform/hub-vpc/main.tf
# Hub VPC: Transit Gateway, Network Firewall, shared services
# ============================================================

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket = "my-terraform-state-bucket"
    key    = "hub-vpc/terraform.tfstate"
    region = "ap-south-1"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = local.common_tags }
}

locals {
  common_tags = {
    Project     = "eks-hub-spoke"
    Environment = "production"
    ManagedBy   = "terraform"
  }
}

# ── Variables ────────────────────────────────────────────────
variable "aws_region"      { default = "ap-south-1" }
variable "hub_vpc_cidr"    { default = "10.0.0.0/16" }
variable "spoke_vpc_cidr"  { default = "10.1.0.0/16" }

# ── Hub VPC ─────────────────────────────────────────────────
resource "aws_vpc" "hub" {
  cidr_block           = var.hub_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "hub-vpc" }
}

resource "aws_subnet" "hub_firewall" {
  count             = 3
  vpc_id            = aws_vpc.hub.id
  cidr_block        = cidrsubnet(var.hub_vpc_cidr, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = { Name = "hub-firewall-${count.index + 1}" }
}

resource "aws_subnet" "hub_tgw" {
  count             = 3
  vpc_id            = aws_vpc.hub.id
  cidr_block        = cidrsubnet(var.hub_vpc_cidr, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = { Name = "hub-tgw-${count.index + 1}" }
}

data "aws_availability_zones" "available" { state = "available" }

# ── Internet Gateway (Hub) ───────────────────────────────────
resource "aws_internet_gateway" "hub" {
  vpc_id = aws_vpc.hub.id
  tags   = { Name = "hub-igw" }
}

# ── Transit Gateway ──────────────────────────────────────────
resource "aws_ec2_transit_gateway" "main" {
  description                     = "Central TGW for hub-spoke routing"
  amazon_side_asn                 = 64512
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  auto_accept_shared_attachments  = "enable"
  tags = { Name = "main-tgw" }
}

# TGW attachment to Hub VPC
resource "aws_ec2_transit_gateway_vpc_attachment" "hub" {
  subnet_ids         = aws_subnet.hub_tgw[*].id
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.hub.id
  tags               = { Name = "tgw-attach-hub" }
}

# TGW route tables
resource "aws_ec2_transit_gateway_route_table" "hub" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  tags               = { Name = "tgw-rt-hub" }
}

resource "aws_ec2_transit_gateway_route_table" "spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  tags               = { Name = "tgw-rt-spoke" }
}

resource "aws_ec2_transit_gateway_route_table_association" "hub" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.hub.id
}

# Route spoke traffic to hub
resource "aws_ec2_transit_gateway_route" "spoke_to_hub" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke.id
}

# ── AWS Network Firewall ─────────────────────────────────────
resource "aws_networkfirewall_rule_group" "stateful_deny" {
  capacity = 100
  name     = "stateful-deny-rules"
  type     = "STATEFUL"

  rule_group {
    rules_source {
      stateful_rule {
        action = "DROP"
        header {
          destination      = "ANY"
          destination_port = "ANY"
          direction        = "ANY"
          protocol         = "TCP"
          source           = "ANY"
          source_port      = "ANY"
        }
        rule_option {
          keyword  = "sid"
          settings = ["100"]
        }
      }
    }
  }
  tags = { Name = "stateful-deny-rules" }
}

resource "aws_networkfirewall_rule_group" "stateless_allow" {
  capacity = 100
  name     = "stateless-allow-rules"
  type     = "STATELESS"

  rule_group {
    rules_source {
      stateless_rules_and_custom_actions {
        stateless_rule {
          priority = 1
          rule_definition {
            actions = ["aws:pass"]
            match_attributes {
              source {
                address_definition = var.spoke_vpc_cidr
              }
              protocols = [6, 17]  # TCP + UDP
            }
          }
        }
      }
    }
  }
  tags = { Name = "stateless-allow-rules" }
}

resource "aws_networkfirewall_firewall_policy" "main" {
  name = "hub-firewall-policy"

  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.stateful_deny.arn
    }
    stateless_rule_group_reference {
      resource_arn     = aws_networkfirewall_rule_group.stateless_allow.arn
      priority         = 1
    }
  }
  tags = { Name = "hub-firewall-policy" }
}

resource "aws_networkfirewall_firewall" "main" {
  name                = "hub-network-firewall"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.main.arn
  vpc_id              = aws_vpc.hub.id

  dynamic "subnet_mapping" {
    for_each = aws_subnet.hub_firewall[*].id
    content { subnet_id = subnet_mapping.value }
  }
  tags = { Name = "hub-network-firewall" }
}

# ── Outputs ─────────────────────────────────────────────────
output "transit_gateway_id"    { value = aws_ec2_transit_gateway.main.id }
output "tgw_spoke_rt_id"       { value = aws_ec2_transit_gateway_route_table.spoke.id }
output "hub_vpc_id"            { value = aws_vpc.hub.id }
output "network_firewall_arn"  { value = aws_networkfirewall_firewall.main.arn }
