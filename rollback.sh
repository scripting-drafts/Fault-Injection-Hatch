#!/usr/bin/env bash
# Remove the fault-injection rig and bring the faulty core back online.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/faultlab-common.sh
. "$here/lib/faultlab-common.sh"

[[ $EUID -eq 0 ]] || { echo "rollback.sh: run with sudo" >&2; exit 1; }

conf=${FAULTLAB_CONF:-/etc/faultlab/config}
if [[ -r $conf ]]; then
    # shellcheck disable=SC1090
    . "$conf"
fi
if [[ -n ${FAULT_CPU:-} ]] && fl_cpu_exists "$FAULT_CPU"; then
    FAULT_CPUS=$(fl_siblings "$FAULT_CPU")
    fl_online_fault_cpus || true
fi

systemctl disable --now faultlab-retire.service 2>/dev/null || true
rm -f /etc/systemd/system/faultlab.slice \
    /etc/systemd/system/faultlab-retire.service \
    /etc/systemd/system/faultlab.slice.d/50-faultlab-cpus.conf \
    /etc/systemd/system/system.slice.d/50-faultlab-allowedcpus.conf \
    /etc/systemd/system/user.slice.d/50-faultlab-allowedcpus.conf
rmdir /etc/systemd/system/faultlab.slice.d 2>/dev/null || true

lib=/usr/local/lib/fault-injection-rig
if [[ -d $lib ]]; then
    for tool in "$lib"/bin/*; do
        [[ ${tool##*/} == faultlab-usb-restore ]] && continue
        [[ -e $tool ]] && rm -f "/usr/local/sbin/$(basename "$tool")"
    done
    rm -rf "$lib"
fi

systemctl daemon-reload

backup=""
for candidate in /etc/default/grub.faultlab.[0-9]*; do
    [[ -f $candidate ]] || continue
    backup=$candidate
done
if [[ -n $backup ]]; then
    cp -a "$backup" /etc/default/grub
    echo "restored: $backup"
    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        grub-mkconfig -o /boot/grub/grub.cfg
    else
        echo "rollback: regenerate grub manually" >&2
    fi
else
    echo "rollback: no grub backup found; check /etc/default/grub manually" >&2
fi

rm -f /etc/faultlab/mode "$conf"
rmdir /etc/faultlab 2>/dev/null || true
echo "rollback complete; reboot to drop the boot parameters"
