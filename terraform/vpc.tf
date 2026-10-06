resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = var.name }
}

resource "aws_subnet" "public" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.lab.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${var.name}-public-${local.azs[count.index]}" }
}

resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.lab.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${var.name}-private-${local.azs[count.index]}" }
}

resource "aws_vpc_ipv4_cidr_block_association" "pods" {
  count      = var.enable_pod_subnets ? 1 : 0
  vpc_id     = aws_vpc.lab.id
  cidr_block = var.pod_cidr
}

resource "aws_subnet" "pods" {
  count             = var.enable_pod_subnets ? length(local.azs) : 0
  vpc_id            = aws_vpc_ipv4_cidr_block_association.pods[0].vpc_id
  cidr_block        = local.pod_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name                     = "${var.name}-pods-${local.azs[count.index]}"
    "kubernetes.io/role/cni" = "1" # enhanced subnet discovery
  }
}

resource "aws_eip" "nat" {
  count  = length(local.azs)
  domain = "vpc"
  tags   = { Name = "${var.name}-nat-${local.azs[count.index]}" }
}

resource "aws_nat_gateway" "lab" {
  count         = length(local.azs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${var.name}-${local.azs[count.index]}" }

  depends_on = [aws_internet_gateway.lab]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table" "private" {
  count  = length(local.azs)
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.lab[count.index].id
  }

  tags = { Name = "${var.name}-private-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "pods" {
  count          = var.enable_pod_subnets ? length(local.azs) : 0
  subnet_id      = aws_subnet.pods[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
