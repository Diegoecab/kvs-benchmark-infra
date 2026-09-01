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
- OCI runners use a private subnet with no ingress rules and outbound HTTPS through a NAT Gateway; an Internet Gateway plus public VNIC is not an equivalent baseline.
- Database resources are isolated and provisioned; product autoscaling settings are explicit outputs.
- `destroy` targets only resources recorded in the dedicated Terraform state.

## OCI runner readiness

An OCI runner returned by the infrastructure project is not ready until all of the following are true:

- the instance lifecycle state is `RUNNING`;
- the `Compute Instance Run Command` plugin is `RUNNING`;
- `/var/lib/cloud/instance/kvs-benchmark-ready` exists;
- `ocarun` can run `sudo -n /usr/bin/podman image exists <IMAGE_DIGEST>`;
- `chronyc tracking` succeeds;
- the instance principal can access its selected database table and evidence bucket;
- a two-second single-target cloud smoke completes and its evidence package passes accounting.

The local dashboard remains the control plane. SSH, SCP, a public IP, and a private key are not part of the normal execution contract.

## Output handoff

The adapter writes one JSON document matching `contracts/benchmark-infrastructure.schema.json`. The benchmark repository treats that document as immutable run input and records its SHA-256 in the evidence package.
