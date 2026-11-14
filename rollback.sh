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

# Prefer the newest clean pre-faultlab backup. Older installs could leave the
# newest backup already containing faultlab parameters, so strip any remaining
# tokens unconditionally before regenerating GRUB.
backup=""
clean_backup=""
for candidate in /etc/default/grub.faultlab.[0-9]*; do
    [[ -f $candidate ]] || continue
    backup=$candidate
    if ! grep -qE '(^|[[:space:]])(isolcpus|nohz_full|rcu_nocbs|irqaffinity)=' "$candidate"; then
        clean_backup=$candidate
    fi
done
restore=${clean_backup:-$backup}
if [[ -n $restore ]]; then
    cp -a "$restore" /etc/default/grub
    echo "restored: $restore"
elif [[ -f /etc/default/grub ]]; then
    cp -a /etc/default/grub /etc/default/grub.faultlab-rollback-before
    echo "rollback: no grub backup found; stripping faultlab parameters"
else
    echo "rollback: /etc/default/grub not found" >&2
fi

if [[ -f /etc/default/grub ]]; then
    sed -i -E \
        -e 's/[[:space:]]+(isolcpus|nohz_full|rcu_nocbs|irqaffinity)=[^"[:space:]]*//g' \
        -e 's/"(isolcpus|nohz_full|rcu_nocbs|irqaffinity)=[^"[:space:]]*[[:space:]]*/"/g' \
        -e 's/(GRUB_CMDLINE_LINUX_DEFAULT=")[[:space:]]+/\1/' \
        -e 's/[[:space:]]+"/"/' \
        /etc/default/grub
fi

if command -v update-grub >/dev/null 2>&1; then
    update-grub
elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg
else
    echo "rollback: regenerate grub manually" >&2
fi

# Final defense: never leave faultlab parameters in the generated GRUB config.
if [[ -f /boot/grub/grub.cfg ]]; then
    sed -i -E 's/[[:space:]]+(isolcpus|nohz_full|rcu_nocbs|irqaffinity)=[^[:space:]"]*//g' \
        /boot/grub/grub.cfg
fi

rm -f /etc/faultlab/mode "$conf"
rmdir /etc/faultlab 2>/dev/null || true
echo "rollback complete; reboot to drop the boot parameters"
