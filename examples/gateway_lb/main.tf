terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.72.0"
    }
  }
}

# Provider definition
provider "aws" {
  region = var.aws_region
}


provider "aws" {
  region = var.cloud_wan_regions.nvirginia
  alias  = "awsnvirginia"
}

# Provider definition for Ireland Region
provider "aws" {
  region = var.cloud_wan_regions.ireland
  alias  = "awsireland"
}


variable "aws_region" {
  description = "AWS Regions to create in Cloud WAN's core network."
  type        = string

  default = "eu-west-1"
}


variable "cloud_wan_regions" {
  description = "AWS Regions to create in Cloud WAN's core network."
  type = object({
    nvirginia = string
    ireland   = string
  })

  default = {
    nvirginia = "us-east-1"
    ireland   = "eu-west-1"
  }
}

variable "prefixes" {
  type        = map(string)
  description = "(optional) describe your variable"

  default = {
    primary  = "10.0.0.0/8",
    internal = "192.168.0.0/16"
  }
}

# resource "aws_ec2_transit_gateway" "example" {
#   description = "example"
# }

resource "aws_networkmanager_global_network" "global_network" {
  provider = aws.awsnvirginia

  description = "Global Network - VPC module"
}

# Core Network
resource "aws_networkmanager_core_network" "core_network" {
  provider = aws.awsnvirginia

  description       = "Core Network - VPC module"
  global_network_id = aws_networkmanager_global_network.global_network.id

  tags = {
    Name = "Core Network - VPC module"
  }
}

# Core Network policy attachment
resource "aws_networkmanager_core_network_policy_attachment" "core_network_policy_attachment" {
  provider = aws.awsnvirginia

  core_network_id = aws_networkmanager_core_network.core_network.id
  policy_document = data.aws_networkmanager_core_network_policy_document.policy.json
}



# module "vpc" {
#   # source  = "aws-ia/vpc/aws"
#   # version = ">= 3.0.2"
#   source = "../.."
#   providers = {
#     aws.network          = aws
#     aws.network_cwan_ram = aws
#   }

#   name                                 = "gateway-lb"
#   cidr_block                           = "10.0.0.0/20"
#   vpc_assign_generated_ipv6_cidr_block = true
#   az_count                             = 3

#   # transit_gateway_id = aws_ec2_transit_gateway.example.id
#   # transit_gateway_routes = {
#   #   public  = "10.0.0.0/8"
#   #   private = "0.0.0.0/0"
#   # }
#   core_network = {
#     id                = aws_networkmanager_core_network.core_network.id
#     arn               = aws_networkmanager_core_network.core_network.arn
#     attachment_subnet = "private"
#     appliance_mode_support = false
#     require_acceptance = true
#     resource_share_arn = ""
#   }

#   subnets = {
#     # public = {
#     #   netmask               = 24
#     #   connect_to_igw        = true
#     #   shared                = true
#     #   associated_principals = ["123456789123", "123456789124"]
#     # }
#     private_db = {
#       netmask = 24
#     }
#     private_app = {
#       netmask = 24
#       shared                = true
#       associated_principals = ["123456789123"]
#     }
#     private_web = {
#       netmask = 24
#       shared                = true
#       associated_principals = ["123456789124","123456789125"]
#     }
#     # gateway_lb = {
#     #   netmask                    = 28
#     #   gwlb_endpoint_service_name = "hello-world"
#     # }

#     # transit_gateway = {
#     #   netmask                                         = 28
#     #   assign_ipv6_cidr                                = false
#     #   connect_to_public_natgw                         = false
#     #   transit_gateway_default_route_table_association = true
#     #   transit_gateway_default_route_table_propagation = true
#     #   transit_gateway_appliance_mode_support          = "enable"
#     #   transit_gateway_dns_support                     = "disable"

#     #   tags = {
#     #     subnet_type = "tgw"
#     #   }
#     # }
#   }
# }
module "inspection_vpc" {
  # source  = "aws-ia/vpc/aws"
  # version = ">= 3.0.2"
  source = "../.."
  providers = {
    aws.network          = aws
    aws.network_cwan_ram = aws
  }

  name       = "inspection-vpc"
  cidr_block = "10.0.0.0/20"
  az_count   = 3

  core_network = {
    id  = aws_networkmanager_core_network.core_network.id
    arn = aws_networkmanager_core_network.core_network.arn
  }

  subnets = {
    public = {
      netmask                   = 26
      connect_to_igw            = true
      nat_gateway_configuration = "all_azs"
    }
    firewall = {
      netmask                 = 26
      connect_to_public_natgw = true
    }
    management = {
      netmask                 = 26
      connect_to_public_natgw = false
    }
    core_network = {
      netmask                = 28
      appliance_mode_support = true
      accept_attachment      = true
      require_acceptance     = true
    }
  }
}

data "aws_networkmanager_core_network_policy_document" "policy" {
  core_network_configuration {
    vpn_ecmp_support = true
    asn_ranges       = ["64515-64520"]

    edge_locations {
      location = var.cloud_wan_regions.nvirginia
      asn      = 64515
    }

    edge_locations {
      location = var.cloud_wan_regions.ireland
      asn      = 64516
    }
  }

  segments {
    name                          = "prod"
    description                   = "Segment for production traffic"
    require_attachment_acceptance = true
  }

  segments {
    name                          = "nonprod"
    description                   = "Segment for non-production traffic"
    require_attachment_acceptance = false
  }

  attachment_policies {
    rule_number     = 100
    condition_logic = "or"

    conditions {
      type     = "tag-value"
      operator = "equals"
      key      = "env"
      value    = "prod"
    }

    action {
      association_method = "constant"
      segment            = "prod"
    }
  }

  attachment_policies {
    rule_number     = 200
    condition_logic = "or"

    conditions {
      type     = "tag-value"
      operator = "equals"
      key      = "env"
      value    = "nonprod"
    }

    action {
      association_method = "constant"
      segment            = "nonprod"
    }
  }
}
