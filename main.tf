# ----------------------------------------------------------------------------------------------------------------------
# REQUIRE A SPECIFIC TERRAFORM VERSION OR HIGHER
# This module has been updated with 0.15.1 syntax, which means it is no longer compatible with any versions below 0.15.1.
# ----------------------------------------------------------------------------------------------------------------------
######################################
# Defaults
######################################
terraform {
  required_version = ">= 1.0.0"
  backend "remote" {}
}

provider "aws" {
  region  = var.region
  profile = "default"
}

resource "random_string" "rand4" {
  length  = 4
  special = false
  upper   = false
}

######################################
# Create VPC
######################################

module "aws-vpc" {
  source                    = "./modules/vpc"
  region                    = var.region
  name                      = "${var.name}-${random_string.rand4.result}"
  cidr                      = var.cidr
  public_subnets            = var.public_subnets
  private_subnets_a         = var.private_subnets_a
  private_subnets_b         = var.private_subnets_b
  tags                      = var.tags
  enable_dns_hostnames      = var.enable_dns_hostnames
  enable_dns_support        = var.enable_dns_support
  instance_tenancy          = var.instance_tenancy
  public_inbound_acl_rules  = var.public_inbound_acl_rules
  public_outbound_acl_rules = var.public_inbound_acl_rules
  custom_inbound_acl_rules  = var.custom_inbound_acl_rules
  custom_outbound_acl_rules = var.custom_outbound_acl_rules
  public_subnet_tags        = tomap(var.public_subnet_tags)
  private_subnet_tags       = tomap(var.private_subnet_tags)
  create_vpc                = var.create_vpc
}