# OCI Dallas 1,000 RU/WU benchmark stack

> Status (2026-09-01): the OCI NoSQL and private-runner portion is paused until
> the tenancy limit and IAM grants are raised. Do not apply the saved plan in
> its current form. The independently approved ADB DynamoDB API path is active;
> see `../../scripts/provision-adb-ddb-api.ps1`.

This isolated root module creates a dedicated VCN, NAT-backed private subnet, two private benchmark runners, one private versioned evidence bucket, and one provisioned OCI NoSQL table capped at 1,000 RU and 1,000 WU in `us-dallas-1`.

It deliberately does not create Autonomous AI Database yet. ADB creation requires an ADMIN password and DynamoDB API access-key bootstrap; those secrets must never enter Terraform state or the Git repository. Provision ADB through a separately approved secret-handling step, then write its protected runtime file only on the ADB runner at `/opt/kvs-dashboard/adb-api.runtime.json`.

Lifecycle:

1. Copy `deployment.auto.tfvars.example` to the ignored `deployment.auto.tfvars` and populate exact OCIDs.
2. Run `terraform init` and `terraform validate`.
3. Save and review `terraform plan -out=dallas.tfplan`.
4. Apply only after explicit approval bound to the reviewed plan.
5. Export outputs, complete ADB bootstrap, and run readiness/smoke gates.
6. Destroy only after the benchmark package has been collected and a separate destroy plan has been approved.

The module owns only resources in its dedicated state. Do not reuse the older `terraform/oci` state for this deployment.
