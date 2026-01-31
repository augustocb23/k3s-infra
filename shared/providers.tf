terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }

    helm = {
      source = "hashicorp/helm"
    }

    random = {
      source = "hashicorp/random"
    }
  }
}

provider "aws" {
  region = var.region
}

provider "helm" {
  kubernetes = {
    host = data.aws_eks_cluster.cluster.endpoint

    cluster_ca_certificate = base64decode(
      data.aws_eks_cluster.cluster.certificate_authority[0].data
    )

    token = data.aws_eks_cluster_auth.cluster.token
  }
}