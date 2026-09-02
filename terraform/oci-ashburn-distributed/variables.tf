variable "oci_profile" {
  description = "OCI CLI profile used by Terraform."
  type        = string
}

variable "region" {
  description = "OCI region for the isolated distributed benchmark stack."
  type        = string
  default     = "us-ashburn-1"

  validation {
    condition     = var.region == "us-ashburn-1"
    error_message = "This root module is intentionally scoped to us-ashburn-1."
  }
}

variable "tenancy_ocid" {
  description = "Tenancy OCID. Used for the Object Storage namespace and optional IAM resources."
  type        = string
  sensitive   = true
}

variable "compartment_ocid" {
  description = "Compartment that will own all regional benchmark resources."
  type        = string
  sensitive   = true
}

variable "availability_domain" {
  description = "Availability domain in us-ashburn-1 for all six runners."
  type        = string
}

variable "instance_image_ocid" {
  description = "Oracle Linux image OCID in us-ashburn-1 compatible with VM.Standard.E5.Flex."
  type        = string
  sensitive   = true
}

variable "run_id" {
  description = "Unique lowercase identifier used to isolate this deployment."
  type        = string
  default     = "ashburn-distributed-01"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{2,31}$", var.run_id))
    error_message = "run_id must be 3-32 lowercase letters, digits, or hyphens and start with a letter or digit."
  }
}

variable "vcn_cidr" {
  description = "CIDR for the dedicated benchmark VCN."
  type        = string
  default     = "10.96.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public runner subnet."
  type        = string
  default     = "10.96.1.0/24"
}

variable "runner_image" {
  description = "Immutable OCI benchmark container image reference, pinned by SHA-256 digest."
  type        = string
  default     = "ghcr.io/diegoecab/kvs-benchmark-runner@sha256:6eb0c3d31123dfec7b49cd6c319d0ebc781efe4b397b2a38997be6249577188b"

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.runner_image))
    error_message = "runner_image must be pinned to an immutable sha256 digest."
  }
}

variable "nosql_table_name" {
  description = "Fresh OCI NoSQL table name. Null derives a unique name from run_id."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.nosql_table_name == null || can(regex("^[A-Za-z][A-Za-z0-9_]{0,255}$", var.nosql_table_name))
    error_message = "nosql_table_name must begin with a letter and contain only letters, digits, and underscores."
  }
}

variable "adb_api_table_name" {
  description = "Name reserved for the fresh DynamoDB API table created through the post-apply bootstrap from an OCI runner."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.adb_api_table_name == null || can(regex("^[A-Za-z][A-Za-z0-9_.-]{0,254}$", var.adb_api_table_name))
    error_message = "adb_api_table_name must begin with a letter and contain only letters, digits, underscores, periods, and hyphens."
  }
}

variable "adb_db_name" {
  description = "Fresh Autonomous AI Database name. Null derives a name from run_id."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.adb_db_name == null || can(regex("^[A-Za-z][A-Za-z0-9]{0,29}$", var.adb_db_name))
    error_message = "adb_db_name must start with a letter, be at most 30 characters, and be alphanumeric."
  }
}

variable "adb_admin_password" {
  description = "ADMIN password for the new ADB. Sensitive output masking does not keep it out of Terraform state."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.adb_admin_password) >= 12
    error_message = "adb_admin_password must contain at least 12 characters and satisfy the current ADB password policy."
  }
}

variable "create_tenancy_iam_resources" {
  description = "Explicit opt-in to create a dedicated tenancy dynamic group and policy. False reuses pre-existing IAM."
  type        = bool
  default     = false
}

variable "existing_dynamic_group_name" {
  description = "Existing dynamic group that matches all six runner OCIDs when IAM creation is disabled."
  type        = string
  default     = null
  nullable    = true
}

variable "existing_policy_name" {
  description = "Informational name of the existing policy granting Run Command, bucket/object, and NoSQL row access."
  type        = string
  default     = null
  nullable    = true
}

variable "identity_domain_name" {
  description = "Identity domain containing the optional dynamic group."
  type        = string
  default     = "Default"
}
