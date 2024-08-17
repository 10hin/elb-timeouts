data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

locals {
  cidr_block_all = "0.0.0.0/0"

  aws_partition = data.aws_partition.current.partition
  aws_region    = data.aws_region.current.name
  # zone名からzone-idを引けるmap
  aws_available_az_name_id_map = {
    for idx, az_name in data.aws_availability_zones.available.names :
    az_name => data.aws_availability_zones.available.zone_ids[idx]
  }
  # zone名を辞書順でソートする
  aws_available_az_names = sort(data.aws_availability_zones.available.names)
  # zone名の順と同じ順序のzone-id
  aws_available_az_ids = [
    for zone_name in local.aws_available_az_names :
    local.aws_available_az_name_id_map[zone_name]
  ]

  vpc_cidr_block        = "10.0.0.0/16"
  subnet_group_count    = 3
  subnet_group_size_max = 3
  subnet_groups = [
    {
      name = "public"
      subnets = [
        for idx in range(2) :
        {
          name_suffix             = "${idx}"
          az_name                 = local.aws_available_az_names[idx]
          map_public_ip_on_launch = true
          tags = {
            Access   = "public"
            ZoneName = local.aws_available_az_names[idx % length(local.aws_available_az_names)]
            ZoneId   = local.aws_available_az_ids[idx % length(local.aws_available_az_ids)]
          }
        }
      ]
    },
    {
      name = "private"
      subnets = [
        for idx in range(2) :
        {
          name_suffix             = "${idx}"
          az_name                 = local.aws_available_az_names[idx]
          map_public_ip_on_launch = false
          tags = {
            Access   = "private"
            ZoneName = local.aws_available_az_names[idx % length(local.aws_available_az_names)]
            ZoneId   = local.aws_available_az_ids[idx % length(local.aws_available_az_ids)]
          }
        }
      ]
    },
  ]
  subnet_layout = flatten([
    for group_idx, subnet_group in local.subnet_groups :
    [
      for subnet_idx, subnet in subnet_group.subnets :
      {
        name       = "${subnet_group.name}${subnet.name_suffix}"
        az_name    = subnet.az_name
        cidr_block = cidrsubnet(local.vpc_cidr_block, ceil(log(local.subnet_group_count * local.subnet_group_size_max, 2)), group_idx * local.subnet_group_count + subnet_idx)
        tags       = subnet.tags
      }
    ]
  ])
}

resource "aws_vpc" "this" {
  cidr_block = local.vpc_cidr_block
}

resource "aws_subnet" "this" {
  for_each = {
    for subnet in local.subnet_layout :
    subnet.name => subnet
  }

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr_block
  availability_zone = each.value.az_name
  tags = merge(each.value.tags, {
    Name = each.key
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
}

resource "aws_eip" "nat_gateway" {
  domain = "vpc"
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat_gateway.id
  subnet_id = [
    for subnet_key, subnet in aws_subnet.this :
    subnet.id
    if subnet.tags["Access"] == "public"
  ][0]
  depends_on = [
    aws_internet_gateway.this,
  ]
}

resource "aws_route_table" "public" {
  for_each = {
    for subnet_key, subnet in aws_subnet.this :
    subnet.tags["Name"] => subnet
    if subnet.tags["Access"] == "public"
  }

  vpc_id = aws_vpc.this.id
}

resource "aws_route" "public_subnet_to_igw" {
  for_each = {
    for subnet_key, subnet in aws_subnet.this :
    subnet.tags["Name"] => subnet
    if subnet.tags["Access"] == "public"
  }

  route_table_id         = aws_route_table.public[each.key].id
  destination_cidr_block = local.cidr_block_all
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = {
    for subnet_key, subnet in aws_subnet.this :
    subnet.tags["Name"] => subnet
    if subnet.tags["Access"] == "public"
  }

  route_table_id = aws_route_table.public[each.key].id
  subnet_id      = aws_subnet.this[each.key].id
}

resource "aws_route_table" "private" {
  for_each = {
    for subnet_key, subnet in aws_subnet.this :
    subnet.tags["Name"] => subnet
    if subnet.tags["Access"] == "private"
  }

  vpc_id = aws_vpc.this.id
}

resource "aws_route" "private_subnet_to_natgw" {
  for_each = {
    for subnet_key, subnet in aws_subnet.this :
    subnet.tags["Name"] => subnet
    if subnet.tags["Access"] == "private"
  }

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = local.cidr_block_all
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  for_each = {
    for subnet_key, subnet in aws_subnet.this :
    subnet.tags["Name"] => subnet
    if subnet.tags["Access"] == "private"
  }

  route_table_id = aws_route_table.private[each.key].id
  subnet_id      = aws_subnet.this[each.key].id
}
