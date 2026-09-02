# OCI private runner replacement — 2026-09-01

## Scope

- Tenancy profile: environment-specific OCI CLI profile (not stored in this reusable deployment record)
- Region: `us-ashburn-1`
- Availability domain: `US-ASHBURN-AD-1`
- Parent boundary: existing exclusive `meli-kvs-bm-20260826-02` compartment
- Existing dedicated VCN: referenced as an input; not managed by this state
- Databases, tables, buckets, previous runners, and public subnet: not managed

## Terraform-owned resources

- One NAT Gateway
- One private route table with `0.0.0.0/0` through the NAT Gateway
- One no-ingress security list with only HTTPS, DNS, and NTP egress
- One AD-local private subnet with public IP assignment prohibited
- One compartment-scoped dynamic group
- One runner policy for Run Command, Object Storage evidence, and OCI NoSQL
- Two `VM.Standard.E5.Flex` runners, each with 2 OCPU and 16 GB RAM

Every resource is tagged with `ManagedBy=Terraform`, `Project=MELI-IM44-KVS`, and `RunId=20260901-runner-replacement`.

## Readiness gates

The instances are not accepted merely because they are `RUNNING`. Both must pass:

1. no public IP;
2. Compute Instance Run Command plugin `RUNNING`;
3. cloud-init readiness marker present;
4. `ocarun` passwordless access to the root Podman image store;
5. immutable runner image present by digest;
6. healthy `chronyc tracking`;
7. target-specific database and evidence access;
8. two-second single-target cloud smoke with valid evidence accounting.

Dynamic-group membership can take up to 30 minutes to propagate. A command that remains `ACCEPTED` during that period is not a successful readiness result.

## Local deployment state

The authoritative state is `terraform/oci/terraform.tfstate`. Exact resource OCIDs can be exported to the ignored `terraform/oci/outputs.json`. The state and output file must not be committed.

## Teardown

Teardown requires explicit user approval after benchmark evidence is packaged:

```powershell
terraform -chdir=terraform/oci plan -destroy -out=destroy.tfplan
terraform -chdir=terraform/oci apply destroy.tfplan
```

The destroy plan must show only the eight Terraform-owned resources above. Never remove the existing VCN, databases, tables, evidence buckets, previous runners, or compartment through this state.
