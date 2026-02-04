# Ubuntu AMI (latest LTS)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-*-amd64-server-*"]
  }
}

# launch template
resource "aws_launch_template" "node_lt" {
  name_prefix   = "k3s-node-${var.env}-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t3.small"

  vpc_security_group_ids = [aws_security_group.node_sg.id]

  iam_instance_profile {
    name = "LabInstanceProfile"
  }
  key_name = "vockey"

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    k3s_url   = "https://${data.terraform_remote_state.core.outputs.k3s_server_ip}:6443"
    k3s_token = data.terraform_remote_state.core.outputs.k3s_token
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "k3s-worker-${var.env}"
      Role = "worker"
    }
  }
}

# auto scaling group
resource "aws_autoscaling_group" "node_asg" {
  name             = "k3s-node-asg-${var.env}"
  max_size         = 5
  min_size         = 1

  vpc_zone_identifier = data.terraform_remote_state.shared.outputs.private_subnets

  instance_refresh {
    strategy = "Rolling"
  }

  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.node_lt.id
        version            = aws_launch_template.node_lt.latest_version
      }

      override { instance_type = "t3.small" }
      override { instance_type = "t3a.small" }
      override { instance_type = "t2.small" }
      override { instance_type = "t3.medium" }
      override { instance_type = "t3a.medium" }
      override { instance_type = "t2.medium" }
    }

    instances_distribution {
      spot_allocation_strategy = "price-capacity-optimized"
    }
  }

  tag {
    key   = "k8s.io/cluster-autoscaler/enabled"
    value = "true"

    propagate_at_launch = true
  }
}

# security group for nodes
resource "aws_security_group" "node_sg" {
  name        = "k3s-node-sg-${var.env}"
  description = "Security Group for K3s Workers"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  ingress {
    description = "Allow VPC internal traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.terraform_remote_state.shared.outputs.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "k3s-node-sg-${var.env}" }
}
