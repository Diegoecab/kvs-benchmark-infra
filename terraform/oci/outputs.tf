output "deployment" {
  value = {
    schemaVersion = 1
    runId         = var.run_id
    network = {
      natGatewayId   = oci_core_nat_gateway.runner.id
      subnetId       = oci_core_subnet.runner_private.id
      routeTableId   = oci_core_route_table.runner_private.id
      securityListId = oci_core_security_list.runner_private.id
    }
    identity = {
      dynamicGroupId = oci_identity_dynamic_group.compartment_runners.id
      policyId       = oci_identity_policy.runner_access.id
    }
    runners = {
      for key, runner in oci_core_instance.runner : key => {
        id            = runner.id
        displayName   = runner.display_name
        region        = var.region
        compartmentId = var.compartment_ocid
        subnetId      = oci_core_subnet.runner_private.id
      }
    }
  }
}

