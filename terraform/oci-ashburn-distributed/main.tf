locals {
  name_prefix = "kvs-${var.run_id}"
  runner_matrix = {
    "adb-01"  = { target = "adb", source = "01" }
    "adb-02"  = { target = "adb", source = "02" }
    "adb-03"  = { target = "adb", source = "03" }
    "ndcs-01" = { target = "ndcs", source = "01" }
    "ndcs-02" = { target = "ndcs", source = "02" }
    "ndcs-03" = { target = "ndcs", source = "03" }
  }
  adb_egress_networks = {
    "01" = { vcn_cidr = var.adb_egress_vcn_cidrs[0], subnet_cidr = var.adb_egress_subnet_cidrs[0] }
    "02" = { vcn_cidr = var.adb_egress_vcn_cidrs[1], subnet_cidr = var.adb_egress_subnet_cidrs[1] }
    "03" = { vcn_cidr = var.adb_egress_vcn_cidrs[2], subnet_cidr = var.adb_egress_subnet_cidrs[2] }
  }
  common_tags = {
    ManagedBy = "Terraform"
    Project   = "KVS-Benchmark"
    Purpose   = "Distributed KVS benchmark"
    RunId     = var.run_id
  }
  evidence_bucket_name = "${local.name_prefix}-evidence"
  nosql_table_name     = coalesce(var.nosql_table_name, "kvs_bm_${replace(var.run_id, "-", "_")}_ndcs")
  adb_api_table_name   = coalesce(var.adb_api_table_name, "kvs_bm_${replace(var.run_id, "-", "_")}_adbapi")
  derived_adb_name     = substr("KVS${replace(upper(var.run_id), "/[^0-9A-Z]/", "")}", 0, 30)
  adb_db_name          = coalesce(var.adb_db_name, local.derived_adb_name)
}

check "existing_iam_is_declared" {
  assert {
    condition = (
      var.create_tenancy_iam_resources ||
      (var.existing_dynamic_group_name != null && var.existing_policy_name != null)
    )
    error_message = "When create_tenancy_iam_resources is false, declare the existing dynamic group and policy used by the six runners."
  }
}

check "six_distinct_private_ips" {
  assert {
    condition     = length(toset([for runner in oci_core_instance.runner : runner.private_ip])) == 6
    error_message = "Every load generator must have a distinct private IP."
  }
}

check "prebaked_image_never_uses_nat" {
  assert {
    condition     = var.runner_bootstrap_mode != "prebaked" || !var.bootstrap_internet_access_enabled
    error_message = "prebaked mode must start with bootstrap_internet_access_enabled=false."
  }
}

data "oci_objectstorage_namespace" "current" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_services" "regional_oracle_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_vcn" "benchmark" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${local.name_prefix}-vcn"
  dns_label      = "kvsdist"
  freeform_tags  = local.common_tags
}

resource "oci_core_service_gateway" "benchmark" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "${local.name_prefix}-sgw"
  freeform_tags  = local.common_tags

  services {
    service_id = data.oci_core_services.regional_oracle_services.services[0].id
  }
}

resource "oci_core_nat_gateway" "bootstrap" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "${local.name_prefix}-bootstrap-nat"
  block_traffic  = !var.bootstrap_internet_access_enabled
  freeform_tags  = local.common_tags
}

resource "oci_core_route_table" "runner_private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "${local.name_prefix}-private-rt"
  freeform_tags  = local.common_tags

  route_rules {
    destination       = data.oci_core_services.regional_oracle_services.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.benchmark.id
    description       = "ADB, NoSQL, Object Storage, and OCI control traffic stays on Oracle Services Network"
  }

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.bootstrap.id
    description       = "Bootstrap-only access for the immutable GHCR image; blocked before measurement"
  }
}

resource "oci_core_security_list" "runner_private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "${local.name_prefix}-private-sl"
  freeform_tags  = local.common_tags

  # Intentionally no ingress_security_rules. Runners are controlled only by
  # the OCI Compute Instance Run Command agent.
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
  dns_label                  = "runnerpriv"
  availability_domain        = var.availability_domain
  prohibit_public_ip_on_vnic = true
  prohibit_internet_ingress  = true
  route_table_id             = oci_core_route_table.runner_private.id
  security_list_ids          = [oci_core_security_list.runner_private.id]
  freeform_tags              = local.common_tags
}

resource "oci_core_nat_gateway" "adb_egress" {
  for_each       = local.adb_egress_networks
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.adb_egress[each.key].id
  display_name   = "${local.name_prefix}-adb-${each.key}-nat"
  block_traffic  = false
  freeform_tags = merge(local.common_tags, {
    Target      = "adb"
    SourceIndex = each.key
  })
}

resource "oci_core_vcn" "adb_egress" {
  for_each       = local.adb_egress_networks
  compartment_id = var.compartment_ocid
  cidr_blocks    = [each.value.vcn_cidr]
  display_name   = "${local.name_prefix}-adb-${each.key}-vcn"
  dns_label      = "kvsadb${each.key}"
  freeform_tags = merge(local.common_tags, {
    Target      = "adb"
    SourceIndex = each.key
  })
}

resource "oci_core_route_table" "adb_egress" {
  for_each       = local.adb_egress_networks
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.adb_egress[each.key].id
  display_name   = "${local.name_prefix}-adb-${each.key}-rt"
  freeform_tags  = local.common_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.adb_egress[each.key].id
    description       = "Dedicated outbound identity for one ADB API load generator"
  }
}

resource "oci_core_security_list" "adb_egress" {
  for_each       = local.adb_egress_networks
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.adb_egress[each.key].id
  display_name   = "${local.name_prefix}-adb-${each.key}-sl"
  freeform_tags  = local.common_tags

  # No ingress. The OCI agent establishes its own outbound control channel.
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

resource "oci_core_subnet" "adb_egress" {
  for_each                   = local.adb_egress_networks
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.adb_egress[each.key].id
  cidr_block                 = each.value.subnet_cidr
  display_name               = "${local.name_prefix}-adb-${each.key}-subnet"
  dns_label                  = "runner"
  availability_domain        = var.availability_domain
  prohibit_public_ip_on_vnic = true
  prohibit_internet_ingress  = true
  route_table_id             = oci_core_route_table.adb_egress[each.key].id
  security_list_ids          = [oci_core_security_list.adb_egress[each.key].id]
  freeform_tags = merge(local.common_tags, {
    Target      = "adb"
    SourceIndex = each.key
  })
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
  name           = local.nosql_table_name
  ddl_statement  = "CREATE TABLE ${local.nosql_table_name} (pk STRING, sk STRING, payload STRING, version LONG, PRIMARY KEY (SHARD(pk), sk))"
  freeform_tags  = local.common_tags

  table_limits {
    capacity_mode      = "PROVISIONED"
    max_read_units     = 1000
    max_write_units    = 1000
    max_storage_in_gbs = 10
  }
}

resource "oci_database_autonomous_database" "benchmark" {
  compartment_id                      = var.compartment_ocid
  db_name                             = local.adb_db_name
  display_name                        = "${local.name_prefix}-adb"
  admin_password                      = var.adb_admin_password
  db_workload                         = "OLTP"
  db_version                          = "26ai"
  compute_model                       = "ECPU"
  compute_count                       = 8
  data_storage_size_in_gb             = 20
  license_model                       = "BRING_YOUR_OWN_LICENSE"
  is_auto_scaling_enabled             = false
  is_auto_scaling_for_storage_enabled = false
  is_free_tier                        = false
  freeform_tags = merge(local.common_tags, {
    "adb$feature" = jsonencode({ name = "DynamoDB_API", enable = true })
  })
}

resource "oci_core_instance" "runner" {
  for_each            = local.runner_matrix
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${local.name_prefix}-${each.key}-runner"
  shape               = "VM.Standard.E5.Flex"
  freeform_tags = merge(local.common_tags, {
    Target      = each.value.target
    SourceIndex = each.value.source
  })

  shape_config {
    ocpus         = 1
    memory_in_gbs = 1
  }

  create_vnic_details {
    subnet_id        = each.value.target == "adb" ? oci_core_subnet.adb_egress[each.value.source].id : oci_core_subnet.runner_private.id
    assign_public_ip = false
    display_name     = "${local.name_prefix}-${each.key}-vnic"
    hostname_label   = "kvs${replace(each.key, "-", "")}"
  }

  source_details {
    source_type = "image"
    source_id   = var.instance_image_ocid
  }

  agent_config {
    is_management_disabled = false
    is_monitoring_disabled = false

    plugins_config {
      name          = "Compute Instance Run Command"
      desired_state = "ENABLED"
    }

    plugins_config {
      name          = "Compute Instance Monitoring"
      desired_state = "ENABLED"
    }
  }

  metadata = {
    user_data = base64encode(templatefile("${path.module}/cloud-init/runner.yaml.tftpl", {
      bootstrap_mode = var.runner_bootstrap_mode
      runner_image   = var.runner_image
      target         = each.value.target
      source         = each.value.source
      run_id         = var.run_id
    }))
  }

  lifecycle {
    # An immutable digest is installed and verified separately before promotion.
    # Do not replace healthy runners merely because cloud-init metadata changed;
    # image/source or subnet changes still force the intended replacement.
    ignore_changes = [metadata]
  }
}

resource "oci_identity_dynamic_group" "runners" {
  count          = var.create_tenancy_iam_resources ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "kvs_${replace(var.run_id, "-", "_")}_runners_dg"
  description    = "Dedicated distributed KVS benchmark load generators"
  matching_rule  = "ANY {${join(", ", [for runner in oci_core_instance.runner : "instance.id = '${runner.id}'"])} }"
  freeform_tags  = local.common_tags
}

resource "oci_identity_policy" "runner_access" {
  count          = var.create_tenancy_iam_resources ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "${local.name_prefix}-runner-access"
  description    = "Scoped data-plane and evidence permissions for distributed KVS benchmark runners"
  statements = [
    "Allow dynamic-group '${var.identity_domain_name}'/'${oci_identity_dynamic_group.runners[0].name}' to use instance-agent-command-execution-family in compartment id ${var.compartment_ocid} where request.instance.id=target.instance.id",
    "Allow dynamic-group '${var.identity_domain_name}'/'${oci_identity_dynamic_group.runners[0].name}' to read buckets in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group '${var.identity_domain_name}'/'${oci_identity_dynamic_group.runners[0].name}' to manage objects in compartment id ${var.compartment_ocid} where target.bucket.name='${oci_objectstorage_bucket.evidence.name}'",
    "Allow dynamic-group '${var.identity_domain_name}'/'${oci_identity_dynamic_group.runners[0].name}' to read nosql-tables in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group '${var.identity_domain_name}'/'${oci_identity_dynamic_group.runners[0].name}' to manage nosql-rows in compartment id ${var.compartment_ocid} where target.nosql-table.name='${oci_nosql_table.benchmark.name}'"
  ]
  freeform_tags = local.common_tags
}
