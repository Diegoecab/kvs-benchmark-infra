locals {
  name_prefix  = "meli-kvs-${var.run_id}"
  runner_names = toset(["adb", "ndcs"])
  common_tags = {
    ManagedBy = "Terraform"
    Project   = "MELI-IM44-KVS"
    Purpose   = "Dallas KVS benchmark"
    RunId     = var.run_id
  }
  evidence_bucket_name = "${local.name_prefix}-evidence"
}

data "oci_objectstorage_namespace" "current" {
  compartment_id = var.tenancy_ocid
}

resource "oci_core_vcn" "benchmark" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${local.name_prefix}-vcn"
  dns_label      = "kvsdallas"
  freeform_tags  = local.common_tags
}

resource "oci_core_nat_gateway" "runner" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "${local.name_prefix}-nat"
  freeform_tags  = local.common_tags
}

resource "oci_core_route_table" "runner_private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "${local.name_prefix}-private-rt"
  freeform_tags  = local.common_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.runner.id
  }
}

resource "oci_core_security_list" "runner_private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "${local.name_prefix}-private-sl"
  freeform_tags  = local.common_tags

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "6"
    tcp_options {
      min = 443
      max = 443
    }
  }
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "6"
    tcp_options {
      min = 53
      max = 53
    }
  }
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "17"
    udp_options {
      min = 53
      max = 53
    }
  }
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "17"
    udp_options {
      min = 123
      max = 123
    }
  }
}

resource "oci_core_subnet" "runner_private" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.benchmark.id
  cidr_block                 = var.private_subnet_cidr
  display_name               = "${local.name_prefix}-private-subnet"
  dns_label                  = "kvspriv"
  availability_domain        = var.availability_domain
  prohibit_public_ip_on_vnic = true
  prohibit_internet_ingress  = true
  route_table_id             = oci_core_route_table.runner_private.id
  security_list_ids          = [oci_core_security_list.runner_private.id]
  freeform_tags              = local.common_tags
}

resource "oci_objectstorage_bucket" "evidence" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.current.namespace
  name           = local.evidence_bucket_name
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Enabled"
  freeform_tags  = local.common_tags
}

resource "oci_nosql_table" "benchmark" {
  compartment_id = var.compartment_ocid
  name           = var.nosql_table_name
  ddl_statement  = "CREATE TABLE IF NOT EXISTS ${var.nosql_table_name} (pk STRING, sk STRING, payload STRING, version LONG, PRIMARY KEY (SHARD(pk), sk))"
  freeform_tags  = local.common_tags

  table_limits {
    capacity_mode      = "PROVISIONED"
    max_read_units     = var.nosql_read_units
    max_write_units    = var.nosql_write_units
    max_storage_in_gbs = 10
  }
}

resource "oci_identity_dynamic_group" "runners" {
  compartment_id = var.tenancy_ocid
  name           = "meli_kvs_${replace(var.run_id, "-", "_")}_runners_dg"
  description    = "Dedicated OCI Dallas KVS benchmark runners"
  matching_rule  = "instance.compartment.id = '${var.compartment_ocid}'"
  freeform_tags  = local.common_tags
}

resource "oci_identity_policy" "runner_access" {
  compartment_id = var.tenancy_ocid
  name           = "${local.name_prefix}-runner-access"
  description    = "Minimum data-plane and evidence permissions for Dallas benchmark runners"
  statements = [
    "Allow dynamic-group 'Default'/'${oci_identity_dynamic_group.runners.name}' to use instance-agent-command-execution-family in compartment id ${var.compartment_ocid} where request.instance.id=target.instance.id",
    "Allow dynamic-group 'Default'/'${oci_identity_dynamic_group.runners.name}' to read buckets in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group 'Default'/'${oci_identity_dynamic_group.runners.name}' to manage objects in compartment id ${var.compartment_ocid} where target.bucket.name='${oci_objectstorage_bucket.evidence.name}'",
    "Allow dynamic-group 'Default'/'${oci_identity_dynamic_group.runners.name}' to read nosql-tables in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group 'Default'/'${oci_identity_dynamic_group.runners.name}' to manage nosql-rows in compartment id ${var.compartment_ocid} where target.nosql-table.name='${oci_nosql_table.benchmark.name}'"
  ]
  freeform_tags = local.common_tags
}

resource "oci_core_instance" "runner" {
  for_each            = local.runner_names
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${local.name_prefix}-${each.key}-runner"
  shape               = var.shape
  freeform_tags       = merge(local.common_tags, { Target = each.key })

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.runner_private.id
    assign_public_ip = false
    display_name     = "${local.name_prefix}-${each.key}-vnic"
    hostname_label   = "kvs${each.key}"
  }

  source_details {
    source_type = "image"
    source_id   = var.image_ocid
  }

  agent_config {
    is_management_disabled = false
    is_monitoring_disabled = false
    plugins_config {
      name          = "Compute Instance Run Command"
      desired_state = "ENABLED"
    }
  }

  metadata = {
    user_data = base64encode(templatefile("${path.module}/cloud-init/runner.yaml.tftpl", {
      runner_image = var.runner_image
      target       = each.key
      run_id       = var.run_id
    }))
  }

  depends_on = [oci_identity_policy.runner_access]
}
