locals {
  runners_by_target_contract = {
    for target in ["adb", "ndcs"] : target => [
      for key in sort(keys(local.runner_matrix)) : {
        id                 = oci_core_instance.runner[key].id
        displayName        = oci_core_instance.runner[key].display_name
        source             = "source-${local.runner_matrix[key].source}"
        shape              = oci_core_instance.runner[key].shape
        vcpus              = oci_core_instance.runner[key].shape_config[0].ocpus * 2
        memoryGiB          = oci_core_instance.runner[key].shape_config[0].memory_in_gbs
        privateIp          = oci_core_instance.runner[key].private_ip
        publicIp           = null
        egressIp           = local.runner_matrix[key].target == "adb" ? oci_core_nat_gateway.adb_egress[local.runner_matrix[key].source].nat_ip : null
        egressIpVerified   = local.runner_matrix[key].target == "adb"
        availabilityDomain = var.availability_domain
        compartmentId      = var.compartment_ocid
      } if local.runner_matrix[key].target == target
    ]
  }
}

output "runners_by_target" {
  description = "Three independently addressed load generators for each benchmark target."
  sensitive   = true
  value = {
    for target in ["adb", "ndcs"] : target => [
      for key in sort(keys(local.runner_matrix)) : {
        source_index   = local.runner_matrix[key].source
        instance_id    = oci_core_instance.runner[key].id
        display_name   = oci_core_instance.runner[key].display_name
        public_ip      = null
        egress_ip      = local.runner_matrix[key].target == "adb" ? oci_core_nat_gateway.adb_egress[local.runner_matrix[key].source].nat_ip : null
        private_ip     = oci_core_instance.runner[key].private_ip
        shape          = oci_core_instance.runner[key].shape
        ocpus          = oci_core_instance.runner[key].shape_config[0].ocpus
        memory_in_gbs  = oci_core_instance.runner[key].shape_config[0].memory_in_gbs
        region         = var.region
        compartment_id = var.compartment_ocid
      } if local.runner_matrix[key].target == target
    ]
  }
}

output "infrastructure_contract" {
  description = "Versioned OCI fragment that the adapter combines with the AWS fragment before benchmark execution."
  sensitive   = true
  value = {
    schemaVersion      = 2
    runId              = var.run_id
    loadGeneratorCount = var.runner_count
    runnerImage        = var.runner_image
    machineImageId     = var.instance_image_ocid
    bootstrapMode      = var.runner_bootstrap_mode
    targets = {
      adb = {
        provider           = "oci"
        region             = var.region
        compartmentId      = var.compartment_ocid
        resource           = local.adb_api_table_name
        evidenceBucket     = oci_objectstorage_bucket.evidence.name
        runners            = local.runners_by_target_contract.adb
        databaseId         = oci_database_autonomous_database.benchmark.id
        databaseVersion    = oci_database_autonomous_database.benchmark.db_version
        workload           = oci_database_autonomous_database.benchmark.db_workload
        computeModel       = oci_database_autonomous_database.benchmark.compute_model
        computeCount       = oci_database_autonomous_database.benchmark.compute_count
        licenseModel       = oci_database_autonomous_database.benchmark.license_model
        autoscalingEnabled = oci_database_autonomous_database.benchmark.is_auto_scaling_enabled
      }
      ndcs = {
        provider       = "oci"
        region         = var.region
        compartmentId  = var.compartment_ocid
        resource       = oci_nosql_table.benchmark.name
        resourceId     = oci_nosql_table.benchmark.id
        evidenceBucket = oci_objectstorage_bucket.evidence.name
        runners        = local.runners_by_target_contract.ndcs
        readUnits      = var.nosql_read_units
        writeUnits     = var.nosql_write_units
        storageGiB     = 10
      }
    }
  }
}

output "autonomous_database" {
  description = "Fresh BYOL Autonomous AI Database and DynamoDB API endpoint metadata."
  value = {
    id                    = oci_database_autonomous_database.benchmark.id
    db_name               = oci_database_autonomous_database.benchmark.db_name
    display_name          = oci_database_autonomous_database.benchmark.display_name
    db_version            = oci_database_autonomous_database.benchmark.db_version
    workload              = oci_database_autonomous_database.benchmark.db_workload
    compute_model         = oci_database_autonomous_database.benchmark.compute_model
    compute_count         = oci_database_autonomous_database.benchmark.compute_count
    data_storage_size_gb  = oci_database_autonomous_database.benchmark.data_storage_size_in_gb
    license_model         = oci_database_autonomous_database.benchmark.license_model
    autoscaling_enabled   = oci_database_autonomous_database.benchmark.is_auto_scaling_enabled
    dynamodb_api_enabled  = true
    dynamodb_api_endpoint = "https://dataaccess.adb.${var.region}.oraclecloudapps.com/adb/keyvaluestore/v1/${oci_database_autonomous_database.benchmark.id}"
  }
}

output "nosql_table" {
  description = "Fresh provisioned OCI NoSQL benchmark table metadata."
  sensitive   = true
  value = {
    id             = oci_nosql_table.benchmark.id
    name           = oci_nosql_table.benchmark.name
    read_units     = var.nosql_read_units
    write_units    = var.nosql_write_units
    storage_gb     = 10
    compartment_id = var.compartment_ocid
  }
}

output "evidence_bucket" {
  description = "Private versioned evidence bucket."
  sensitive   = true
  value = {
    name           = oci_objectstorage_bucket.evidence.name
    namespace      = oci_objectstorage_bucket.evidence.namespace
    compartment_id = var.compartment_ocid
    access_type    = oci_objectstorage_bucket.evidence.access_type
  }
}

output "network" {
  description = "Private network metadata for the distributed runners."
  value = {
    vcn_id                            = oci_core_vcn.benchmark.id
    subnet_id                         = oci_core_subnet.runner_private.id
    service_gateway_id                = oci_core_service_gateway.benchmark.id
    bootstrap_nat_gateway_id          = oci_core_nat_gateway.bootstrap.id
    bootstrap_internet_access_enabled = var.bootstrap_internet_access_enabled
    security_list_id                  = oci_core_security_list.runner_private.id
    adb_egress = {
      for source, gateway in oci_core_nat_gateway.adb_egress : source => {
        vcn_id           = oci_core_vcn.adb_egress[source].id
        nat_gateway_id   = gateway.id
        egress_ip        = gateway.nat_ip
        subnet_id        = oci_core_subnet.adb_egress[source].id
        route_table_id   = oci_core_route_table.adb_egress[source].id
        security_list_id = oci_core_security_list.adb_egress[source].id
      }
    }
  }
}

output "iam" {
  description = "IAM mode used by the load generators."
  value = {
    resources_created  = var.create_tenancy_iam_resources
    dynamic_group_name = var.create_tenancy_iam_resources ? oci_identity_dynamic_group.runners[0].name : var.existing_dynamic_group_name
    policy_name        = var.create_tenancy_iam_resources ? oci_identity_policy.runner_access[0].name : var.existing_policy_name
  }
}

output "deployment" {
  description = "Control-plane handoff containing resource and per-source runner identities, without credentials."
  sensitive   = true
  value = {
    schema_version   = 1
    run_id           = var.run_id
    region           = var.region
    compartment_id   = var.compartment_ocid
    runner_image     = var.runner_image
    machine_image_id = var.instance_image_ocid
    bootstrap_mode   = var.runner_bootstrap_mode
    targets = {
      adb = {
        resource_id = oci_database_autonomous_database.benchmark.id
        runners = [for key in sort(keys(local.runner_matrix)) : {
          source_index = local.runner_matrix[key].source
          runner_id    = oci_core_instance.runner[key].id
          public_ip    = null
          egress_ip    = oci_core_nat_gateway.adb_egress[local.runner_matrix[key].source].nat_ip
          private_ip   = oci_core_instance.runner[key].private_ip
        } if local.runner_matrix[key].target == "adb"]
      }
      ndcs = {
        resource_id = oci_nosql_table.benchmark.id
        table_name  = oci_nosql_table.benchmark.name
        runners = [for key in sort(keys(local.runner_matrix)) : {
          source_index = local.runner_matrix[key].source
          runner_id    = oci_core_instance.runner[key].id
          public_ip    = null
          private_ip   = oci_core_instance.runner[key].private_ip
        } if local.runner_matrix[key].target == "ndcs"]
      }
    }
    evidence_bucket = oci_objectstorage_bucket.evidence.name
  }
}
