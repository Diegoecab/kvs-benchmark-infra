packer {
  required_version = ">= 1.10.0"
  required_plugins {
    oracle = {
      source  = "github.com/hashicorp/oracle"
      version = ">= 1.1.2"
    }
  }
}

variable "oci_config_file" {
  type = string
}

variable "oci_profile" {
  type = string
}

variable "region" {
  type    = string
  default = "us-ashburn-1"
}

variable "availability_domain" {
  type = string
}

variable "compartment_ocid" {
  type = string
}

variable "subnet_ocid" {
  type = string
}

variable "base_image_ocid" {
  type = string
}

variable "runner_image" {
  type = string
}

variable "use_private_ip" {
  type    = bool
  default = false
}

locals {
  image_version = formatdate("YYYYMMDDhhmmss", timestamp())
  runner_digest = regex("sha256:[0-9a-f]{64}$", var.runner_image)
}

source "oracle-oci" "runner" {
  access_cfg_file         = var.oci_config_file
  access_cfg_file_account = var.oci_profile
  region                  = var.region
  availability_domain     = var.availability_domain
  compartment_ocid        = var.compartment_ocid
  subnet_ocid             = var.subnet_ocid
  base_image_ocid         = var.base_image_ocid
  image_name              = "kvs-benchmark-runner-${local.image_version}"
  instance_name           = "kvs-image-builder-${local.image_version}"
  shape                   = "VM.Standard.E5.Flex"
  ssh_username            = "opc"
  use_private_ip          = var.use_private_ip

  shape_config {
    ocpus         = 1
    memory_in_gbs = 2
  }

  create_vnic_details {
    assign_public_ip = !var.use_private_ip
  }

  instance_options_are_legacy_imds_endpoints_disabled = true
  instance_tags = {
    ManagedBy = "Packer"
    Project   = "KVS-Benchmark"
    Purpose   = "Ephemeral image builder"
  }
  tags = {
    ManagedBy    = "Packer"
    Project      = "KVS-Benchmark"
    ImageSchema  = "1"
    RunnerDigest = local.runner_digest
  }
}

build {
  name    = "oci-kvs-runner"
  sources = ["source.oracle-oci.runner"]

  provisioner "shell" {
    script = "${path.root}/scripts/provision-runner.sh"
    environment_vars = [
      "KVS_PROVIDER=oci",
      "KVS_RUNNER_IMAGE=${var.runner_image}"
    ]
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E {{ .Path }}"
  }

  provisioner "shell" {
    inline = [
      "sudo rm -rf /opt/kvs-dashboard/results/*",
      "sudo rm -f /etc/kvs-benchmark-runner-release",
      "sudo cloud-init clean --logs",
      "sudo oci-image-cleanup -f y"
    ]
  }

  post-processor "manifest" {
    output     = "${path.root}/manifest-oci.json"
    strip_path = true
    custom_data = {
      provider     = "oci"
      runner_image = var.runner_image
    }
  }
}
