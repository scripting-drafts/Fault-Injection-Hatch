#!/bin/sh
# Rescue-USB init-bottom hook: undo faultlab boot changes on the mounted root.
# Runs from the initramfs before switch_root, so it works even when the
# installed system cannot boot. Keep this POSIX/busybox-compatible.
set -u

rootmnt=${rootmnt:-/root}
LOG="$rootmnt/var/log/faultlab-usb-restore.log"

log() {
    echo "faultlab-usb-restore: $*" >>"$LOG" 2>/dev/null
    echo "faultlab-usb-restore: $*" >/dev/console 2>/dev/null
}

mkdir -p "$rootmnt/var/log" 2>/dev/null
mount -o remount,rw "$rootmnt" 2>/dev/null

# Nothing installed and no backup means there is nothing to undo.
if [ ! -e "$rootmnt/etc/faultlab/mode" ] &&
    [ ! -e "$rootmnt/etc/systemd/system/faultlab-retire.service" ] &&
    [ ! -e "$rootmnt/etc/systemd/system/faultlab.slice" ] &&
    ! grep -qE 'isolcpus=(domain,)?managed_irq' "$rootmnt/etc/default/grub" 2>/dev/null &&
    ! grep -qE 'isolcpus=(domain,)?managed_irq' "$rootmnt/boot/grub/grub.cfg" 2>/dev/null &&
    ! ls "$rootmnt"/etc/default/grub.faultlab.[0-9]* >/dev/null 2>&1; then
    log "no faultlab changes found; nothing to restore"
    exit 0
fi

log "starting restore on $rootmnt"

strip_grub_params() {
    sed -i -E \
        -e 's/[[:space:]]+(isolcpus|nohz_full|rcu_nocbs|irqaffinity)=[^"[:space:]]*//g' \
        -e 's/"(isolcpus|nohz_full|rcu_nocbs|irqaffinity)=[^"[:space:]]*[[:space:]]*/"/g' \
        -e 's/(GRUB_CMDLINE_LINUX_DEFAULT=")[[:space:]]+/\1/' \
        -e 's/[[:space:]]+"/"/' \
        "$1"
}

# Prefer the newest clean pre-faultlab backup. Older installs could leave the
# newest backup already containing faultlab parameters.
backup=""
clean_backup=""
for candidate in "$rootmnt"/etc/default/grub.faultlab.[0-9]*; do
    [ -f "$candidate" ] || continue
    backup=$candidate
    if ! grep -qE '(^|[[:space:]])(isolcpus|nohz_full|rcu_nocbs|irqaffinity)=' "$candidate"; then
        clean_backup=$candidate
    fi
done
restore=${clean_backup:-$backup}
if [ -n "$restore" ] && [ -f "$restore" ]; then
    cp -a "$restore" "$rootmnt/etc/default/grub"
    log "restored $restore -> /etc/default/grub"
elif [ -f "$rootmnt/etc/default/grub" ]; then
    cp -a "$rootmnt/etc/default/grub" "$rootmnt/etc/default/grub.faultlab-usb-before"
    log "no grub backup found; using current /etc/default/grub"
fi

if [ -f "$rootmnt/etc/default/grub" ]; then
    strip_grub_params "$rootmnt/etc/default/grub"
    log "stripped faultlab parameters from /etc/default/grub"
fi

rm -f "$rootmnt/etc/systemd/system/faultlab.slice" \
    "$rootmnt/etc/systemd/system/faultlab-retire.service" \
    "$rootmnt/etc/systemd/system/faultlab.slice.d/50-faultlab-cpus.conf" \
    "$rootmnt/etc/systemd/system/system.slice.d/50-faultlab-allowedcpus.conf" \
    "$rootmnt/etc/systemd/system/user.slice.d/50-faultlab-allowedcpus.conf"
rmdir "$rootmnt/etc/systemd/system/faultlab.slice.d" 2>/dev/null
rm -f "$rootmnt/etc/faultlab/mode" "$rootmnt/etc/faultlab/config"
rmdir "$rootmnt/etc/faultlab" 2>/dev/null

for name in faultlab faultlab-ab faultlab-classify faultlab-crypto \
    faultlab-mode faultlab-retire faultlab-verify faultlab-watch; do
    rm -f "$rootmnt/usr/local/sbin/$name"
done
rm -rf "$rootmnt/usr/local/lib/fault-injection-rig"

# update-grub needs proc/sys inside the target. Unmount them again so the
# normal init can move the initramfs mounts into place afterwards.
mount -t proc proc "$rootmnt/proc" 2>/dev/null
mount -t sysfs sysfs "$rootmnt/sys" 2>/dev/null
if [ -x "$rootmnt/usr/sbin/update-grub" ]; then
    chroot "$rootmnt" /usr/sbin/update-grub >>"$LOG" 2>&1 ||
        log "update-grub failed; see $LOG"
elif [ -x "$rootmnt/usr/sbin/grub-mkconfig" ]; then
    chroot "$rootmnt" /usr/sbin/grub-mkconfig -o /boot/grub/grub.cfg >>"$LOG" 2>&1 ||
        log "grub-mkconfig failed; see $LOG"
else
    log "no grub generator found; patching grub.cfg directly"
fi
if [ -f "$rootmnt/boot/grub/grub.cfg" ]; then
    sed -i -E 's/[[:space:]]+(isolcpus|nohz_full|rcu_nocbs|irqaffinity)=[^[:space:]"]*//g' \
        "$rootmnt/boot/grub/grub.cfg"
    log "stripped faultlab parameters from /boot/grub/grub.cfg"
fi
umount "$rootmnt/proc" 2>/dev/null
umount "$rootmnt/sys" 2>/dev/null

sync
log "restore complete; continuing boot"
exit 0
