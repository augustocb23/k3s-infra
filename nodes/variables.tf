variable "region" {
  description = "AWS Region"
  default     = "us-east-1"
}

variable "env" {
  type        = string
  default     = "dev"
  description = "Name for the environment (dev, stg or prod)"

  validation {
    condition     = contains(["dev", "stg", "prod"], var.env)
    error_message = "Environment must be one of 'dev', 'stg', or 'prod'."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  default     = "10.0.0.0/16"
}
