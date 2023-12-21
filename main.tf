
# ---------- SUBNET CALCULATOR (IPv4 AND IPv6) ----------

module "calculate_subnets" {
  source = "./modules/calculate_subnets"

  cidr = local.cidr_block
  azs  = local.azs

  subnets = var.subnets
}

module "calculate_subnets_ipv6" {
  # count  = local.vpc_ipv6_cidr_block != "" ? 1 : 0
  source = "./modules/calculate_subnets_ipv6"

  cidr_ipv6 = local.vpc_ipv6_cidr_block
  azs       = local.azs

  subnets = var.subnets
}

# ---------- VPC RESOURCE ----------
# flow logs optionally enabled by standalone resource
#tfsec:ignore:aws-ec2-require-vpc-flow-logs-for-all-vpcs
resource "aws_vpc" "main" {
  count = local.create_vpc ? 1 : 0

  cidr_block                       = var.cidr_block
  ipv4_ipam_pool_id                = var.vpc_ipv4_ipam_pool_id
  ipv4_netmask_length              = var.vpc_ipv4_netmask_length
  assign_generated_ipv6_cidr_block = var.vpc_assign_generated_ipv6_cidr_block
  ipv6_cidr_block                  = var.vpc_ipv6_cidr_block
  ipv6_ipam_pool_id                = var.vpc_ipv6_ipam_pool_id
  ipv6_netmask_length              = var.vpc_ipv6_netmask_length

  enable_dns_hostnames = var.vpc_enable_dns_hostnames
  enable_dns_support   = var.vpc_enable_dns_support
  instance_tenancy     = var.vpc_instance_tenancy

  tags = merge(
    { "Name" = "${var.naming_prefix}-vpc-${local.region}" },
    module.tags.tags_aws
  )
}

# ---------- SECONDARY IPv4 CIDR BLOCK (if configured) ----------
resource "aws_vpc_ipv4_cidr_block_association" "secondary" {
  count = (var.vpc_secondary_cidr && !local.create_vpc) ? 1 : 0

  vpc_id            = var.vpc_id
  cidr_block        = local.cidr_block
  ipv4_ipam_pool_id = var.vpc_ipv4_ipam_pool_id
}

# ---------- PUBLIC SUBNET CONFIGURATION ----------
# Public Subnets
resource "aws_subnet" "public" {
  for_each = contains(local.subnet_keys, "public") ? toset(try(var.subnets.public.azs, local.azs)) : toset([])

  availability_zone                              = each.key
  vpc_id                                         = local.vpc.id
  cidr_block                                     = can(local.calculated_subnets["public"][each.key]) ? local.calculated_subnets["public"][each.key] : null
  ipv6_cidr_block                                = can(local.calculated_subnets_ipv6["public"][each.key]) ? local.calculated_subnets_ipv6["public"][each.key] : null
  ipv6_native                                    = contains(local.subnets_with_ipv6_native, "public") ? true : false
  map_public_ip_on_launch                        = local.public_ipv6only ? null : true
  assign_ipv6_address_on_creation                = local.public_ipv6only || local.public_dualstack ? true : null
  enable_resource_name_dns_aaaa_record_on_launch = local.public_ipv6only || local.public_dualstack ? true : false

  tags = merge(
    { Name = "${local.subnet_names["public"]}-${each.key}" },
    module.tags.tags_aws,
    try(module.subnet_tags["public"].tags_aws, {})
  )
}

# Public subnet Route Table and association
resource "aws_route_table" "public" {
  for_each = contains(local.subnet_keys, "public") ? toset(try(var.subnets.public.azs, local.azs)) : toset([])

  vpc_id = local.vpc.id

  tags = merge(
    { Name = "${local.subnet_names["public"]}-${each.key}" },
    module.tags.tags_aws,
    try(module.subnet_tags["public"].tags_aws, {})
  )
}

resource "aws_route_table_association" "public" {
  for_each = contains(local.subnet_keys, "public") ? toset(try(var.subnets.public.azs, local.azs)) : toset([])

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public[each.key].id
}

# Elastic IP - used in NAT gateways (if configured)
resource "aws_eip" "nat" {
  for_each = toset(local.nat_configuration)
  domain   = "vpc"

  tags = merge(
    { Name = "nat-${local.subnet_names["public"]}-${each.key}" },
    module.tags.tags_aws,
    try(module.subnet_tags["public"].tags_aws, {})
  )
}

# NAT gateways (if configured)
resource "aws_nat_gateway" "main" {
  for_each = toset(local.nat_configuration)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = merge(
    { Name = "nat-${local.subnet_names["public"]}-${each.key}" },
    module.tags.tags_aws,
    try(module.subnet_tags["public"].tags_aws, {})
  )

  depends_on = [
    aws_internet_gateway.main
  ]
}

# Internet gateway (if public subnets are created)
resource "aws_internet_gateway" "main" {
  count  = contains(local.subnet_keys, "public") ? 1 : 0
  vpc_id = local.vpc.id

  tags = merge(
    { Name = "${var.naming_prefix}-igw-${local.region}" },
    module.tags.tags_aws,
    try(module.subnet_tags["public"].tags_aws, {})
  )
}

# Egress-only IGW (if indicated)
resource "aws_egress_only_internet_gateway" "eigw" {
  count  = var.vpc_egress_only_internet_gateway ? 1 : 0
  vpc_id = local.vpc.id

  tags = merge(
    { "Name" = "${var.naming_prefix}-eigw-${local.region}" },
    module.tags.tags_aws
  )
}

# Route: 0.0.0.0/0 from public subnets to the Internet gateway
resource "aws_route" "public_to_igw" {
  for_each = contains(local.subnet_keys, "public") && !local.public_ipv6only && local.connect_to_igw ? local.public_to_igw : {}

  route_table_id         = aws_route_table.public[each.value.az].id
  destination_cidr_block = each.value.route
  gateway_id             = aws_internet_gateway.main[0].id
}
# resource "aws_route" "selected_public_to_igw" {
#   for_each = contains(local.subnet_keys, "public") && !local.public_ipv6only && !local.connect_to_igw ? toset(local.azs) : toset([])

#   route_table_id         = aws_route_table.public[each.key].id
#   destination_cidr_block = "0.0.0.0/0"
#   gateway_id             = aws_internet_gateway.main[0].id
# }

# Route: ::/0 from public subnets to the Internet gateway
resource "aws_route" "public_ipv6_to_igw" {
  for_each = contains(local.subnet_keys, "public") && (local.public_ipv6only || local.public_dualstack) && local.connect_to_igw ? toset(try(var.subnets.public.azs, local.azs)) : toset([])

  route_table_id              = aws_route_table.public[each.key].id
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = aws_internet_gateway.main[0].id
}

# Route: IPv4 routes from public subnets to the Transit Gateway (if configured in var.transit_gateway_routes)
resource "aws_route" "public_to_tgw" {
  for_each = (contains(local.subnet_keys, "public") && contains(local.subnets_tgw_routed, "public")) ? toset(try(var.subnets.public.azs, local.azs)) : toset([])

  destination_cidr_block     = can(regex("^pl-", var.transit_gateway_routes["public"])) ? null : var.transit_gateway_routes["public"]
  destination_prefix_list_id = can(regex("^pl-", var.transit_gateway_routes["public"])) ? var.transit_gateway_routes["public"] : null

  transit_gateway_id = var.transit_gateway_id
  route_table_id     = aws_route_table.public[each.key].id

  depends_on = [
    aws_ec2_transit_gateway_vpc_attachment.tgw
  ]
}

# Route: IPv6 routes from public subnets to the Transit Gateway (if configured in var.transit_gateway_ipv6_routes)
resource "aws_route" "ipv6_public_to_tgw" {
  for_each = (contains(local.subnet_keys, "public") && contains(local.ipv6_subnets_tgw_routed, "public")) ? toset(try(var.subnets.public.azs, local.azs)) : toset([])

  destination_ipv6_cidr_block = can(regex("^pl-", var.transit_gateway_ipv6_routes["public"])) ? null : var.transit_gateway_ipv6_routes["public"]
  destination_prefix_list_id  = can(regex("^pl-", var.transit_gateway_ipv6_routes["public"])) ? var.transit_gateway_ipv6_routes["public"] : null

  transit_gateway_id = var.transit_gateway_id
  route_table_id     = aws_route_table.public[each.key].id

  depends_on = [
    aws_ec2_transit_gateway_vpc_attachment.tgw
  ]
}

# Route: IPv4 routes from public subnets to AWS Cloud WAN's core network (if configured in var.core_network_routes)
resource "aws_route" "public_to_cwan" {
  for_each = (contains(local.subnet_keys, "public") && contains(local.subnets_cwan_routed, "public") && local.create_cwan_routes) ? toset(try(var.subnets.public.azs, local.azs)) : toset([])

  destination_cidr_block     = can(regex("^pl-", var.core_network_routes["public"])) ? null : var.core_network_routes["public"]
  destination_prefix_list_id = can(regex("^pl-", var.core_network_routes["public"])) ? var.core_network_routes["public"] : null

  core_network_arn = var.core_network.arn
  route_table_id   = aws_route_table.public[each.key].id

  depends_on = [
    aws_networkmanager_vpc_attachment.cwan,
    aws_networkmanager_attachment_accepter.cwan
  ]
}

# Route: IPv6 routes from public subnets to AWS Cloud WAN's core network (if configured in var.core_network_routes)
resource "aws_route" "ipv6_public_to_cwan" {
  for_each = (contains(local.subnet_keys, "public") && contains(local.ipv6_subnets_cwan_routed, "public") && local.create_cwan_routes) ? toset(try(var.subnets.public.azs, local.azs)) : toset([])

  destination_ipv6_cidr_block = can(regex("^pl-", var.core_network_ipv6_routes["public"])) ? null : var.core_network_ipv6_routes["public"]
  destination_prefix_list_id  = can(regex("^pl-", var.core_network_ipv6_routes["public"])) ? var.core_network_ipv6_routes["public"] : null

  core_network_arn = var.core_network.arn
  route_table_id   = aws_route_table.public[each.key].id

  depends_on = [
    aws_networkmanager_vpc_attachment.cwan,
    aws_networkmanager_attachment_accepter.cwan
  ]
}

# ---------- PRIVATE SUBNETS CONFIGURATION ----------
# Private Subnets
resource "aws_subnet" "private" {
  for_each = toset(try(local.private_per_az, []))

  availability_zone                              = split("/", each.key)[1]
  vpc_id                                         = local.vpc.id
  cidr_block                                     = can(local.calculated_subnets[split("/", each.key)[0]][split("/", each.key)[1]]) ? local.calculated_subnets[split("/", each.key)[0]][split("/", each.key)[1]] : null
  ipv6_cidr_block                                = can(local.calculated_subnets_ipv6[split("/", each.key)[0]][split("/", each.key)[1]]) ? local.calculated_subnets_ipv6[split("/", each.key)[0]][split("/", each.key)[1]] : null
  ipv6_native                                    = contains(local.subnets_with_ipv6_native, split("/", each.key)[0]) ? true : false
  map_public_ip_on_launch                        = contains(local.subnets_with_ipv6_native, split("/", each.key)[0]) ? null : false
  assign_ipv6_address_on_creation                = contains(local.subnets_with_ipv6_native, split("/", each.key)[0]) ? true : try(var.subnets[each.key].assign_ipv6_address_on_creation, false)
  enable_resource_name_dns_aaaa_record_on_launch = contains(local.subnets_with_ipv6_native, split("/", each.key)[0]) ? true : try(var.subnets[each.key].enable_resource_name_dns_aaaa_record_on_launch, false)

  tags = merge(
    { Name = "${local.subnet_names[split("/", each.key)[0]]}-${split("/", each.key)[1]}" },
    module.tags.tags_aws,
    try(module.subnet_tags[split("/", each.key)[0]].tags_aws, {})
  )

  depends_on = [
    aws_vpc_ipv4_cidr_block_association.secondary
  ]
}

# Private subnet Route Table and association
resource "aws_route_table" "private" {
  for_each = toset(try(local.private_per_az, []))

  vpc_id = local.vpc.id

  tags = merge(
    { Name = "${local.subnet_names[split("/", each.key)[0]]}-${split("/", each.key)[1]}" },
    module.tags.tags_aws,
    try(module.subnet_tags[split("/", each.key)[0]].tags_aws, {})
  )
}

resource "aws_route_table_association" "private" {
  for_each = toset(try(local.private_per_az, []))

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

# Route: from the private subnet to the NAT gateway (if Internet access configured)
resource "aws_route" "private_to_nat" {
  for_each = toset(try(local.private_subnet_names_nat_routed, []))

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  # try to get nat for AZ, else use singular nat
  nat_gateway_id = local.nat_per_az[split("/", each.key)[1]].id
}

# Route: from the private subnet to the Egress-only IGW (if configured)
resource "aws_route" "private_to_egress_only" {
  for_each = toset(try(local.private_subnet_names_egress_routed, []))

  route_table_id              = aws_route_table.private[each.key].id
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = aws_egress_only_internet_gateway.eigw[0].id
}

# Route: IPv4 routes from private subnets to the Transit Gateway (if configured in var.transit_gateway_routes)
resource "aws_route" "private_to_tgw" {
  for_each = toset(local.private_subnet_key_names_tgw_routed)

  destination_cidr_block     = can(regex("^pl-", var.transit_gateway_routes[split("/", each.key)[0]])) ? null : var.transit_gateway_routes[split("/", each.key)[0]]
  destination_prefix_list_id = can(regex("^pl-", var.transit_gateway_routes[split("/", each.key)[0]])) ? var.transit_gateway_routes[split("/", each.key)[0]] : null

  route_table_id     = aws_route_table.private[each.key].id
  transit_gateway_id = var.transit_gateway_id

  depends_on = [
    aws_ec2_transit_gateway_vpc_attachment.tgw
  ]
}

# Route: IPv6 routes from private subnets to the Transit Gateway (if configured in var.transit_gateway_ipv6_routes)
resource "aws_route" "ipv6_private_to_tgw" {
  for_each = toset(local.ipv6_private_subnet_key_names_tgw_routed)

  destination_ipv6_cidr_block = can(regex("^pl-", var.transit_gateway_ipv6_routes[split("/", each.key)[0]])) ? null : var.transit_gateway_ipv6_routes[split("/", each.key)[0]]
  destination_prefix_list_id  = can(regex("^pl-", var.transit_gateway_ipv6_routes[split("/", each.key)[0]])) ? var.transit_gateway_ipv6_routes[split("/", each.key)[0]] : null

  route_table_id     = aws_route_table.private[each.key].id
  transit_gateway_id = var.transit_gateway_id

  depends_on = [
    aws_ec2_transit_gateway_vpc_attachment.tgw
  ]
}

# Route: IPv4 routes from private subnets to AWS Cloud WAN's core network (if configured in var.core_network_routes)
resource "aws_route" "private_to_cwan" {
  for_each = {
    for k, v in toset(local.private_subnet_key_names_cwan_routes) : k => v
    if local.create_cwan_routes
  }

  destination_cidr_block     = can(regex("^pl-", var.core_network_routes[split("/", each.key)[0]])) ? null : var.core_network_routes[split("/", each.key)[0]]
  destination_prefix_list_id = can(regex("^pl-", var.core_network_routes[split("/", each.key)[0]])) ? var.core_network_routes[split("/", each.key)[0]] : null

  core_network_arn = var.core_network.arn
  route_table_id   = aws_route_table.private[each.key].id

  depends_on = [
    aws_networkmanager_vpc_attachment.cwan,
    aws_networkmanager_attachment_accepter.cwan
  ]
}

# Route: IPv6 routes from private subnets to AWS Cloud WAN's core network (if configured in var.core_network_routes)
resource "aws_route" "ipv6_private_to_cwan" {
  for_each = {
    for k, v in toset(local.ipv6_private_subnet_keys_names_cwan_routes) : k => v
    if local.create_cwan_routes
  }

  destination_ipv6_cidr_block = can(regex("^pl-", var.core_network_ipv6_routes[split("/", each.key)[0]])) ? null : var.core_network_ipv6_routes[split("/", each.key)[0]]
  destination_prefix_list_id  = can(regex("^pl-", var.core_network_ipv6_routes[split("/", each.key)[0]])) ? var.core_network_ipv6_routes[split("/", each.key)[0]] : null

  core_network_arn = var.core_network.arn
  route_table_id   = aws_route_table.private[each.key].id

  depends_on = [
    aws_networkmanager_vpc_attachment.cwan,
    aws_networkmanager_attachment_accepter.cwan
  ]
}

# ---------- TRANSIT GATEWAY SUBNET CONFIGURATION ----------
# Transit Gateway Subnets
resource "aws_subnet" "tgw" {
  for_each = contains(local.subnet_keys, "transit_gateway") ? toset(try(var.subnets.transit_gateway.azs, local.azs)) : toset([])

  availability_zone = each.key
  vpc_id            = local.vpc.id
  cidr_block        = local.calculated_subnets["transit_gateway"][each.key]
  ipv6_cidr_block   = can(local.calculated_subnets_ipv6["transit_gateway"][each.key]) ? local.calculated_subnets_ipv6["transit_gateway"][each.key] : null

  tags = merge(
    { Name = "${local.subnet_names["transit_gateway"]}-${each.key}" },
    module.tags.tags_aws,
    try(module.subnet_tags["transit_gateway"].tags_aws, {})
  )

}

# Transit Gateway subnet Route Table and association
resource "aws_route_table" "tgw" {
  for_each = contains(local.subnet_keys, "transit_gateway") ? toset(try(var.subnets.transit_gateway.azs, local.azs)) : toset([])

  vpc_id = local.vpc.id

  tags = merge(
    { Name = "${local.subnet_names["transit_gateway"]}-${each.key}" },
    module.tags.tags_aws,
    try(module.subnet_tags["transit_gateway"].tags_aws, {})
  )
}

resource "aws_route_table_association" "tgw" {
  for_each = contains(local.subnet_keys, "transit_gateway") ? toset(try(var.subnets.transit_gateway.azs, local.azs)) : toset([])

  subnet_id      = aws_subnet.tgw[each.key].id
  route_table_id = aws_route_table.tgw[each.key].id
}

# Route: from transit_gateway subnet to NAT gateway (if Internet access configured)
resource "aws_route" "tgw_to_nat" {
  for_each = (try(var.subnets.transit_gateway.connect_to_public_natgw == true, false) && contains(local.subnet_keys, "public")) ? toset(try(var.subnets.transit_gateway.azs, local.azs)) : toset([])

  route_table_id         = aws_route_table.tgw[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  # try to get nat for AZ, else use singular nat
  nat_gateway_id = local.nat_per_az[each.key].id
}

# Transit Gateway VPC attachment
resource "aws_ec2_transit_gateway_vpc_attachment" "tgw" {
  count = contains(local.subnet_keys, "transit_gateway") ? 1 : 0

  subnet_ids         = values(aws_subnet.tgw)[*].id
  transit_gateway_id = var.transit_gateway_id
  vpc_id             = local.vpc.id

  transit_gateway_default_route_table_association = try(var.subnets.transit_gateway.transit_gateway_default_route_table_association, null)
  transit_gateway_default_route_table_propagation = try(var.subnets.transit_gateway.transit_gateway_default_route_table_propagation, null)
  appliance_mode_support                          = try(var.subnets.transit_gateway.transit_gateway_appliance_mode_support, "disable")
  dns_support                                     = try(var.subnets.transit_gateway.transit_gateway_dns_support, "enable")
  ipv6_support                                    = local.tgw_dualstack ? "enable" : "disable"

  tags = merge(
    {
      Name      = "${var.naming_prefix}-tgw-vpc-attach-${data.aws_caller_identity.this.id}-${local.region}"
      AccountId = data.aws_caller_identity.this.id
    },
    module.tags.tags_aws,
    try(module.subnet_tags["transit_gateway"].tags_aws, {})

  )
  lifecycle {
    ignore_changes = [
      transit_gateway_default_route_table_association,
      transit_gateway_default_route_table_propagation
    ]
  }

}

resource "aws_ec2_transit_gateway_vpc_attachment_accepter" "tgw" {
  count    = contains(local.subnet_keys, "transit_gateway") && var.transit_gateway_resource_share_arn != null ? 1 : 0
  provider = aws.network

  transit_gateway_attachment_id = aws_ec2_transit_gateway_vpc_attachment.tgw[0].id

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false



  tags = merge(
    {
      Name      = "${var.naming_prefix}-tgw-vpc-attach-${data.aws_caller_identity.this.id}-${local.region}"
      AccountId = data.aws_caller_identity.this.id
    },
    module.tags.tags_aws,
    try(module.subnet_tags["transit_gateway"].tags_aws, {})

  )
  lifecycle {
    ignore_changes = [
      transit_gateway_default_route_table_association,
      transit_gateway_default_route_table_propagation
    ]
  }
}

resource "aws_ram_principal_association" "tgw" {
  count    = contains(local.subnet_keys, "transit_gateway") && var.transit_gateway_resource_share_arn != null ? 1 : 0
  provider = aws.network

  principal          = data.aws_caller_identity.this.account_id
  resource_share_arn = var.transit_gateway_resource_share_arn

  lifecycle {
    ignore_changes = [
      principal
    ]
  }
}

resource "aws_ec2_transit_gateway_route_table" "tgw" {
  count              = contains(local.subnet_keys, "transit_gateway") ? 1 : 0
  provider           = aws.network
  transit_gateway_id = var.transit_gateway_id
  tags = merge(
    {
      Name      = "${var.naming_prefix}-tgw-vpc-rtb-${data.aws_caller_identity.this.id}-${local.region}"
      AccountId = data.aws_caller_identity.this.id
    },
    try(module.subnet_tags["transit_gateway"].tags_aws, {})
    ,
    module.tags.tags_aws
  )
}

resource "aws_ec2_transit_gateway_route_table_association" "tgw" {
  count                          = contains(local.subnet_keys, "transit_gateway") ? 1 : 0
  provider                       = aws.network
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.tgw[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.tgw[0].id

  depends_on = [
    aws_ec2_transit_gateway_vpc_attachment_accepter.tgw
  ]
}

# ---------- CORE NETWORK SUBNET CONFIGURATION ----------
# Core Network Subnets
resource "aws_subnet" "cwan" {
  for_each = contains(local.subnet_keys, "core_network") ? toset(try(var.subnets.core_network.azs, local.azs)) : toset([])

  availability_zone = each.key
  vpc_id            = local.vpc.id
  cidr_block        = local.calculated_subnets["core_network"][each.key]
  ipv6_cidr_block   = can(local.calculated_subnets_ipv6["core_network"][each.key]) ? local.calculated_subnets_ipv6["core_network"][each.key] : null

  tags = merge(
    { Name = "${local.subnet_names["core_network"]}-${each.key}" },
    module.tags.tags_aws,
    try(module.subnet_tags["core_network"].tags_aws, {})
  )
}

# Core Network subnet Route Table and association
resource "aws_route_table" "cwan" {
  for_each = contains(local.subnet_keys, "core_network") ? toset(try(var.subnets.core_network.azs, local.azs)) : toset([])

  vpc_id = local.vpc.id

  tags = merge(
    { Name = "${local.subnet_names["core_network"]}-${each.key}" },
    module.tags.tags_aws,
    try(module.subnet_tags["core_network"].tags_aws, {})
  )
}

resource "aws_route_table_association" "cwan" {
  for_each = contains(local.subnet_keys, "core_network") ? toset(try(var.subnets.core_network.azs, local.azs)) : toset([])

  subnet_id      = aws_subnet.cwan[each.key].id
  route_table_id = aws_route_table.cwan[each.key].id
}

# Route: from core_network subnet to NAT gateway (if Internet access configured)
resource "aws_route" "cwan_to_nat" {
  for_each = (try(var.subnets.core_network.connect_to_public_natgw == true, false) && contains(local.subnet_keys, "public")) ? toset(local.azs) : toset([])

  route_table_id         = aws_route_table.cwan[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  # try to get nat for AZ, else use singular nat
  nat_gateway_id = local.nat_per_az[each.key].id
}

# AWS Cloud WAN's Core Network VPC attachment
resource "aws_networkmanager_vpc_attachment" "cwan" {
  count = contains(local.subnet_keys, "core_network") || try(var.core_network.attachment_subnet != null, false) ? 1 : 0

  core_network_id = var.core_network.id
  subnet_arns     = contains(local.subnet_keys, "core_network") ? values(aws_subnet.cwan)[*].arn : local.core_network_attachment_subnet_ids
  vpc_arn         = local.vpc.arn

  options {
    ipv6_support           = local.cwan_dualstack ? true : false
    appliance_mode_support = try((contains(local.subnet_keys, "core_network") ? var.subnets.core_network.appliance_mode_support : var.core_network.appliance_mode_support), false)
  }

  tags = merge(
    { Name = "${var.naming_prefix}-cwan-vpc-attach-${data.aws_caller_identity.this.id}-${local.region}" },
    module.tags.tags_aws,
    local.core_network_tags
  )
}

# Core Network's attachment acceptance (if required)
resource "aws_networkmanager_attachment_accepter" "cwan" {
  count           = (contains(local.subnet_keys, "core_network") || try(var.core_network.attachment_subnet != null, false)) && local.create_acceptance ? 1 : 0
  provider        = aws.network
  attachment_id   = aws_networkmanager_vpc_attachment.cwan[0].id
  attachment_type = "VPC"
}
resource "aws_ram_principal_association" "cwan" {
  count    = try(var.core_network.resource_share_arn != null, false) ? 1 : 0
  provider = aws.network_cwan_ram

  principal          = data.aws_caller_identity.this.account_id
  resource_share_arn = var.core_network.resource_share_arn
}

# AWS Gateway LoadBalancer Endpoint subnet
resource "aws_subnet" "gwlb" {
  for_each = contains(local.subnet_keys, "gateway_lb") ? toset(try(var.subnets.gateway_lb.azs, local.azs)) : toset([])

  availability_zone = each.key
  vpc_id            = local.vpc.id
  cidr_block        = local.calculated_subnets["gateway_lb"][each.key]
  ipv6_cidr_block   = can(local.calculated_subnets_ipv6["gateway_lb"][each.key]) ? local.calculated_subnets_ipv6["gateway_lb"][each.key] : null

  tags = merge(
    { Name = "${local.subnet_names["gateway_lb"]}-${each.key}" },
    module.tags.tags_aws,
    try(module.subnet_tags["gateway_lb"].tags_aws, {})
  )
}

resource "aws_route_table" "gwlb" {
  for_each = contains(local.subnet_keys, "gateway_lb") ? toset(try(var.subnets.gateway_lb.azs, local.azs)) : toset([])

  vpc_id = local.vpc.id

  tags = merge(
    { Name = "${local.subnet_names["gateway_lb"]}-${each.key}" },
    module.tags.tags_aws,
    try(module.subnet_tags["gateway_lb"].tags_aws, {})
  )
}

resource "aws_route_table_association" "gwlb" {
  for_each = contains(local.subnet_keys, "gateway_lb") ? toset(try(var.subnets.gateway_lb.azs, local.azs)) : toset([])

  subnet_id      = aws_subnet.gwlb[each.key].id
  route_table_id = aws_route_table.gwlb[each.key].id
}

resource "aws_route" "gwlb_to_igw" {
  for_each = (contains(local.subnet_keys, "gateway_lb") && contains(local.subnet_keys, "public") && !local.connect_to_igw) ? toset(try(var.subnets.gateway_lb.azs, local.azs)) : toset([])

  route_table_id         = aws_route_table.gwlb[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main[0].id
}
# resource "aws_route" "gwlb_to_igw" {
#   for_each = (contains(local.subnet_keys, "gateway_lb") && contains(local.subnet_keys, "public") && !local.connect_to_igw) ? toset(local.azs) : toset([])

#   route_table_id         = aws_route_table.gwlb[each.key].id
#   destination_cidr_block = "0.0.0.0/0"
#   gateway_id             = aws_internet_gateway.main[0].id
# }


resource "aws_vpc_endpoint_service_allowed_principal" "allow_this" {
  count                   = (contains(local.subnet_keys, "gateway_lb") && contains(local.subnet_keys, "public") && !local.connect_to_igw) ? 1 : 0
  provider                = aws.network
  vpc_endpoint_service_id = data.aws_vpc_endpoint_service.endpoint_service[0].service_id
  principal_arn           = "arn:aws:iam::${data.aws_caller_identity.this.account_id}:root"
}

resource "aws_vpc_endpoint_connection_accepter" "this" {
  for_each                = (contains(local.subnet_keys, "gateway_lb") && contains(local.subnet_keys, "public") && !local.connect_to_igw) ? toset(try(var.subnets.gateway_lb.azs, local.azs)) : toset([])
  provider                = aws.network
  vpc_endpoint_service_id = data.aws_vpc_endpoint_service.endpoint_service[0].service_id
  vpc_endpoint_id         = aws_vpc_endpoint.gwlb_endpoint[each.key].id
}

resource "aws_vpc_endpoint" "gwlb_endpoint" {
  for_each          = (contains(local.subnet_keys, "gateway_lb") && contains(local.subnet_keys, "public") && !local.connect_to_igw) ? toset(try(var.subnets.gateway_lb.azs, local.azs)) : toset([])
  service_name      = local.gwlb_endpoint_service_name
  subnet_ids        = [aws_subnet.gwlb[each.key].id]
  vpc_endpoint_type = "GatewayLoadBalancer"
  vpc_id            = local.vpc.id
}
resource "aws_route" "public_to_gwlb" {
  for_each = (contains(local.subnet_keys, "gateway_lb") && contains(local.subnet_keys, "public") && !local.connect_to_igw) ? toset(try(var.subnets.gateway_lb.azs, local.azs)) : toset([])

  route_table_id         = aws_route_table.public[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = aws_vpc_endpoint.gwlb_endpoint[each.key].id
}



resource "aws_route_table" "ingress" {
  count  = (contains(local.subnet_keys, "gateway_lb") && contains(local.subnet_keys, "public") && !local.connect_to_igw) ? 1 : 0
  vpc_id = local.vpc.id

  tags = merge(
    var.tags,
    {
      Name             = "ingress-rtb",
      "AssociatedEdge" = "igw"
    }
  )
}
resource "aws_route_table_association" "ingress" {
  count          = (contains(local.subnet_keys, "gateway_lb") && contains(local.subnet_keys, "public") && !local.connect_to_igw) ? 1 : 0
  route_table_id = aws_route_table.ingress[0].id
  gateway_id     = aws_internet_gateway.main[0].id
}

resource "aws_route" "ingress_to_gwlb_endpoint" {
  for_each               = (contains(local.subnet_keys, "gateway_lb") && contains(local.subnet_keys, "public") && !local.connect_to_igw) ? toset(try(var.subnets.gateway_lb.azs, local.azs)) : toset([])
  route_table_id         = aws_route_table.ingress[0].id
  destination_cidr_block = local.calculated_subnets["public"][each.key]
  vpc_endpoint_id        = aws_vpc_endpoint.gwlb_endpoint[each.key].id
}


# RAM share for shared subnets

#public subnet
resource "aws_ram_resource_share" "public" {
  count                     = (contains(local.subnet_keys, "public") && local.public_shared) ? 1 : 0
  name                      = "public-shared-subnets"
  allow_external_principals = false

  tags = {}
}

resource "aws_ram_resource_association" "public" {
  for_each           = (contains(local.subnet_keys, "public") && local.public_shared) ? toset(try(var.subnets.gateway_lb.azs, local.azs)) : toset([])
  resource_arn       = aws_subnet.public[each.key].arn
  resource_share_arn = aws_ram_resource_share.public[0].arn
}
resource "aws_ram_principal_association" "public" {
  for_each           = (contains(local.subnet_keys, "public") && local.public_shared) ? toset(try(var.subnets.public.associated_principals, [])) : toset([])
  principal          = each.key
  resource_share_arn = aws_ram_resource_share.public[0].arn
}


resource "aws_ram_resource_share" "private" {
  for_each                  = toset(try(local.private_subnets_shared, []))
  name                      = "${each.key}-shared-subnets"
  allow_external_principals = false

  tags = {}
}

resource "aws_ram_resource_association" "private" {
  for_each           = local.private_subnets_shared_per_az
  resource_arn       = aws_subnet.private[each.key].arn
  resource_share_arn = aws_ram_resource_share.private[each.value].arn
}
resource "aws_ram_principal_association" "private" {
  for_each           = try(local.private_subnets_shared_associations, toset([]))
  principal          = each.value.principal
  resource_share_arn = aws_ram_resource_share.private[each.value.subnet].arn
}


# FLOW LOGS
# module "flow_logs" {
#   count = local.create_flow_logs ? 1 : 0

#   source = "./modules/flow_logs"

#   name                = "${var.naming_prefix}-vpc-flow-logs-${local.region}"
#   flow_log_definition = var.vpc_flow_logs
#   vpc_id              = local.vpc.id

#   tags = module.tags.tags_aws
# }
# module "flow_logs" {
#   count           = local.create_flow_logs ? 1 : 0
#   source          = "../../aws-landing-zone-modules/terraform-aws-vpc-flow-logs"
#   destination_arn = var.vpc_flow_log_destination_arn
#   naming_prefixes = var.naming_prefixes
#   vpc_id          = local.vpc.id
#   region          = local.region

#   log_retention = 7

#   tags = module.tags.tags_aws
# }

# Importing default Sec Grp to manage.
# Not setting the rules will set all rules to blank 

resource "aws_default_security_group" "default" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = local.vpc.id
}
