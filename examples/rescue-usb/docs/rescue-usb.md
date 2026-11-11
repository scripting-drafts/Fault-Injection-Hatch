# UEFI rescue USB

This example builds a UEFI FAT32 USB that automatically undoes the boot-time
changes made by faultlab. It is a recovery aid for the case where the next
boot fails after `apply.sh`; it is not a backup, a repair tool for unrelated
boot problems, or a substitute for physical access to the machine.

## How it works

The USB contains:

- `EFI/BOOT/BOOTX64.EFI` — a GRUB standalone image with an embedded menu;
- `faultlab/initrd-auto-<kernel>.img` — the host initramfs with an
  `init-bottom` hook added;
- `faultlab/grub.cfg` — a copy of the embedded menu;
- `faultlab/faultlab-usb-restore` — a host-side/manual fallback.

The menu loads the installed kernel from `/boot` but the **USB initramfs**.
The hook runs before `switch_root` and, on the mounted root filesystem:

1. restores the newest `/etc/default/grub.faultlab.[0-9]*` backup;
2. if no backup exists, strips `isolcpus`, `nohz_full`, `rcu_nocbs` and
   `irqaffinity` from `GRUB_CMDLINE_LINUX_DEFAULT`;
3. removes the faultlab systemd units and cgroup drop-ins;
4. removes the faultlab runtime configuration and installed tools;
5. regenerates `grub.cfg` in a chroot, then strips the same parameters from
   `/boot/grub/grub.cfg` as a fallback;
6. continues booting the restored system.

If none of those faultlab traces exist, the hook exits without changes.

## Build

Requirements: Ubuntu/Debian with initramfs-tools, `grub-mkstandalone`, `cpio`,
`zstd`, `unmkinitramfs`, `lsinitramfs`, and Python 3. The USB must be FAT32
and the machine must boot via UEFI. Secure Boot must be disabled because the
loader is unsigned.

```bash
# Identify the USB and create a FAT32 partition (destroys existing data).
lsblk
sudo umount /dev/sdX1 2>/dev/null || true
sudo mkfs.vfat -F 32 -n FAULTLAB /dev/sdX1
sudo sfdisk --part-type /dev/sdX 1 ef   # EFI System, optional but recommended

# Mount it, build the payload, then unmount.
udisksctl mount -b /dev/sdX1
./build-rescue-usb.sh /media/$USER/FAULTLAB
udisksctl unmount -b /dev/sdX1
```

`build-rescue-usb.sh` detects the root UUID, builds one rescue initramfs for
every kernel with a readable `/boot/initrd.img-*`, generates the GRUB menu and
EFI binary, and writes only under `EFI/` and `faultlab/` on the target.

## Use

1. Reboot and open the firmware boot menu (`F12`, `F11`, `Esc`, or the
   vendor-specific key).
2. Select the UEFI entry for the USB.
3. Choose `Auto-restore faultlab (kernel ...)`.
4. Let the machine finish booting; remove the USB.

The menu also contains a no-restore boot entry, a `Root shell
(init=/bin/bash)` entry, and a host-side restore entry that requires
`/usr/local/sbin/faultlab-usb-restore` on the installed system.

If the automatic entry fails, boot the root shell and run the copy from the
USB:

```bash
mkdir -p /mnt/usb
mount -t vfat /dev/sdX1 /mnt/usb
/mnt/usb/faultlab/faultlab-usb-restore --no-exec
```

## Limits and safety

- The installed kernel and `/boot` must still be readable; only the initramfs
  is carried by the USB.
- Rebuild the USB after a kernel, root-filesystem, or root-UUID change.
- Encrypted, LVM, RAID, or otherwise non-trivial root setups may need extra
  initramfs modules and were not part of the reference implementation.
- BIOS/legacy boot is not installed; only UEFI.
- Secure Boot must be disabled, or the loader must be signed.
- The USB can modify the installed system. Keep it physically secure and do
  not store credentials, keys, or unrelated data on it.
- The host-side script is installed by `apply.sh`; `rollback.sh` keeps it so
  the USB fallback entry remains usable.

## Validation

The reference implementation was tested by booting the generated loader under
QEMU/OVMF and by booting both generated initramfs variants against a disposable
ext4 image containing a fake faultlab installation. The hook restored the GRUB
backup, removed the units, ran the chrooted GRUB generator and stripped the
kernel parameters from `grub.cfg`. Repeat that test on your own distribution
before relying on the USB.
