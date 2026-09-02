packer {
  required_version = ">= 1.10.0"
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.9"
    }
  }
}

variable "aws_profile" {
  type = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "subnet_id" {
  type = string
}

variable "base_ami_id" {
  type = string
}

variable "runner_image" {
  type = string
}

locals {
  image_version = formatdate("YYYYMMDDhhmmss", timestamp())
  runner_digest = regex("sha256:[0-9a-f]{64}$", var.runner_image)
}

source "amazon-ebs" "runner" {
  profile                     = var.aws_profile
  region                      = var.region
  subnet_id                   = var.subnet_id
  instance_type               = "t3.micro"
  associate_public_ip_address = true
  ssh_username                = "ec2-user"
  ami_name                    = "kvs-benchmark-runner-${local.image_version}"
  ami_description             = "Immutable KVS benchmark runner with agents, time sync, Podman, and pinned workload image"
  imds_support                = "v2.0"
  source_ami                  = var.base_ami_id

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = {
    ManagedBy    = "Packer"
    Project      = "KVS-Benchmark"
    ImageSchema  = "1"
    RunnerDigest = local.runner_digest
  }
}

build {
  name    = "aws-kvs-runner"
  sources = ["source.amazon-ebs.runner"]

  provisioner "shell" {
    script = "${path.root}/scripts/provision-runner.sh"
    environment_vars = [
      "KVS_PROVIDER=aws",
      "KVS_RUNNER_IMAGE=${var.runner_image}"
    ]
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{ .Path }}"
  }

  provisioner "shell" {
    inline = [
      "sudo rm -rf /opt/kvs-dashboard/results/*",
      "sudo rm -f /etc/kvs-benchmark-runner-release",
      "sudo cloud-init clean --logs",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /etc/ssh/ssh_host_*"
    ]
  }

  post-processor "manifest" {
    output     = "${path.root}/manifest-aws.json"
    strip_path = true
    custom_data = {
      provider     = "aws"
      runner_image = var.runner_image
    }
  }
}
