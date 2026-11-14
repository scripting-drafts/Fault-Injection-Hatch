#!/usr/bin/env bash
# Build a UEFI faultlab rescue USB into a mounted FAT32 directory.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
target=${1:-}

# Keep the USB copy identical to the host-side recovery entrypoint.
repo_restore=$here/../../bin/faultlab-usb-restore
if [[ -f $repo_restore ]] && ! cmp -s "$here/faultlab-usb-restore" "$repo_restore"; then
    echo "$0: examples/rescue-usb/faultlab-usb-restore differs from bin/faultlab-usb-restore" >&2
    exit 1
fi

usage() {
    echo "usage: $0 MOUNTED_FAT32_DIRECTORY" >&2
    echo "  Builds EFI/BOOT/BOOTX64.EFI and faultlab/initrd-auto-<kernel>.img" >&2
    echo "  The target directory must already be a mounted FAT32 filesystem." >&2
}

[[ -n $target ]] || { usage; exit 2; }
[[ -d $target ]] || { echo "$0: target is not a directory: $target" >&2; exit 2; }
target=$(cd -- "$target" && pwd)
[[ -w $target ]] || { echo "$0: target is not writable: $target" >&2; exit 1; }

for cmd in unmkinitramfs cpio zstd grub-mkstandalone grub-script-check \
    lsinitramfs python3 findmnt; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "$0: missing required command: $cmd" >&2
        exit 1
    }
done

root_uuid=$(findmnt -no UUID /)
root_fstype=$(findmnt -no FSTYPE /)
[[ -n $root_uuid ]] || { echo "$0: cannot determine the root filesystem UUID" >&2; exit 1; }
case $root_fstype in
ext2 | ext3 | ext4 | xfs | btrfs) ;;
*)
    echo "$0: warning: root filesystem is '$root_fstype'; the rescue initramfs may lack its modules" >&2
    ;;
esac

target_fstype=$(findmnt -no FSTYPE -T "$target" 2>/dev/null || true)
[[ $target_fstype == vfat ]] ||
    echo "$0: warning: target filesystem is '$target_fstype'; UEFI usually requires FAT32" >&2

kernel=$(uname -r)
[[ -r /boot/initrd.img-$kernel ]] || {
    echo "$0: cannot read /boot/initrd.img-$kernel; run with sufficient permissions" >&2
    exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

build_initrd() {
    local ver=$1 dir=$work/initrd-$ver
    local order hook part parts=()
    mkdir -p "$dir"
    unmkinitramfs "/boot/initrd.img-$ver" "$dir" >/dev/null
    order=$dir/main/scripts/init-bottom/ORDER
    hook=$dir/main/scripts/init-bottom/zz-faultlab-restore
    [[ -d $dir/main/scripts/init-bottom ]] || {
        echo "$0: unsupported initramfs layout for $ver (expected initramfs-tools)" >&2
        return 1
    }
    install -m 0755 "$here/initramfs-hook.sh" "$hook"
    grep -q 'zz-faultlab-restore' "$order" 2>/dev/null || {
        printf '%s\n' '/scripts/init-bottom/zz-faultlab-restore "$@"' \
            '[ -e /conf/param.conf ] && . /conf/param.conf' >>"$order"
    }

    for part in early early2; do
        [[ -d $dir/$part ]] || continue
        (cd "$dir/$part" && find . -print0 |
            cpio --null -o --format=newc -R 0:0 --quiet) >"$dir/$part.cpio"
        parts+=("$dir/$part.cpio")
    done
    (cd "$dir/main" && find . -print0 |
        cpio --null -o --format=newc -R 0:0 --quiet) >"$dir/main.cpio"
    zstd -T0 -3 -f -q "$dir/main.cpio" -o "$dir/main.cpio.zst"
    parts+=("$dir/main.cpio.zst")
    cat "${parts[@]}" >"$work/initrd-auto-$ver.img"

    lsinitramfs "$work/initrd-auto-$ver.img" >"$work/initrd-$ver.list"
    grep -q 'zz-faultlab-restore' "$work/initrd-$ver.list" || {
        echo "$0: rescue hook missing from the $ver initramfs" >&2
        return 1
    }
}

kernels=()
for image in /boot/vmlinuz-*; do
    [[ -e $image ]] || continue
    ver=${image##*/vmlinuz-}
    if [[ ! -r /boot/initrd.img-$ver ]]; then
        echo "$0: skipping $ver (no readable initrd)" >&2
        continue
    fi
    kernels+=("$ver")
done

ordered=()
for ver in "${kernels[@]}"; do [[ $ver == "$kernel" ]] && ordered+=("$ver"); done
for ver in "${kernels[@]}"; do [[ $ver == "$kernel" ]] || ordered+=("$ver"); done
((${#ordered[@]})) || { echo "$0: no usable kernels found in /boot" >&2; exit 1; }

default_kernel=$kernel
if [[ ! " ${ordered[*]} " == *" $kernel "* ]]; then
    default_kernel=${ordered[0]}
    echo "$0: running kernel $kernel has no usable /boot entry; root shell uses $default_kernel" >&2
fi

install -d "$target/EFI/BOOT" "$target/faultlab"
entries=$work/entries.cfg
: >"$entries"

for ver in "${ordered[@]}"; do
    echo "building rescue initramfs for $ver" >&2
    build_initrd "$ver"
    install -m 0644 "$work/initrd-auto-$ver.img" "$target/faultlab/initrd-auto-$ver.img"

    cat >>"$entries" <<EOF
menuentry "Auto-restore faultlab (kernel $ver)" {
    insmod part_msdos
    insmod part_gpt
    insmod fat
    insmod ext2
    if search --no-floppy --file --set=usb /faultlab/initrd-auto-$ver.img; then
        search --no-floppy --fs-uuid --set=root $root_uuid
        linux /boot/vmlinuz-$ver root=UUID=$root_uuid ro quiet splash
        initrd (\$usb)/faultlab/initrd-auto-$ver.img
    else
        echo "Rescue initramfs not found on USB."
        sleep 10
    fi
}

menuentry "Boot installed system (kernel $ver, no restore)" {
    insmod part_msdos
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root $root_uuid
    linux /boot/vmlinuz-$ver root=UUID=$root_uuid ro quiet splash
    initrd /boot/initrd.img-$ver
}

EOF
done

python3 - "$here/grub.cfg.in" "$entries" "$root_uuid" "$default_kernel" "$work/grub.cfg" <<'PY'
import sys
template, entries, root_uuid, kernel, out = sys.argv[1:]
text = open(template, encoding="utf-8").read()
text = text.replace("@ENTRIES@", open(entries, encoding="utf-8").read().rstrip())
text = text.replace("@ROOT_UUID@", root_uuid).replace("@DEFAULT_KERNEL@", kernel)
open(out, "w", encoding="utf-8").write(text)
PY

grub-script-check "$work/grub.cfg"
grub-mkstandalone -O x86_64-efi -o "$work/BOOTX64.EFI" \
    --modules="part_msdos part_gpt fat ext2 normal linux search search_fs_uuid search_fs_file configfile echo test sleep chain all_video gfxterm" \
    "boot/grub/grub.cfg=$work/grub.cfg"

install -m 0644 "$work/BOOTX64.EFI" "$target/EFI/BOOT/BOOTX64.EFI"
install -m 0644 "$work/grub.cfg" "$target/faultlab/grub.cfg"
install -m 0755 "$here/faultlab-usb-restore" "$target/faultlab/faultlab-usb-restore"
install -m 0644 "$here/usb-README.txt" "$target/faultlab/README.txt"
sync

echo "built rescue USB payload in $target" >&2
echo "set the partition type to EFI System (0xef/EF00) and disable Secure Boot" >&2
