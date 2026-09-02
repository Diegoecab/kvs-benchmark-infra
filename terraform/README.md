# Terraform stacks

The current distributed benchmark uses two independent root modules with separate remote state:

- [`aws-us-east-1-distributed/`](aws-us-east-1-distributed/README.md): three AWS load generators, a fresh DynamoDB table, and an evidence bucket.
- [`oci-ashburn-distributed/`](oci-ashburn-distributed/README.md): three ADB API load generators, three OCI NoSQL load generators, both fresh OCI data services, and an evidence bucket.

Both roots pin the same runner image and declare the equivalent 2-vCPU/1-GiB load-generator baseline. Terraform owns the infrastructure lifecycle; the benchmark control plane consumes only reviewed outputs and never adopts resources into state.

The OCI transitional stack in [`oci/`](oci/) creates only replacement-runner resources. It consumes the existing dedicated benchmark VCN as an input and owns a NAT Gateway, private route table, no-ingress security list, private subnet, compartment-scoped dynamic group, least-privilege runner policy, and two private runners. Databases, tables, buckets, the existing VCN, and previous runners are outside its state and cannot be destroyed by this stack.

The checked-in OCI runner cloud-init baseline is available at [`cloud-init/oci-runner.yaml`](cloud-init/oci-runner.yaml) and is used for the transitional runner replacement. It installs Podman, jq, chrony, and archive tools; enables the Oracle Cloud Agent and clock service; grants `ocarun` passwordless access only to commands invoked by the harness; preloads the immutable image by digest; validates image access as `ocarun`; and writes `/var/lib/cloud/instance/kvs-benchmark-ready` only after every gate passes.

The isolated [`oci-dallas/`](oci-dallas/) root module remains available for the earlier Dallas deployment and has its own state boundary.

Before changing the runner image, update both the image reference and release marker in the cloud-init file, validate the image on `linux/amd64`, and run the benchmark repository acceptance suite.
