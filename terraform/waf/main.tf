# ============================================================
# terraform/waf/main.tf
# AWS WAF v2, Bot Control, Shield Advanced, CloudFront
# ============================================================

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  # WAF for CloudFront must be in us-east-1
  required_version = ">= 1.6"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"   # CloudFront WAF must be us-east-1
}

provider "aws" {
  region = "ap-south-1"   # Regional WAF for ALB
}

# ── Regional WAF (for ALB in ap-south-1) ─────────────────────
resource "aws_wafv2_web_acl" "alb" {
  provider    = aws
  name        = "alb-waf-acl"
  scope       = "REGIONAL"
  description = "WAF ACL for ALB — OWASP, Bot, Rate limiting"

  default_action { allow {} }

  # Rule 1: AWS Managed Core Rule Set
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
        # Exclude body-size rules if microservices have large payloads
        rule_action_override {
          action_to_use { count {} }
          name = "SizeRestrictions_BODY"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: SQL Injection protection
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 2
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SQLiRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Rule 3: Known Bad Inputs
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 3
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "BadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Rule 4: Bot Control (targeted mode)
  rule {
    name     = "AWSManagedRulesBotControlRuleSet"
    priority = 4
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesBotControlRuleSet"
        vendor_name = "AWS"
        managed_rule_group_configs {
          aws_managed_rules_bot_control_rule_set {
            inspection_level = "TARGETED"   # advanced bot detection
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "BotControlRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Rule 5: IP Rate limiting (100 req/5min per IP)
  rule {
    name     = "RateLimitPerIP"
    priority = 5
    action { block {} }
    statement {
      rate_based_statement {
        limit              = 500
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitPerIP"
      sampled_requests_enabled   = true
    }
  }

  # Rule 6: Geo-block if needed (example: restrict to India + US)
  rule {
    name     = "GeoRestriction"
    priority = 6
    action { count {} }   # change to block {} to enforce
    statement {
      not_statement {
        statement {
          geo_match_statement {
            country_codes = ["IN", "US", "GB", "SG", "AU"]
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "GeoRestriction"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "alb-waf-acl"
    sampled_requests_enabled   = true
  }

  tags = { Name = "alb-waf-acl" }
}

# ── Associate WAF with ALB (ALB ARN comes from k8s ingress output) ──
# resource "aws_wafv2_web_acl_association" "alb" {
#   resource_arn = var.alb_arn
#   web_acl_arn  = aws_wafv2_web_acl.alb.arn
# }

# ── WAF Logging to S3 / Firehose ─────────────────────────────
resource "aws_s3_bucket" "waf_logs" {
  bucket = "prod-waf-logs-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "waf-logs" }
}

resource "aws_s3_bucket_lifecycle_configuration" "waf_logs" {
  bucket = aws_s3_bucket.waf_logs.id
  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    expiration { days = 90 }
    filter { prefix = "waf-logs/" }
  }
}

resource "aws_wafv2_web_acl_logging_configuration" "alb" {
  log_destination_configs = [aws_s3_bucket.waf_logs.arn]
  resource_arn            = aws_wafv2_web_acl.alb.arn

  logging_filter {
    default_behavior = "KEEP"
    filter {
      behavior    = "KEEP"
      requirement = "MEETS_ANY"
      condition {
        action_condition { action = "BLOCK" }
      }
    }
  }
}

data "aws_caller_identity" "current" {}

# ── CloudFront WAF (us-east-1) ────────────────────────────────
resource "aws_wafv2_web_acl" "cloudfront" {
  provider    = aws.us_east_1
  name        = "cloudfront-waf-acl"
  scope       = "CLOUDFRONT"
  description = "WAF ACL for CloudFront"

  default_action { allow {} }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CF-CommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "cloudfront-waf-acl"
    sampled_requests_enabled   = true
  }
}

# ── Outputs ───────────────────────────────────────────────────
output "waf_acl_arn"             { value = aws_wafv2_web_acl.alb.arn }
output "waf_acl_id"              { value = aws_wafv2_web_acl.alb.id }
output "cloudfront_waf_acl_arn"  { value = aws_wafv2_web_acl.cloudfront.arn }
output "waf_logs_bucket"         { value = aws_s3_bucket.waf_logs.bucket }
