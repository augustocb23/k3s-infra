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

variable "instance_type" {
  description = "EC2 instance type for the server"
  default     = "t4g.small" 
}

variable "database_storage_size" {
  description = "Storage size for database data"
  default = 10
}