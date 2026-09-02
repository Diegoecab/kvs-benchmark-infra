variable "aws_profile" {
  description = "Existing local AWS CLI profile used only by Terraform and the dashboard control plane."
  type        = string
  default     = "default"

  validation {
    condition     = length(trimspace(var.aws_profile)) > 0
    error_message = "aws_profile must not be empty."
  }
}

variable "region" {
  description = "AWS region for the distributed benchmark target."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = var.region == "us-east-1"
    error_message = "This root module is intentionally scoped to us-east-1."
  }
}

variable "availability_zone" {
  description = "Existing availability zone containing the selected subnet."
  type        = string
  default     = "us-east-1a"

  validation {
    condition     = var.availability_zone == "us-east-1a"
    error_message = "The distributed AWS benchmark runners must be placed in us-east-1a."
  }
}

variable "vpc_id" {
  description = "ID of the existing VPC. This module does not create or own the VPC."
  type        = string

  validation {
    condition     = can(regex("^vpc-[a-f0-9]+$", var.vpc_id))
    error_message = "vpc_id must be a valid VPC ID."
  }
}

variable "subnet_id" {
  description = "ID of an existing public subnet in the selected VPC and availability zone."
  type        = string

  validation {
    condition     = can(regex("^subnet-[a-f0-9]+$", var.subnet_id))
    error_message = "subnet_id must be a valid subnet ID."
  }
}

variable "run_id" {
  description = "Lowercase run identifier used to name every resource owned by this root module."
  type        = string
  default     = "kvs-distributed"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{2,36}$", var.run_id))
    error_message = "run_id must be 3-37 lowercase letters, digits, or hyphens and start with a letter or digit."
  }
}

variable "ubuntu_ami_id" {
  description = "Optional pinned Ubuntu 24.04 amd64 AMI. When null, the newest Canonical Ubuntu 24.04 gp3 image is selected."
  type        = string
  default     = null

  validation {
    condition     = var.ubuntu_ami_id == null || can(regex("^ami-[a-f0-9]+$", var.ubuntu_ami_id))
    error_message = "ubuntu_ami_id must be null or a valid AMI ID."
  }
}

variable "runner_image" {
  description = "Immutable benchmark runner image reference pinned by SHA-256 digest."
  type        = string
  default     = "ghcr.io/diegoecab/kvs-benchmark-runner@sha256:6eb0c3d31123dfec7b49cd6c319d0ebc781efe4b397b2a38997be6249577188b"

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.runner_image))
    error_message = "runner_image must be pinned with an @sha256 digest."
  }
}

variable "tags" {
  description = "Additional tags applied to resources owned by this module."
  type        = map(string)
  default     = {}
}
