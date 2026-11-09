#!/usr/bin/env bash
# scripts/build_rootfs.sh — build the guest kernel + base root filesystem (Project Plan MVP, section 1b).
#
# Run on the host (sbx-node-1):   sudo ./scripts/build_rootfs.sh
#
# Produces in ~/fc:
#   vmlinux          the guest kernel
#   rootfs.ext4      the base image (every sandbox gets its own copy of this)
#   vm_key(.pub)     SSH key for debugging (reused across rebuilds if it already exists)
#   build-info.txt   exactly which CI artifacts were used
#
# To reproduce an exact earlier build, copy the keys from build-info.txt:
#   sudo KERNEL_KEY=firecracker-ci/... UBUNTU_KEY=firecracker-ci/... ./scripts/build_rootfs.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

REAL_USER="${SUDO_USER:-root}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
WORKDIR="${WORKDIR:-$REAL_HOME/fc}"
ROOTFS_DIR="$WORKDIR/rootfs-dir"
ROOTFS_SIZE="${ROOTFS_SIZE:-4G}"
GUEST_PACKAGES="python3 git curl ca-certificates nodejs npm"

S3="https://s3.amazonaws.com/spec.ccfc.min"
ARCH="$(uname -m)"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Unmount anything left mounted inside rootfs-dir (also runs on exit or error).
# This MUST happen before any rm -rf of rootfs-dir, or we'd delete through the host's /dev.
cleanup_mounts() {
  local m
  for m in dev/pts dev sys proc; do
    if mountpoint -q "$ROOTFS_DIR/$m" 2>/dev/null; then umount "$ROOTFS_DIR/$m"; fi
  done
}
trap cleanup_mounts EXIT

# --- 1. Find the kernel and Ubuntu image in Firecracker's CI bucket -----------
FC_VERSION="$(firecracker --version | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')"
CI_VERSION="${FC_VERSION%.*}"   # v1.x.y -> v1.x

list_keys() {  # list_keys <prefix> <key regex>  -> matching keys, oldest..newest
  curl -fsSL "$S3?list-type=2&prefix=$1" | grep -oP "(?<=<Key>)$2(?=</Key>)" | sort -V || true
}

pick_prefix() {
  local p="firecracker-ci/${CI_VERSION}/${ARCH}/"
  if [[ -n "$(list_keys "${p}vmlinux-" "${p}vmlinux-[0-9]+\.[0-9]+\.[0-9]+")" ]]; then
    echo "$p"; return
  fi
  # Newer Firecracker docs publish CI artifacts in dated folders instead of per-version ones.
  local dated
  dated="$(curl -fsSL "$S3?list-type=2&prefix=firecracker-ci/&delimiter=/" \
    | grep -oP "(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)" | sort | tail -1 || true)"
  echo "WARNING: no CI folder for ${CI_VERSION}; using latest dated CI build: ${dated}" >&2
  echo "${dated}${ARCH}/"
}

if [[ -z "${KERNEL_KEY:-}" || -z "${UBUNTU_KEY:-}" ]]; then
  PREFIX="$(pick_prefix)"
  : "${KERNEL_KEY:=$(list_keys "${PREFIX}vmlinux-" "${PREFIX}vmlinux-[0-9]+\.[0-9]+\.[0-9]+" | tail -1)}"
  : "${UBUNTU_KEY:=$(list_keys "${PREFIX}ubuntu-" "${PREFIX}ubuntu-[0-9]+\.[0-9]+\.squashfs" | tail -1)}"
fi
[[ -n "$KERNEL_KEY" && -n "$UBUNTU_KEY" ]] \
  || { echo "Could not find a kernel and Ubuntu image in the Firecracker CI bucket." >&2; exit 1; }
echo "Firecracker: $FC_VERSION"
echo "Kernel:      $KERNEL_KEY"
echo "Ubuntu:      $UBUNTU_KEY"

# --- 2. Start from scratch and download -------------------------------------
cleanup_mounts
rm -rf "$ROOTFS_DIR" vmlinux ubuntu.squashfs rootfs.ext4
curl -fL -o vmlinux "$S3/$KERNEL_KEY"
curl -fL -o ubuntu.squashfs "$S3/$UBUNTU_KEY"
unsquashfs -q -d "$ROOTFS_DIR" ubuntu.squashfs

# --- 3. Add what the agent needs: Python (guest agent), git + Node (coding tasks), DNS ---
rm -f "$ROOTFS_DIR/etc/resolv.conf"
printf 'nameserver 8.8.8.8\noptions single-request-reopen\n' > "$ROOTFS_DIR/etc/resolv.conf"

mkdir -p "$ROOTFS_DIR"/{proc,sys,dev}
mount -t proc  proc          "$ROOTFS_DIR/proc"
mount -t sysfs sys           "$ROOTFS_DIR/sys"
mount --bind   /dev          "$ROOTFS_DIR/dev"
mount --bind   /dev/pts      "$ROOTFS_DIR/dev/pts"

chroot "$ROOTFS_DIR" /bin/bash -c "
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y $GUEST_PACKAGES
  apt-get clean
  rm -rf /var/lib/apt/lists/*
"
cleanup_mounts

for bin in python3 git curl node npm; do
  [[ -x "$ROOTFS_DIR/usr/bin/$bin" ]] || { echo "Missing /usr/bin/$bin in rootfs" >&2; exit 1; }
done

# --- 4. SSH key for debugging (kept across rebuilds so existing logins keep working) ---
[[ -f vm_key ]] || ssh-keygen -q -t ed25519 -f vm_key -N "" -C "sbx-debug"
chown "$REAL_USER": vm_key vm_key.pub
install -d -m 700 "$ROOTFS_DIR/root/.ssh"
install -m 600 vm_key.pub "$ROOTFS_DIR/root/.ssh/authorized_keys"

# --- 5. Pack into the base disk image ---------------------------------------
chown -R root:root "$ROOTFS_DIR"
truncate -s "$ROOTFS_SIZE" rootfs.ext4
mkfs.ext4 -q -d "$ROOTFS_DIR" -F rootfs.ext4
e2fsck -fn rootfs.ext4 >/dev/null || { echo "rootfs.ext4 failed e2fsck" >&2; exit 1; }

# --- 6. Record what we built --------------------------------------------------
cat > build-info.txt <<EOF
built_at=$(date -u +%FT%TZ)
firecracker=$FC_VERSION
kernel_key=$KERNEL_KEY
ubuntu_key=$UBUNTU_KEY
rootfs_size=$ROOTFS_SIZE
guest_packages=$GUEST_PACKAGES
EOF

echo
echo "Done. In $WORKDIR:"
ls -lh vmlinux rootfs.ext4 vm_key vm_key.pub build-info.txt
echo "Guest versions: $(chroot "$ROOTFS_DIR" python3 --version), node $(chroot "$ROOTFS_DIR" node --version)"
