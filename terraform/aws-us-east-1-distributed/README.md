# AWS us-east-1 distributed benchmark stack

This isolated Terraform root module creates one AWS DynamoDB target and three independent load-generator VMs for a distributed KVS benchmark in `us-east-1a`. It reuses an existing VPC and public subnet; neither network resource enters this module's Terraform state.

## Resources

- One provisioned DynamoDB table with canonical string partition/sort keys (`pk`, `sk`) and fixed 500 RCU / 500 WCU.
- One private, public-access-blocked, AES-256 encrypted, versioned S3 evidence bucket.
- Exactly three `t3.micro` runners (2 vCPU, 1 GiB each), each with its own Elastic IP, unlimited CPU credits, and one-minute EC2 monitoring.
- One no-ingress security group. Egress is limited to HTTPS, VPC DNS, and Amazon Time Sync NTP.
- One EC2 role and instance profile: the standard SSM managed-instance policy plus table-scoped `DescribeTable`/`GetItem`/`PutItem` and write-only access below the bucket's `results/` evidence prefix.
- If the selected subnet routes DynamoDB through a pre-existing gateway endpoint, that endpoint policy must also include the newly created table ARN. The benchmark preflight checks this from every runner, before preload, and reports the stale endpoint policy explicitly.

A promoted AMI already contains Podman, AWS CLI, chrony, the SSM agent, and the immutable runner image by digest. In `prebaked` mode cloud-init only validates that manifest, starts services, checks clock synchronization, and writes the readiness marker. Package installation and registry downloads are reserved for image construction or recovery.

The configured workload rate remains the aggregate offered load for each target. The dashboard uses `loadGeneratorCount = 3` and deterministically shards that target load across the three source VMs; it does not multiply the requested offered rate by three.

## Existing-network prerequisites

The supplied subnet must:

1. belong to `vpc_id`;
2. be in `us-east-1a`;
3. have a route to an Internet Gateway, because each runner uses an Elastic IP;
4. use the VPC resolver for DNS.

The account also needs quota for three additional Elastic IP allocations in `us-east-1`.

There is no SSH ingress. Runner control is through AWS Systems Manager Run Command.

## Plan and apply deliberately

Copy `deployment.auto.tfvars.example` to an ignored `.auto.tfvars` file and replace the example VPC/subnet IDs and `run_id`.

Configure the partial `s3` backend with a private, encrypted, versioned bucket and a root-specific key. State locking must remain enabled. Backend credentials come from the selected AWS profile and are never written to Terraform files.

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan -out=distributed.tfplan
```

Review the saved plan before a separately authorized apply:

```bash
terraform apply distributed.tfplan
```

No apply is performed by repository validation. Destroy only after the benchmark package has been collected and the specific destroy plan has been reviewed.

## Dashboard contract

After apply, retrieve the reusable contract and runner inventory:

```bash
terraform output -json aws_dashboard_target
terraform output -json runners
terraform output -json infrastructure_contract
```

`aws_dashboard_target` contains the global load-generator count, table, evidence bucket, all three runner IDs, and each VM's shape, vCPU, memory, availability zone, private IP, and public source IP. The first `runnerId` is retained for backward compatibility; new runs use the complete `runnerIds`/`runners` arrays. `infrastructure_contract` is the versioned fragment merged with the OCI output and recorded in the final evidence package.
