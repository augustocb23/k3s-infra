resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "k3s-vpc-${var.env}" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "k3s-igw-${var.env}" }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# public subnets

resource "aws_subnet" "public" {
  count = length(data.aws_availability_zones.available.names)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  map_public_ip_on_launch = true

  tags = { Name = "k3s-public-${var.env}-${count.index + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "k3s-public-rt-${var.env}" }
}

resource "aws_route_table_association" "public" {
  count =  length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# private subnets

resource "aws_subnet" "private" {
  count = length(data.aws_availability_zones.available.names)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + count.length)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = { Name = "k3s-private-${var.env}-${count.index + 1}" }
}

# Note: The route to 0.0.0.0/0 via NAT Instance will be injected by the 'core' module
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "k3s-private-rt-${var.env}" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
