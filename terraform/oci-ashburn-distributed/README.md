# OCI Ashburn distributed benchmark stack

This isolated Terraform root module creates a fresh, same-region benchmark environment in `us-ashburn-1`:

- one dedicated VCN, Internet Gateway, public subnet, route table, and security list;
- no ingress security rules and only HTTPS, DNS, and NTP egress;
- exactly six `VM.Standard.E5.Flex` load generators at 1 OCPU and 1 GiB each;
- three independently addressed runners for ADB DynamoDB API and three for OCI NoSQL;
- OCI Run Command and Compute Instance Monitoring enabled on every runner;
- an immutable benchmark container image pinned by SHA-256 digest;
- one private, versioned Object Storage evidence bucket;
- one fresh OCI NoSQL table at 1,000 RU, 1,000 WU, and 10 GB;
- one fresh Autonomous AI Database 26ai using OLTP, 8 ECPU, 20 GB, BYOL, and no compute or storage autoscaling;
- the ADB `adb$feature` free-form tag enabling `DynamoDB_API`.

Each runner receives its own ephemeral public IP. The module checks that the six resulting addresses are distinct and outputs the three sources under each target. The security list exposes no inbound path; runner control is through the OCI agent.

## IAM mode

Tenancy IAM creation is disabled by default. Supply `existing_dynamic_group_name` and `existing_policy_name` for existing IAM that matches all six runner OCIDs and grants:

- Run Command execution-family use by the instance agents;
- read access to the private bucket and object management in that bucket;
- OCI NoSQL table inspection and row access to the benchmark table.

Setting `create_tenancy_iam_resources=true` opts into a dedicated dynamic group and policy. Review that tenancy-level change separately before planning or applying it. The Terraform caller still needs permission to submit Run Command operations; that operator permission is deliberately outside this module.

## ADB ADMIN password and state

`adb_admin_password` is a sensitive Terraform variable, but **sensitive values are still stored in Terraform state**. Local state is therefore a credential-bearing artifact. Keep the populated `deployment.auto.tfvars` and every state/plan file out of Git, restrict filesystem access, and prefer an approved encrypted remote backend with state locking. Rotate the ADMIN password if a state or plan file may have been exposed.

The root uses a partial `s3` backend so every deployment supplies its private encrypted/versioned state bucket and a root-specific key during `terraform init`. The ADMIN password should be injected through `TF_VAR_adb_admin_password` from a protected process environment; it must not be added to the populated tfvars file.

The OCI Terraform provider creates ADB and enables its DynamoDB API feature tag, but it does not create a DynamoDB API access key or DynamoDB-compatible table. Bootstrap those after `apply` through the approved secret-delivery workflow; do not put the resulting key or secret in Terraform variables, outputs, state, cloud-init, or source control.

## Safe workflow

1. Copy `deployment.auto.tfvars.example` to the ignored `deployment.auto.tfvars` and populate exact values.
2. Confirm the chosen Oracle Linux image supports `VM.Standard.E5.Flex` in `us-ashburn-1`.
3. Run `terraform init` and `terraform validate`.
4. Save and review `terraform plan -out=ashburn-distributed.tfplan`; confirm it creates six runners and fresh data resources.
5. Apply only after approval of that exact saved plan. This repository does not auto-apply.
6. Bootstrap the ADB DynamoDB API credential and table outside Terraform, then install credentials only on the three ADB runners.
7. Require all six readiness markers, clocks, agents, image digests, public IP identities, service access, and evidence upload checks to pass before starting a distributed workload.
8. Export `terraform output -json infrastructure_contract` and combine it with the AWS fragment for the benchmark control plane.

No teardown is automatic. Stop or destroy resources only after benchmark evidence has been packaged and a separate cleanup plan has been reviewed.
