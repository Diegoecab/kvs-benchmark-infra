variable "oci_profile" {
  type    = string
  default = "LATINOAMERICA_APIKEY"
}

variable "tenancy_ocid" {
  type      = string
  sensitive = true
}

variable "compartment_ocid" {
  type      = string
  sensitive = true
}

variable "availability_domain" {
  type = string
}

variable "image_ocid" {
  type      = string
  sensitive = true
}

variable "region" {
  type    = string
  default = "us-dallas-1"
  validation {
    condition     = var.region == "us-dallas-1"
    error_message = "This isolated stack is only for us-dallas-1."
  }
}

variable "run_id" {
  type    = string
  default = "20260901-dallas-1000"
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.run_id))
    error_message = "run_id must contain lowercase letters, digits, and hyphens only."
  }
}

variable "vcn_cidr" {
  type    = string
  default = "10.94.0.0/16"
}

variable "private_subnet_cidr" {
  type    = string
  default = "10.94.1.0/24"
}

variable "shape" {
  type    = string
  default = "VM.Standard.E5.Flex"
}

variable "ocpus" {
  type    = number
  default = 2
}

variable "memory_gbs" {
  type    = number
  default = 16
}

variable "runner_image" {
  type    = string
  default = "ghcr.io/diegoecab/kvs-benchmark-runner@sha256:55ce8eeccce8e8e698ec7b672e491d0e99c28813a2d8ad93ef44ae85330131e0"
}

variable "nosql_table_name" {
  type    = string
  default = "meli_kvs_bm_dallas_1000"
}

variable "nosql_read_units" {
  type    = number
  default = 1000
  validation {
    condition     = var.nosql_read_units > 0 && var.nosql_read_units <= 1000
    error_message = "Dallas benchmark read units must be between 1 and the agreed 1,000 RU ceiling."
  }
}

variable "nosql_write_units" {
  type    = number
  default = 1000
  validation {
    condition     = var.nosql_write_units > 0 && var.nosql_write_units <= 1000
    error_message = "Dallas benchmark write units must be between 1 and the agreed 1,000 WU ceiling."
  }
}
