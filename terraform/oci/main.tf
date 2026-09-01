locals {
  name_prefix = "meli-kvs-bm-20260901"
  common_tags = {
    ManagedBy = "Terraform"
    Project   = "MELI-IM44-KVS"
    Purpose   = "Private benchmark runner replacement"
    RunId     = var.run_id
  }
  runner_names = toset(["adb", "ndcs"])
}

resource "oci_core_nat_gateway" "runner" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_ocid
  display_name   = "${local.name_prefix}-nat"
  freeform_tags  = local.common_tags
}

resource "oci_core_route_table" "runner_private" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_ocid
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
  vcn_id         = var.vcn_ocid
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
  vcn_id                     = var.vcn_ocid
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

resource "oci_identity_dynamic_group" "compartment_runners" {
  compartment_id = var.tenancy_ocid
  name           = "meli_kvs_bm_20260901_compartment_runners_dg"
  description    = "All benchmark runners in the exclusive MELI KVS benchmark compartment"
  matching_rule  = "instance.compartment.id = '${var.compartment_ocid}'"
  freeform_tags  = local.common_tags
}

resource "oci_identity_policy" "runner_access" {
  compartment_id = var.tenancy_ocid
  name           = "meli-kvs-bm-20260901-private-runner-access"
  description    = "Run Command, NoSQL, and evidence access for private MELI KVS runners"
  statements = [
    "Allow dynamic-group 'Default'/'${oci_identity_dynamic_group.compartment_runners.name}' to use instance-agent-command-execution-family in compartment id ${var.compartment_ocid} where request.instance.id=target.instance.id",
    "Allow dynamic-group 'Default'/'${oci_identity_dynamic_group.compartment_runners.name}' to manage object-family in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group 'Default'/'${oci_identity_dynamic_group.compartment_runners.name}' to manage nosql-family in compartment id ${var.compartment_ocid}"
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
    }))
  }

  depends_on = [oci_identity_policy.runner_access]
}
