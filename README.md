# KVS Benchmark Infrastructure

Optional, isolated infrastructure for [`kvs-benchmark`](https://github.com/Diegoecab/kvs-benchmark).

This repository owns cloud resources only. It does not implement workloads, calculate benchmark metrics, or generate reports. The benchmark dashboard consumes the versioned output contract in [`contracts/benchmark-infrastructure.schema.json`](contracts/benchmark-infrastructure.schema.json).

## Current milestone

The repository contract and Terraform layout are initialized. Deployment is intentionally disabled while the benchmark dashboard is validated against existing infrastructure.

Planned provider stacks:

- AWS `us-east-1`: private runner controlled by Systems Manager, DynamoDB table, private S3 evidence bucket, and least-privilege IAM.
- OCI `us-ashburn-1`: private runners controlled by Compute Run Command, ADB DynamoDB API and/or OCI NoSQL destinations, private Object Storage evidence buckets, dynamic groups, and least-privilege policies.

No SSH, SCP, inbound public access, cross-region resources, or benchmark execution belongs here.

## Safety model

- Every deployment uses a unique run ID and dedicated resource boundary.
- `terraform plan`, `apply`, and `destroy` are separate dashboard approvals.
- Existing resources are data sources only and cannot be adopted or destroyed.
- Outputs contain identifiers and endpoints, never credentials.
- Teardown is never automatic; the user must explicitly approve it after evidence is packaged.

See [`docs/integration-contract.md`](docs/integration-contract.md) for the dashboard handoff.
