# Terraform stacks

Provider implementations will live in independent `aws/` and `oci/` root modules with a shared naming/tagging contract. No root module is executable in the current reuse-existing milestone.

The OCI transitional stack in [`oci/`](oci/) creates only replacement-runner resources. It consumes the existing dedicated benchmark VCN as an input and owns a NAT Gateway, private route table, no-ingress security list, private subnet, compartment-scoped dynamic group, least-privilege runner policy, and two private runners. Databases, tables, buckets, the existing VCN, and previous runners are outside its state and cannot be destroyed by this stack.

The checked-in OCI runner cloud-init baseline is available at [`cloud-init/oci-runner.yaml`](cloud-init/oci-runner.yaml) and is used for the transitional runner replacement. It installs Podman, jq, chrony, and archive tools; enables the Oracle Cloud Agent and clock service; grants `ocarun` passwordless access only to commands invoked by the harness; preloads the immutable image by digest; validates image access as `ocarun`; and writes `/var/lib/cloud/instance/kvs-benchmark-ready` only after every gate passes.

Before changing the runner image, update both the image reference and release marker in the cloud-init file, validate the image on `linux/amd64`, and run the benchmark repository acceptance suite.
