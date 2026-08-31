# Terraform stacks

Provider implementations will live in independent `aws/` and `oci/` root modules with a shared naming/tagging contract. No root module is executable in the current reuse-existing milestone.

The first implementation must expose only typed variables, pin provider versions, enable remote-state locking where configured, and emit the versioned dashboard contract.
