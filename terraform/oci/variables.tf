variable "oci_profile" { type = string }
variable "tenancy_ocid" { type = string }
variable "compartment_ocid" { type = string }
variable "vcn_ocid" { type = string }
variable "availability_domain" { type = string }
variable "image_ocid" { type = string }
variable "region" {
  type    = string
  default = "us-ashburn-1"
}
variable "run_id" {
  type    = string
  default = "20260901-runner-replacement"
}
variable "private_subnet_cidr" {
  type    = string
  default = "10.93.0.64/26"
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
