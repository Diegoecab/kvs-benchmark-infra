terraform {
  required_version = ">= 1.8.0"

  backend "s3" {}

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.32"
    }
  }
}

provider "oci" {
  region              = var.region
  config_file_profile = var.oci_profile
}
