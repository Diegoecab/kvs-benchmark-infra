# Benchmark runner images

These Packer templates move package installation and container-image downloads out of the benchmark deployment path. They produce one promoted image per provider with:

- the provider control agent and clock synchronization enabled;
- Podman, `jq`, archive utilities, and the provider CLI required by the runner;
- a 2 GiB swap file for the 1 GiB benchmark shapes;
- the immutable benchmark container already stored by its SHA-256 digest;
- `/etc/kvs-benchmark-image-release`, which cloud-init verifies before declaring a VM ready.

No workload, dataset, table credential, database password, run ID, result, or evidence is stored in an image. OCI image cleanup and cloud-init cleanup remove instance identity before the image is captured.

## Build and promote

Run Packer from an approved cloud-connected build environment. The temporary builder VM is not a load generator and is terminated by Packer. Prefer a private build subnet and `use_private_ip=true` when the build environment can reach it; otherwise use a tightly controlled public build subnet only for the short-lived image build.

Copy the two `.pkrvars.hcl.example` files to their ignored `.pkrvars.hcl` names and fill the pinned base-image, subnet, profile, and runner-digest inputs. The same Node command works on macOS, Linux, and Windows and runs init, formatting, validation, and build in order:

```bash
node images/build.mjs --provider=aws
node images/build.mjs --provider=oci
node images/build.mjs --provider=all
```

Use `--validate-only=true` to exercise both templates without creating cloud resources. `PACKER_BIN` can point to a verified Packer executable when it is not on `PATH`. Each successful build writes an ignored `manifest-aws.json` or `manifest-oci.json` beside the template. Rebuilding after an image was deleted uses the same command and inputs; promote the newly returned ID only after its smoke test passes.

Do not promote an image directly from a successful build. First launch the same runner count and shapes used by the benchmark, then require all of these gates:

1. every control agent reaches its online/running state;
2. cloud-init validates the embedded provider and runner-image digest;
3. Podman finds the digest locally without a registry request;
4. clock synchronization, CPU/memory telemetry, and evidence upload work;
5. each target can perform a short data-plane request;
6. all sources have the expected distinct network identities.

Both templates require an explicit base-image ID; selecting an unpinned newest image is not a release input. Record the resulting AMI ID or OCI image OCID, base-image ID, runner digest, build manifest, smoke-test result, and promotion timestamp. Terraform must pin the promoted ID and set `runner_bootstrap_mode = "prebaked"`. OCI can then start with `bootstrap_internet_access_enabled = false`, eliminating the NAT bootstrap entirely.

## Rebuild policy

Rebuild only when the base OS, a host package/control agent, the runner container digest, or the image schema changes. A normal benchmark run does not rebuild an image. Retain the prior promoted version for rollback until its replacement passes the multi-VM smoke test.

## Time budget

Image construction is a release activity, not a benchmark stage. For a normal run, infrastructure readiness should consist of instance launch, agent registration, manifest verification, clock verification, and a data-plane smoke test. Alert when this exceeds five minutes per provider; package repository access or registry pulls in `prebaked` mode are configuration defects.

Official references: [OCI custom images](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/managingcustomimages.htm), [OCI image cleanup guidance](https://docs.oracle.com/en-us/iaas/Content/Marketplace/create-image.htm), [Packer OCI builder](https://developer.hashicorp.com/packer/integrations/hashicorp/oracle/latest/components/builder/oci), [EC2 Image Builder](https://docs.aws.amazon.com/imagebuilder/latest/userguide/start-build-image-pipeline.html), and [Packer Amazon EBS builder](https://developer.hashicorp.com/packer/integrations/hashicorp/amazon/latest/components/builder/ebs).
