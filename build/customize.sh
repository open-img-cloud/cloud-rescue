#!/usr/bin/env bash
# Customize hook called by the build-libguestfs-image reusable workflow.
# Receives the qcow2 path as $1.
#
# cloud-rescue = Rocky Linux 9 GenericCloud (cloud-init, sshd, qemu-guest-agent, serial
# console) plus:
#   1. repair tools (LVM, mdadm, LUKS, XFS/ext4/vfat/NTFS, partitioning, recovery, network);
#   2. rescue-mount, which mounts the disk to repair on /mnt/sysimage for a chroot;
#   3. root autologin on the serial and graphical consoles (for VMs whose network is
#      broken; console access already goes through the cloud API);
#   4. the default cloud-init user renamed from `rocky` to `rescue`;
#   5. new filesystem UUIDs and the label `cloudrescue` on / and /boot.
#
# Why 5: every Rocky Linux 9 GenericCloud image shares the same filesystem UUIDs. Rescuing
# a VM made from it (our rocky-linux-9 image included) would put two disks with the same
# UUIDs in one machine: GRUB and the kernel could then boot or mount the wrong one, and
# XFS refuses to mount a second filesystem with a UUID already in use. The fstab, the
# boot loader entries and the GRUB configuration are rewritten to the new UUIDs, and the
# BIOS boot code is reinstalled (it embeds the /boot UUID).
#
# Rocky 9 rather than 10: Rocky 10 needs an x86-64-v3 CPU, and a rescue image has to boot
# on any VM, including clouds that expose an older CPU model.

set -euo pipefail

QCOW2="${1:?usage: customize.sh <path-to-qcow2>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOTFS="$HERE/rootfs"

[[ -f "$QCOW2" ]] || { echo "::error::qcow2 not found: $QCOW2" >&2; exit 1; }
echo "[customize] target: $QCOW2"

# Repair tools. BaseOS/AppStream first (must all install), then EPEL (best effort: a
# package missing from EPEL must not break the build, it is reported below).
BASE_PKGS=(
  lvm2 mdadm cryptsetup xfsprogs e2fsprogs dosfstools parted gdisk
  rsync vim-enhanced nano tmux lsof strace tcpdump bind-utils nmap-ncat
  smartmontools nvme-cli sg3_utils hdparm pciutils usbutils psmisc
  curl wget tar unzip jq tree file which efibootmgr qemu-img
)
EPEL_PKGS=(ntfs-3g ntfsprogs testdisk ddrescue ncdu htop)

virt-customize -a "$QCOW2" \
  --run-command 'dnf -y install epel-release' \
  --run-command "dnf -y install ${BASE_PKGS[*]}" \
  --run-command "dnf -y --setopt=strict=0 install ${EPEL_PKGS[*]}; for p in ${EPEL_PKGS[*]}; do rpm -q \$p >/dev/null || echo \"::warning::EPEL package \$p not installed\"; done" \
  --mkdir /etc/systemd/system/serial-getty@ttyS0.service.d \
  --mkdir /etc/systemd/system/getty@tty1.service.d \
  --mkdir /etc/motd.d \
  --upload "$ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d/10-oic-autologin.conf:/etc/systemd/system/serial-getty@ttyS0.service.d/10-oic-autologin.conf" \
  --upload "$ROOTFS/etc/systemd/system/getty@tty1.service.d/10-oic-autologin.conf:/etc/systemd/system/getty@tty1.service.d/10-oic-autologin.conf" \
  --upload "$ROOTFS/etc/motd.d/10-cloud-rescue:/etc/motd.d/10-cloud-rescue" \
  --upload "$ROOTFS/usr/local/sbin/rescue-mount:/usr/local/sbin/rescue-mount" \
  --chmod 0755:/usr/local/sbin/rescue-mount \
  --run-command 'sed -i -E "s/^(\s+name:\s+)rocky\s*$/\1rescue/; s/^(\s+gecos:\s+).*Rocky.*$/\1Cloud Rescue/" /etc/cloud/cloud.cfg' \
  --run-command 'grep -qE "^\s+name:\s+rescue\s*$" /etc/cloud/cloud.cfg' \
  --run-command 'dnf clean all; rm -rf /var/cache/dnf /var/cache/yum /tmp/* /var/tmp/*'

# --- 5. new filesystem UUIDs (offline, through guestfish) ------------------------------
echo "[customize] regenerating filesystem UUIDs"
eval "$(guestfish --listen --rw -a "$QCOW2")"
g() { guestfish --remote "$@"; }
# glob-expand takes one pattern: expand several.
globs() { local p; for p in "$@"; do g glob-expand "$p"; done; }
trap 'guestfish --remote exit >/dev/null 2>&1 || true' EXIT
g run
root_dev=$(g inspect-os | head -n1)
[[ -n "$root_dev" ]] || { echo "::error::no operating system found in $QCOW2" >&2; exit 1; }

declare -A mp_dev
while IFS= read -r line; do
  mp_dev["${line%%: *}"]="${line#*: }"
done < <(g inspect-get-mountpoints "$root_dev")
echo "[customize] mountpoints: $(for k in "${!mp_dev[@]}"; do printf '%s=%s ' "$k" "${mp_dev[$k]}"; done)"

declare -A old_new
for mp in / /boot; do
  dev=${mp_dev[$mp]:-}
  [[ -n "$dev" ]] || continue
  # / and /boot on one filesystem: already done.
  [[ "$mp" == /boot && "$dev" == "${mp_dev[/]}" ]] && continue
  old=$(g vfs-uuid "$dev")
  g set-uuid-random "$dev"
  new=$(g vfs-uuid "$dev")
  [[ -n "$old" && -n "$new" && "$old" != "$new" ]] || { echo "::error::UUID change failed on $dev" >&2; exit 1; }
  old_new[$old]=$new
  echo "[customize] $mp ($dev): $old -> $new"
done
g set-label "${mp_dev[/]}" cloudrescue

g mount "${mp_dev[/]}" /
[[ -n "${mp_dev[/boot]:-}" && "${mp_dev[/boot]}" != "${mp_dev[/]}" ]] && g mount "${mp_dev[/boot]}" /boot
[[ -n "${mp_dev[/boot/efi]:-}" ]] && g mount "${mp_dev[/boot/efi]}" /boot/efi

work=$(mktemp -d)
patched=0
for f in $(globs '/etc/fstab' '/etc/default/grub' '/etc/kernel/cmdline' \
  '/boot/loader/entries/*.conf' '/boot/grub2/grub.cfg' '/boot/grub2/grubenv' \
  '/boot/efi/EFI/*/grub.cfg'); do
  local_copy="$work/file"
  g download "$f" "$local_copy"
  before=$(sha256sum <"$local_copy")
  for old in "${!old_new[@]}"; do
    sed -i "s/$old/${old_new[$old]}/g" "$local_copy"
  done
  if [[ "$f" == /etc/fstab ]]; then
    # Never mount the EFI partition automatically: the disk being repaired may carry one
    # with the same identifiers.
    awk '$2 == "/boot/efi" && $4 !~ /noauto/ { $4 = $4 ",noauto,nofail" } { print }' \
      "$local_copy" >"$local_copy.new" && mv "$local_copy.new" "$local_copy"
  fi
  if [[ "$(sha256sum <"$local_copy")" != "$before" ]]; then
    g upload "$local_copy" "$f"
    patched=$((patched + 1))
    echo "[customize] updated $f"
  fi
done
# No file may still name an old UUID.
for f in $(globs '/etc/fstab' '/etc/kernel/cmdline' '/boot/loader/entries/*.conf' \
  '/boot/grub2/grub.cfg' '/boot/grub2/grubenv' '/boot/efi/EFI/*/grub.cfg'); do
  g download "$f" "$work/check"
  for old in "${!old_new[@]}"; do
    if grep -q "$old" "$work/check"; then
      echo "::error::$f still references the old UUID $old" >&2
      exit 1
    fi
  done
done
rm -rf "$work"
((patched > 0)) || { echo "::error::no boot or fstab file referenced the old UUIDs" >&2; exit 1; }
g umount-all
g exit
trap - EXIT

# BIOS boot code embeds the /boot UUID: reinstall it. Then restore SELinux labels on
# everything written above (uploads and guestfish edits).
virt-customize -a "$QCOW2" \
  --run-command 'if [ -d /usr/lib/grub/i386-pc ]; then grub2-install --target=i386-pc /dev/sda; fi' \
  --selinux-relabel

echo "[customize] done"
