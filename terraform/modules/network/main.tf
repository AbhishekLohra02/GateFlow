# Availability zones, looked up rather than hardcoded.
#
# AZ names are not stable across accounts - your "us-east-1a" is a different
# physical datacentre from someone else's, and not every AZ offers every
# instance type. Hardcoding a list is also how a config becomes
# region-locked. `state = "available"` filters out zones AWS has marked
# impaired.
data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both are required for private DNS to work inside the VPC. ECS tasks
  # resolving anything by name - ECR endpoints, other AWS services - depend
  # on this. The failure mode when it is off is DNS timeouts that look like
  # a network problem and are not.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

# ---------------------------------------------------------------------------
# Internet gateway: the VPC's door to the public internet.
#
# It is free. The NAT Gateway - which does the same job for PRIVATE subnets -
# is not, at roughly $33/month. That single distinction is why this design
# puts instances in public subnets: an IGW plus a public IP costs nothing,
# a private subnet needs NAT to reach ECR at all.
# ---------------------------------------------------------------------------
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-igw" }
}

# ---------------------------------------------------------------------------
# Public subnets, one per AZ.
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = var.subnet_count

  vpc_id = aws_vpc.this.id

  # cidrsubnet(prefix, newbits, index) carves the VPC range into pieces.
  # With a /16 and newbits = 8 you get /24s: 10.0.0.0/24, 10.0.1.0/24, ...
  # Computing them beats hardcoding, which silently breaks the moment
  # vpc_cidr changes and leaves you debugging overlapping ranges.
  cidr_block = cidrsubnet(var.vpc_cidr, 8, count.index)

  availability_zone = data.aws_availability_zones.available.names[count.index]

  # Give instances launched here a public IP automatically.
  #
  # Without this the ECS agent cannot reach the ECS control plane or pull
  # from ECR, and the instance never joins the cluster. The symptom is a
  # cluster showing zero registered instances with no error anywhere - one
  # of the more frustrating ways to lose an afternoon.
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-public-${data.aws_availability_zones.available.names[count.index]}"
    Tier = "public"
  }
}

# ---------------------------------------------------------------------------
# Routing.
#
# A subnet is only "public" because of its route table, not because of its
# name. What makes it public is the 0.0.0.0/0 route to an internet gateway
# below. A subnet tagged "public" with no such route is a private subnet
# with a misleading tag.
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name_prefix}-public-rt" }
}

# Every subnet is implicitly associated with the VPC's default ("main") route
# table, which has no internet route. This association overrides that.
# Forgetting it is the other classic cause of "my instance has a public IP
# but nothing can reach it".
resource "aws_route_table_association" "public" {
  count = var.subnet_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Security group for the ECS container instances.
#
# Security groups are STATEFUL: a reply to an allowed inbound request is
# automatically permitted, so there is no need to open ephemeral ports for
# return traffic. Network ACLs are the stateless layer and are why people
# who learned on NACLs over-open security groups out of habit.
# ---------------------------------------------------------------------------
resource "aws_security_group" "instance" {
  name        = "${var.name_prefix}-instance-sg"
  description = "Traffic rules for GateFlow ECS container instances"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-instance-sg" }
}

# Rules as separate resources rather than inline blocks.
#
# Inline `ingress`/`egress` blocks are authoritative: Terraform removes any
# rule it did not create, so an emergency rule added in the console vanishes
# on the next apply with no warning in the plan. Separate rule resources
# also give each rule its own address in state, so changing one does not
# churn the others.
resource "aws_vpc_security_group_ingress_rule" "app" {
  security_group_id = aws_security_group.instance.id
  description       = "Application traffic"

  cidr_ipv4   = var.ingress_cidr
  from_port   = var.app_port
  to_port     = var.app_port
  ip_protocol = "tcp"
}

# No SSH rule, deliberately.
#
# Port 22 open to the world is the single most attacked surface on AWS, and
# it is unnecessary: AWS Systems Manager Session Manager gives shell access
# through the SSM agent over an outbound connection, so there is no inbound
# port to attack and no key material to lose. Access is controlled by IAM
# and logged in CloudTrail.

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.instance.id
  description       = "Allow all outbound"

  # Wide open outbound, and this is not laziness. The instance must reach the
  # ECS control plane, pull images from ECR, and ship logs to CloudWatch -
  # all public AWS endpoints with IP ranges that change. Locking egress down
  # properly means VPC endpoints, which cost money per endpoint per hour.
  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}
