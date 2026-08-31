# Dashboard integration contract

The control dashboard invokes this repository through a typed adapter. Free-form Terraform arguments from the browser are not accepted.

## Lifecycle

1. `validate`: check Terraform, cloud CLIs, credentials, regions, quotas, and input schema.
2. `plan`: create a saved plan and machine-readable change summary without cloud mutation.
3. `apply`: require explicit approval bound to the saved plan SHA-256.
4. `outputs`: validate `terraform output -json` against the checked-in schema.
5. `benchmark`: hand outputs to `kvs-benchmark`; this repository is idle.
6. `destroy-plan`: create and review a saved destroy plan.
7. `destroy`: require a second explicit approval after the benchmark package exists.

## Required invariants

- AWS region is `us-east-1`; OCI region is `us-ashburn-1`.
- Resources are single-region and tagged with `kvs-benchmark-run-id`.
- Runner control is AWS SSM or OCI Compute Run Command.
- Evidence uses S3 or OCI Object Storage.
- Runners do not require public IPs, SSH, SCP, or local private keys.
- Database resources are isolated and provisioned; product autoscaling settings are explicit outputs.
- `destroy` targets only resources recorded in the dedicated Terraform state.

## Output handoff

The adapter writes one JSON document matching `contracts/benchmark-infrastructure.schema.json`. The benchmark repository treats that document as immutable run input and records its SHA-256 in the evidence package.
