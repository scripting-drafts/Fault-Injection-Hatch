#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "rollback.sh: run with sudo" >&2; exit 1; }

systemctl disable --now faultlab-retire.service 2>/dev/null || true
rm -f /etc/systemd/system/faultlab.slice \
      /etc/systemd/system/faultlab-retire.service \
      /etc/systemd/system/system.slice.d/50-faultlab-allowedcpus.conf \
      /etc/systemd/system/user.slice.d/50-faultlab-allowedcpus.conf
rm -rf /usr/local/lib/fault-injection-rig
for name in faultlab faultlab-mode faultlab-ab faultlab-verify faultlab-watch \
            faultlab-classify faultlab-crypto; do
    rm -f "/usr/local/sbin/$name"
done
systemctl daemon-reload

backup=$(ls -1t /etc/default/grub.faultlab.* 2>/dev/null | head -1 || true)
if [[ -n ${backup:-} ]]; then
    cp -a "$backup" /etc/default/grub
    echo "restored: $backup"
    update-grub
else
    echo "rollback: no grub backup found; check /etc/default/grub manually" >&2
fi

# bring the core back if it was offlined
[[ -e /sys/devices/system/cpu/cpu2/online ]] && echo 1 > /sys/devices/system/cpu/cpu2/online || true
[[ -e /sys/devices/system/cpu/cpu8/online ]] && echo 1 > /sys/devices/system/cpu/cpu8/online || true
rm -f /etc/faultlab/mode
echo "rollback complete; reboot to drop the boot parameters"
