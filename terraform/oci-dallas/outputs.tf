output "deployment" {
  sensitive = true
  value = {
    schemaVersion = 1
    runId         = var.run_id
    region        = var.region
    resources = {
      vcnId              = oci_core_vcn.benchmark.id
      subnetId           = oci_core_subnet.runner_private.id
      evidenceBucketName = oci_objectstorage_bucket.evidence.name
      nosqlTableName     = oci_nosql_table.benchmark.name
    }
    runners = {
      for key, runner in oci_core_instance.runner : key => {
        id            = runner.id
        displayName   = runner.display_name
        region        = var.region
        compartmentId = var.compartment_ocid
      }
    }
  }
}

output "ndcs_dashboard_target" {
  sensitive = true
  value = {
    region              = var.region
    runnerId            = oci_core_instance.runner["ndcs"].id
    runnerCompartmentId = var.compartment_ocid
    compartmentId       = var.compartment_ocid
    resource            = oci_nosql_table.benchmark.name
    evidenceBucket      = oci_objectstorage_bucket.evidence.name
  }
}
