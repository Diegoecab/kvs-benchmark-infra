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

- AWS DynamoDB is in `us-east-1`; the OCI deployment region is an explicit immutable input and currently supports `us-ashburn-1` and `us-dallas-1`.
- Resources are single-region and tagged with `kvs-benchmark-run-id`.
- Runner control is AWS SSM or OCI Compute Run Command.
- Evidence uses S3 or OCI Object Storage.
- Runners never expose ingress and do not use SSH, SCP, or local private keys.
- A distributed source-IP run gives every selected runner a distinct egress identity. The AWS root associates one Elastic IP per no-ingress VM; the OCI root uses one public VNIC address per no-ingress VM. This is a deliberate benchmark topology, not a management path.
- The configured offered load is aggregate per target. The benchmark deterministically shards it across the same number of runners for AWS DynamoDB, ADB DynamoDB API, and OCI NoSQL; adding runners must not multiply the target rate.
- Database resources are isolated and provisioned; product autoscaling settings are explicit outputs.
- `destroy` targets only resources recorded in the dedicated Terraform state.

## OCI runner readiness

An OCI runner returned by the infrastructure project is not ready until all of the following are true:

- the instance lifecycle state is `RUNNING`;
- the `Compute Instance Run Command` plugin is `RUNNING`;
- `/var/lib/cloud/instance/kvs-benchmark-ready` exists;
- `ocarun` can run `sudo -n /usr/bin/podman image exists <IMAGE_DIGEST>`;
- `chronyc tracking` succeeds;
- the instance principal or table-scoped service credential can access its selected database table, and the instance principal can access the evidence bucket;
- a two-second single-target cloud smoke completes and its evidence package passes accounting.

The local dashboard remains the control plane. SSH, SCP, and private keys are not part of the execution contract; public addresses provide outbound source identity only.

## Output handoff

The adapter combines the independently reviewed AWS and OCI Terraform outputs into one JSON document matching `contracts/benchmark-infrastructure.schema.json`. The benchmark repository treats that document as immutable run input and records its SHA-256 in the evidence package. Runner arrays are authoritative; singular runner fields exist only in legacy outputs.
