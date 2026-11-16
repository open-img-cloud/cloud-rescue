<p align="center">
  <a href="https://openimages.cloud/images/cloud-rescue/">
    <img src="https://openimages.cloud/img/og/cloud-rescue.png" alt="Cloud Rescue image for OpenStack and Proxmox" width="720">
  </a>
</p>

<p align="center">
  <a href="https://openimages.cloud/images/cloud-rescue/"><img alt="Latest version" src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fimages.openimages.cloud%2Fcloud-rescue%2Flatest%2FMANIFEST.json&query=%24.version&label=latest&color=2459c4&cacheSeconds=3600"></a>
  <a href="https://github.com/open-img-cloud/cloud-rescue/actions/workflows/release.yml"><img alt="Release" src="https://github.com/open-img-cloud/cloud-rescue/actions/workflows/release.yml/badge.svg"></a>
  <a href="https://openimages.cloud/verify/"><img alt="Signed with Sigstore cosign" src="https://img.shields.io/badge/signed-Sigstore%20cosign-2459c4"></a>
  <a href="https://openimages.cloud/quality/"><img alt="Boot-tested on OpenStack" src="https://img.shields.io/badge/boot--tested-OpenStack-2459c4"></a>
  <a href="LICENSE"><img alt="License GPL-2.0" src="https://img.shields.io/badge/license-GPL--2.0-555"></a>
</p>

<p align="center">
  <a href="https://openimages.cloud/images/cloud-rescue/"><b>Catalog page</b></a> ·
  <a href="https://images.openimages.cloud/cloud-rescue/latest/">Download</a> ·
  <a href="https://openimages.cloud/verify/">Verify</a> ·
  <a href="https://github.com/open-img-cloud/docs">Documentation</a> ·
  <a href="https://github.com/open-img-cloud/cloud-rescue/issues">Report an issue</a>
</p>

Rescue image (qcow2) for **OpenStack** and **Proxmox**: boot it next to the disk of a VM that
no longer starts, mount that disk with one command, and repair it (fstab, boot loader, full
filesystem, lost SSH key, broken network configuration). Built on Rocky Linux 9 with the repair
tools preinstalled, signed with Sigstore cosign and boot-tested on a real OpenStack before it is
published.

## At a glance

| | |
|---|---|
| **Base** | [Rocky Linux](https://rockylinux.org/) 9 `GenericCloud` image from [dl.rockylinux.org](https://dl.rockylinux.org/pub/rocky/9/images/x86_64/), checked against its `CHECKSUM` |
| **Access** | user `rescue` with the SSH key of the instance, passwordless `sudo`; optional password from the metadata (`rescue_pass`); root logged in automatically on the serial and graphical consoles |
| **Helpers** | `rescue-menu`: menu of the common repairs, opened at login; `rescue-mount`: finds the system on the other disk, mounts it on `/mnt/sysimage` for a `chroot` |
| **Firmware** | BIOS |
| **Format** | qcow2, x86_64 (x86-64-v2, so it boots on older CPU models too) |
| **Version** | the Rocky Linux build it is made from, e.g. `9.8-20260525.0` ([all versions](https://images.openimages.cloud/cloud-rescue/versions.json)) |

## Rescue a VM

### OpenStack

```sh
# Once: upload the image (or let oic-sync keep it up to date)
M=https://images.openimages.cloud/cloud-rescue/latest/MANIFEST.json
V=$(curl -fsS $M | jq -r .version); F=$(curl -fsS $M | jq -r .filename)
curl -fLO https://images.openimages.cloud/cloud-rescue/$V/$F
openstack image create --disk-format qcow2 --container-format bare \
  --property hw_rescue_device=disk --property hw_rescue_bus=virtio \
  --property hw_qemu_guest_agent=yes --property os_admin_user=rescue \
  --file "$F" "Cloud Rescue"

# Each time: boot the server on the rescue image, its own disk attached next to it
openstack server rescue --image "Cloud Rescue" my-server
ssh rescue@<server address>        # same key as the server
# the repair menu opens: mount, fsck, password, SSH key, fstab, logs, GRUB...
# or by hand:
sudo -i
rescue-mount                       # mounts the server disk on /mnt/sysimage
chroot /mnt/sysimage /bin/bash     # repair, then exit
rescue-mount --umount
openstack server unrescue my-server
```

The `hw_rescue_*` properties enable stable device rescue (Nova Ussuri and later, needed for
servers that boot from a volume): the server disks keep their usual devices and the rescue
disk is added last. Without them Nova uses the legacy mode (rescue disk first, server disk
second), which works too: `rescue-mount` finds the right disk either way.

Lost the key, or need someone without it to log in? Put a password in the server metadata
before rescuing it: the rescue image sets it on `rescue` and SSH accepts it in addition to
the key. Without `rescue_pass` the image stays key-only.

```sh
openstack server set --property rescue_pass='a long passphrase' my-server
openstack server rescue --image "Cloud Rescue" my-server
ssh rescue@<server address>        # key or password
openstack server unset --property rescue_pass my-server   # afterwards
```

The admin password of `openstack server rescue --password` is used too when the cloud passes
it through a config drive. Metadata is readable by anyone who can see the server through the
API and from inside the VM: use a throwaway password and remove it afterwards.

No network in the VM? Open the server console (`openstack console url show my-server`, or the
dashboard): it is already logged in as root.

### Proxmox VE

Create a VM from the image (the catalog page has the `qm` commands, or use
[oic-sync](https://github.com/open-img-cloud/oic-sync)), then lend it the disk of the stopped
VM to repair, and give it back afterwards:

```sh
qm stop 120                                                   # VM to repair
qm disk move 120 scsi0 --target-vmid 9900 --target-disk scsi1 # 9900: rescue VM
qm start 9900                                                 # then rescue-mount in it
qm shutdown 9900
qm disk move 9900 scsi1 --target-vmid 120 --target-disk scsi0
qm start 120
```

## What is inside

On top of the official Rocky Linux 9 image:

- **Disks and filesystems**: `lvm2`, `mdadm`, `cryptsetup` (LUKS), `xfsprogs`, `e2fsprogs`,
  `dosfstools`, `ntfs-3g`, `parted`, `gdisk`, `efibootmgr`, `qemu-img`;
- **Recovery and diagnosis**: `testdisk` (and `photorec`), `ddrescue`, `smartmontools`,
  `nvme-cli`, `sg3_utils`, `hdparm`, `lsof`, `strace`, `ncdu`, `htop`;
- **Network and transfer**: `tcpdump`, `bind-utils`, `nmap-ncat`, `curl`, `wget`, `rsync`;
- **Editors and shell**: `vim`, `nano`, `tmux`, `jq`, `tree`;
- [`rescue-menu`](build/rootfs/usr/local/sbin/rescue-menu), opened at every interactive login
  (console or SSH with a terminal; not for `ssh host command`, and `RESCUE_NOMENU=1` skips it):
  mount the system, shell inside it, check or repair a filesystem (`xfs_repair`, `e2fsck`,
  `fsck.vfat`, `btrfs check`, `ntfsfix`), reset a password, add an SSH key, edit `/etc/fstab`
  (with a backup copy), read the last boot logs, rebuild the initramfs and the GRUB
  configuration (Debian/Ubuntu and RHEL-like systems), find what fills the disk, check the
  network of the rescue VM, unmount everything. Changes made from outside an SELinux system
  schedule a relabel at its next boot;
- [`rescue-mount`](build/rootfs/usr/local/sbin/rescue-mount): assembles RAID and LVM, finds the
  installed system on the other disk (XFS, ext4, Btrfs with its usual subvolumes), mounts it with
  its `/boot`, `/boot/efi` and other fstab entries, and binds `/dev`, `/proc`, `/sys` and `/run`
  for a `chroot`. Encrypted volumes are listed with the `cryptsetup open` command to run first.
  The rescue disk itself is never touched.

Two changes make it safe to rescue a VM built from the same Rocky Linux image (including the
openimages.cloud [rocky-linux-9](https://github.com/open-img-cloud/rocky-linux-9) image):
the root and `/boot` filesystems get their own UUIDs (label `cloudrescue`), so the boot loader
and the kernel never pick the other disk, and XFS filesystems of the repaired disk are mounted
with `nouuid`.

The image follows the openimages.cloud cloud-init policy (no root login over SSH, no SSH
password unless you set `rescue_pass`). The console autologin is the other exception, on
purpose: console access already
requires the cloud API (OpenStack console, Proxmox web interface) and is not reachable from
the network.

Every release must pass the same [runtime contract](https://openimages.cloud/quality/) on
OpenStack as the other images: SSH with the injected key, cloud-init finished, DNS, hostname,
root filesystem grown, passwordless `sudo`, IPv6 address and egress.

## How releases happen

1. Every day at 07:17 UTC a watcher looks for a new Rocky Linux 9 image and opens a pull
   request that bumps [`VERSION`](VERSION).
2. Merging it is all it takes: the release is tagged, built, signed, boot-tested and
   published, then `latest/` and the [catalog](https://openimages.cloud/images/) move to it.

This repository only holds what is specific to the rescue image: [`VERSION`](VERSION),
[`build/customize.sh`](build/customize.sh), the files under [`build/rootfs`](build/rootfs),
[`build/detect-upstream.sh`](build/detect-upstream.sh) and thin workflows calling the shared
pipeline in [`open-img-cloud/.github`](https://github.com/open-img-cloud/.github).

## License

The build tooling in this repository is under [GPL-2.0](LICENSE). The image keeps the licensing
terms of Rocky Linux and of each package. Rocky Linux is a trademark of the Rocky Enterprise
Software Foundation; this project is not affiliated with it.
