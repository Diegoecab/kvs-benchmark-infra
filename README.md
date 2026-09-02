# KVS Benchmark Infrastructure

Optional, isolated infrastructure for [`kvs-benchmark`](https://github.com/Diegoecab/kvs-benchmark).

This repository owns cloud resources only. It does not implement workloads, calculate benchmark metrics, or generate reports. The benchmark dashboard consumes the versioned output contract in [`contracts/benchmark-infrastructure.schema.json`](contracts/benchmark-infrastructure.schema.json).

## Current milestone

The clean distributed environment is split into two independently stateful Terraform roots:

- [`terraform/aws-us-east-1-distributed/`](terraform/aws-us-east-1-distributed/README.md) creates a fresh DynamoDB table, private S3 evidence bucket, and three same-size load generators in `us-east-1a`.
- [`terraform/oci-ashburn-distributed/`](terraform/oci-ashburn-distributed/README.md) creates a fresh OCI NoSQL table, a fresh Autonomous AI Database 26ai with DynamoDB API enabled, a private Object Storage evidence bucket, and three same-size load generators per OCI target in `us-ashburn-1`.

The nine load generators expose no ingress. Each one has a distinct controlled egress address so the benchmark can distribute, rather than multiply, the aggregate offered load across three source IPs per target. AWS Systems Manager and OCI Compute Run Command remain the only control paths.

No SSH, SCP, inbound public access, cross-region resources, or benchmark execution belongs here.

The first controlled OCI deployment is recorded in [`docs/deployments/20260901-runner-replacement.md`](docs/deployments/20260901-runner-replacement.md). Its databases, tables, buckets, VCN, and previous runners are deliberately outside Terraform state.

## Safety model

- Every deployment uses a unique run ID and dedicated resource boundary.
- `terraform plan`, `apply`, and `destroy` are separate dashboard approvals.
- Existing resources are data sources only and cannot be adopted or destroyed.
- Outputs contain identifiers and endpoints, never credentials.
- Teardown is never automatic; it is performed only after evidence is packaged and the exact cleanup scope is approved.

See [`docs/integration-contract.md`](docs/integration-contract.md) for the dashboard handoff.
