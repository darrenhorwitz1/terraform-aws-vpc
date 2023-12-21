data "aws_availability_zones" "current" {}

resource "aws_ec2_transit_gateway" "example" {
  description = "example"
}

resource "aws_ec2_managed_prefix_list" "example" {
  name           = "All VPC CIDR-s"
  address_family = "IPv4"
  max_entries    = 5

  dynamic "entry" {
    for_each = var.prefixes

    content {
      cidr        = entry.value
      description = entry.key
    }
  }
}

module "vpc" {
  source = "../../"
  # version = ">= 4.2.0"
  providers = {
    aws.network          = aws
    aws.network_cwan_ram = aws
  }
  naming_prefix                        = "tgw"
  cidr_block                           = "10.0.0.0/16"
  vpc_assign_generated_ipv6_cidr_block = true
  az_count                             = 3

  transit_gateway_id = aws_ec2_transit_gateway.example.id
  transit_gateway_routes = {
    public              = "10.0.0.0/8"
    private_with_egress = "192.168.0.0/16"
    private_dualstack   = aws_ec2_managed_prefix_list.example.id
  }
  transit_gateway_ipv6_routes = {
    private_dualstack = "::/0"
  }

  subnets = {
    public = {
      # cidrs = ["10.0.0.0/24", "10.0.1.0/24","10.0.8.0/24"]
      netmask                   = 24
      nat_gateway_configuration = "single_az"
    }
    private_with_egress = {
      netmask                 = 24
      connect_to_public_natgw = true
      # cidrs                   = ["10.0.2.0/24", "10.0.3.0/24"]
      azs = ["eu-west-1a", "eu-west-1c"]
    }
    private_dualstack = {
      netmask = 24
      # cidrs            = ["10.0.4.0/24", "10.0.5.0/24","10.0.7.0/24"]
      assign_ipv6_cidr = true
    }
    transit_gateway = {
      netmask                                         = 28
      assign_ipv6_cidr                                = true
      connect_to_public_natgw                         = true
      transit_gateway_default_route_table_association = true
      transit_gateway_default_route_table_propagation = true
      transit_gateway_appliance_mode_support          = "enable"
      transit_gateway_dns_support                     = "disable"
      # azs                                             = ["eu-west-1a"]
      # cidrs                                           = ["10.0.6.0/24", ]

      tags = {
        subnet_type = "tgw"
      }
    }
  }
}
