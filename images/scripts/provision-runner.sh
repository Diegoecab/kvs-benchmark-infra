#!/usr/bin/env bash
set -euo pipefail

: "${KVS_PROVIDER:?KVS_PROVIDER is required}"
: "${KVS_RUNNER_IMAGE:?KVS_RUNNER_IMAGE is required}"

case "$KVS_PROVIDER" in
  aws)
    sudo dnf install -y chrony jq podman tar gzip
    command -v aws >/dev/null
    systemctl enable --now amazon-ssm-agent
    ;;
  oci)
    sudo dnf install -y chrony jq podman tar gzip
    systemctl enable --now oracle-cloud-agent
    getent passwd ocarun >/dev/null
    getent group oracle-cloud-agent >/dev/null
    cat > /etc/sudoers.d/101-oracle-cloud-agent-kvs-benchmark <<'SUDOERS'
ocarun ALL=(root) NOPASSWD: /usr/bin/podman *, /usr/bin/mkdir *, /usr/bin/chmod *, /usr/bin/chown *, /usr/bin/install *, /usr/bin/chronyc *, /usr/bin/jq *
SUDOERS
    chmod 0440 /etc/sudoers.d/101-oracle-cloud-agent-kvs-benchmark
    visudo -cf /etc/sudoers.d/101-oracle-cloud-agent-kvs-benchmark
    ;;
  *)
    echo "Unsupported KVS_PROVIDER: $KVS_PROVIDER" >&2
    exit 2
    ;;
esac

systemctl enable --now chronyd
test -f /var/swapfile || fallocate -l 2G /var/swapfile
chmod 0600 /var/swapfile
mkswap /var/swapfile >/dev/null 2>&1 || true
swapon /var/swapfile || true
grep -q '^/var/swapfile ' /etc/fstab || echo '/var/swapfile none swap defaults 0 0' >> /etc/fstab

install -d -o root -g root -m 0755 /opt/kvs-dashboard
install -d -o root -g root -m 0755 /opt/kvs-dashboard/results
if [[ "$KVS_PROVIDER" == "oci" ]]; then
  chown root:oracle-cloud-agent /opt/kvs-dashboard /opt/kvs-dashboard/results
  chmod 0750 /opt/kvs-dashboard /opt/kvs-dashboard/results
fi
podman pull "$KVS_RUNNER_IMAGE"
podman image exists "$KVS_RUNNER_IMAGE"

cat > /etc/kvs-benchmark-image-release <<EOF
schemaVersion=1
provider=$KVS_PROVIDER
runnerImage=$KVS_RUNNER_IMAGE
EOF
chmod 0444 /etc/kvs-benchmark-image-release

chronyc tracking >/dev/null
