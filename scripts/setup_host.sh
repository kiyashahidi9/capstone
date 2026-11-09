#!/usr/bin/env bash
# scripts/setup_host.sh — rebuild the sandbox host (Project Plan MVP, section 1a).
#
#   1. On your laptop / Cloud Shell:   ./scripts/setup_host.sh create
#   2. SSH in:                         gcloud compute ssh sbx-node-1 --zone=us-east1-b
#   3. On sbx-node-1:                  sudo ./scripts/setup_host.sh provision
#   4. Re-check any time:              ./scripts/setup_host.sh verify
set -euo pipefail

VM_NAME="${VM_NAME:-sbx-node-1}"
ZONE="${ZONE:-us-east1-b}"
MACHINE_TYPE="${MACHINE_TYPE:-n2-standard-8}"
IMAGE_FAMILY="ubuntu-2404-lts-amd64"
IMAGE_PROJECT="ubuntu-os-cloud"
BOOT_DISK_SIZE="200GB"
BOOT_DISK_TYPE="${BOOT_DISK_TYPE:-pd-balanced}"

# Pinned Firecracker version (e.g. FC_VERSION="v1.16.1"). Leave empty ONLY on the
# very first build: the script resolves the latest release and prints it, then you
# pin that exact value here and in NOTES.md so everyone uses the same binary.
FC_VERSION="${FC_VERSION:-v1.18.0}"

FC_RELEASES="https://github.com/firecracker-microvm/firecracker/releases"

create() {
  gcloud compute instances create "$VM_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --boot-disk-size="$BOOT_DISK_SIZE" \
    --boot-disk-type="$BOOT_DISK_TYPE" \
    --enable-nested-virtualization
  echo "Created $VM_NAME. Next: gcloud compute ssh $VM_NAME --zone=$ZONE"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    curl wget jq git squashfs-tools e2fsprogs iproute2 iptables \
    python3 python3-venv python3-pip \
    cpu-checker   # provides kvm-ok
}

grant_kvm_access() {
  # Let the human user (not just root) open /dev/kvm. Takes effect on next login.
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    usermod -aG kvm "$SUDO_USER"
    echo "Added $SUDO_USER to the kvm group (log out and back in to apply)."
  fi
}

install_firecracker() {
  local arch ver tmp
  arch="$(uname -m)"
  ver="$FC_VERSION"

  if [[ -z "$ver" ]]; then
    ver="$(basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$FC_RELEASES/latest")")"
    echo ">>> FC_VERSION not pinned; latest release is $ver."
    echo ">>> Pin FC_VERSION=\"$ver\" in this script and record it in NOTES.md."
  fi

  if command -v firecracker >/dev/null 2>&1 && firecracker --version | head -1 | grep -qF "$ver"; then
    echo "Firecracker $ver already installed."
    return
  fi

  tmp="$(mktemp -d)"
  curl -fsSL "$FC_RELEASES/download/$ver/firecracker-$ver-$arch.tgz" | tar -xz -C "$tmp"
  install -m 0755 "$tmp/release-$ver-$arch/firecracker-$ver-$arch" /usr/local/bin/firecracker
  install -m 0755 "$tmp/release-$ver-$arch/jailer-$ver-$arch"      /usr/local/bin/jailer
  rm -rf "$tmp"
}

verify() {
  local failed=0
  check() { if eval "$2" >/dev/null 2>&1; then echo "PASS  $1"; else echo "FAIL  $1"; failed=1; fi; }

  check "/dev/kvm exists"                    "[[ -e /dev/kvm ]]"
  check "kvm-ok: KVM acceleration usable"    "/usr/sbin/kvm-ok"
  check "cgroup v2 (cgroup2fs)"              "[[ \$(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]]"
  check "python3 >= 3.11"                    "python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))'"
  check "firecracker at /usr/local/bin"      "[[ -x /usr/local/bin/firecracker ]]"
  check "firecracker --version"              "/usr/local/bin/firecracker --version"

  echo "---"
  /usr/sbin/kvm-ok || true
  python3 --version
  /usr/local/bin/firecracker --version 2>/dev/null | head -1 || true

  return "$failed"
}

provision() {
  [[ $EUID -eq 0 ]] || { echo "Run provision with sudo." >&2; exit 1; }
  install_packages
  grant_kvm_access
  install_firecracker
  verify
}

case "${1:-}" in
  create)    create ;;
  provision) provision ;;
  verify)    verify ;;
  *) echo "usage: $0 {create|provision|verify}" >&2; exit 1 ;;
esac
