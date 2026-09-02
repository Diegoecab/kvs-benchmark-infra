locals {
  runner_inventory = [
    for index, runner in aws_instance.runner : {
      id               = runner.id
      displayName      = runner.tags.Name
      source           = format("source-%02d", index + 1)
      region           = var.region
      availabilityZone = runner.availability_zone
      shape            = runner.instance_type
      vcpus            = 2
      memoryGiB        = 1
      privateIp        = runner.private_ip
      publicIp         = aws_eip.runner[index].public_ip
    }
  ]
}

output "runners" {
  description = "Exactly three distinct regional load generators and their network identities."
  value       = local.runner_inventory
}

output "aws_dashboard_target" {
  description = "Target contract accepted by the KVS Benchmark Control dashboard."
  value = {
    execution = {
      loadGeneratorCount = local.runner_count
    }
    targets = {
      aws = {
        enabled   = true
        profile   = var.aws_profile
        region    = var.region
        resource  = aws_dynamodb_table.benchmark.name
        runnerId  = aws_instance.runner[0].id
        runnerIds = aws_instance.runner[*].id
        runners   = local.runner_inventory
      }
    }
    artifactBucket = aws_s3_bucket.evidence.id
  }
}

output "infrastructure_contract" {
  description = "Versioned AWS fragment that the adapter combines with the OCI fragment before benchmark execution."
  value = {
    schemaVersion      = 2
    runId              = var.run_id
    loadGeneratorCount = local.runner_count
    runnerImage        = var.runner_image
    targets = {
      aws = {
        provider         = "aws"
        region           = var.region
        availabilityZone = var.availability_zone
        resource         = aws_dynamodb_table.benchmark.name
        resourceArn      = aws_dynamodb_table.benchmark.arn
        evidenceBucket   = aws_s3_bucket.evidence.id
        runners          = local.runner_inventory
      }
    }
  }
}

output "deployment" {
  description = "Inventory of resources owned by this isolated root module."
  value = {
    schemaVersion    = 1
    runId            = var.run_id
    region           = var.region
    availabilityZone = var.availability_zone
    resources = {
      vpcId              = var.vpc_id
      subnetId           = var.subnet_id
      dynamodbTableName  = aws_dynamodb_table.benchmark.name
      dynamodbTableArn   = aws_dynamodb_table.benchmark.arn
      evidenceBucketName = aws_s3_bucket.evidence.id
      securityGroupId    = aws_security_group.runner.id
      iamRoleArn         = aws_iam_role.runner.arn
    }
    runners = local.runner_inventory
  }
}
