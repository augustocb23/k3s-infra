data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-*-arm64-server-*"]
  }
}

data "aws_iam_role" "lab_role" {
  name = "LabRole"
}

data "aws_iam_instance_profile" "lab_profile" {
  name = "LabInstanceProfile"
}

resource "aws_instance" "k3s_core" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t4g.micro"

  subnet_id              = data.terraform_remote_state.shared.outputs.public_subnets[0]
  vpc_security_group_ids = [aws_security_group.core_sg.id]

  iam_instance_profile = data.aws_iam_instance_profile.lab_profile.name

  user_data = templatefile("${path.module}/user_data.sh", {
    db_password = random_password.db_root_pass.result
  })
  user_data_replace_on_change = true

  source_dest_check = false

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name = "k3s-core-${var.env}"
    Role = "control-plane"
  }
}

resource "aws_security_group" "core_sg" {
  name        = "k3s-core-sg-${var.env}"
  description = "Security group for K3s Core and NAT"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP/HTTPS (Nginx)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # K3s API (kubectl)
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # MySQL (VPC only)
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # NAT traffic (VPC only)
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
