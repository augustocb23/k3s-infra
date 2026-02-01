terraform {
  cloud {
    organization = "augustocb23"

    workspaces {
      project = "k3s-infra"
      name    = "k3s-nodes"
    }
  }

  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "k3s-infra"
      ManagedBy = "Terraform"
    }
  }
}
