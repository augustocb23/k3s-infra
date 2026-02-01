# Ubuntu ARM64 AMI (latest LTS)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-*-arm64-server-*"]
  }
}

# roles
data "aws_iam_role" "lab_role" {
  name = "LabRole"
}

data "aws_iam_instance_profile" "lab_profile" {
  name = "LabInstanceProfile"
}

# security group
resource "aws_security_group" "core_sg" {
  name        = "k3s-core-sg-${var.env}"
  description = "Security group for K3s Core and NAT"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "K3s API Server"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "MySQL (VPC only)"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "All traffic within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EBS volume for database
resource "aws_ebs_volume" "db_data" {
  availability_zone = data.terraform_remote_state.shared.outputs.public_subnets_azs[0]

  size = var.database_storage_size
  type = "gp3"

  tags = {
    Name = "k3s-mysql-data-${var.env}"
  }
}

resource "aws_volume_attachment" "db_att" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.db_data.id
  instance_id = aws_instance.k3s_core.id

  force_detach = true
}

# EC2 instance
resource "aws_instance" "k3s_core" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type

  subnet_id              = data.terraform_remote_state.shared.outputs.public_subnets[0]
  enable_primary_ipv6    = true
  vpc_security_group_ids = [aws_security_group.core_sg.id]

  iam_instance_profile = data.aws_iam_instance_profile.lab_profile.name
  key_name             = "vockey"

  user_data = templatefile("${path.module}/user_data.sh", {
    db_password = random_password.db_root_pass.result,
    k3s_token   = random_password.k3s_token.result
  })
  user_data_replace_on_change = true

  source_dest_check = false

  root_block_device {
    volume_size = 15
    volume_type = "gp3"
  }

  tags = {
    Name = "k3s-core-${var.env}"
    Role = "control-plane"
  }
}

# Elastic IP for NAT
resource "aws_eip" "k3s_core_ip" {
  domain   = "vpc"
  instance = aws_instance.k3s_core.id

  tags = {
    Name = "k3s-core-ip-${var.env}"
  }
}

# route injection (NAT instance)
resource "aws_route" "private_nat_gateway" {
  route_table_id = data.terraform_remote_state.shared.outputs.private_route_table_id

  destination_cidr_block = "0.0.0.0/0"

  network_interface_id = aws_instance.k3s_core.primary_network_interface_id
}
