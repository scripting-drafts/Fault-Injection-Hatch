#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "apply.sh: run with sudo" >&2; exit 1; }
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

backup=/etc/default/grub.faultlab.$(date +%Y%m%d-%H%M%S)
cp -a /etc/default/grub "$backup"
echo "grub backup: $backup"

params=(isolcpus=managed_irq,2,8 nohz_full=2,8 rcu_nocbs=2,8 irqaffinity=0-1,3-7,9-11)
line="GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash ${params[*]}\""

python3 - "$line" <<'PY'
import re, sys
path = "/etc/default/grub"
new = sys.argv[1]
text = open(path).read()
if "isolcpus=" in text:
    print("grub: isolation parameters already present, leaving file unchanged")
else:
    text2 = re.sub(r'(?m)^GRUB_CMDLINE_LINUX_DEFAULT=.*$', new, text, count=1)
    if text2 == text:
        text2 = text.rstrip("\n") + "\n" + new + "\n"
    open(path, "w").write(text2)
    print("grub: parameters added")
PY

update-grub

install -d /etc/faultlab /usr/local/sbin /usr/local/lib \
    /etc/systemd/system/system.slice.d /etc/systemd/system/user.slice.d
install -d -o root -g adm -m 0750 /var/log/faultlab
install -m 0644 "$here/systemd/faultlab.slice"            /etc/systemd/system/faultlab.slice
install -m 0644 "$here/systemd/faultlab-retire.service"   /etc/systemd/system/faultlab-retire.service
install -m 0644 "$here/systemd/system-slice-allowedcpus.conf" \
    /etc/systemd/system/system.slice.d/50-faultlab-allowedcpus.conf
install -m 0644 "$here/systemd/user-slice-allowedcpus.conf" \
    /etc/systemd/system/user.slice.d/50-faultlab-allowedcpus.conf

lib=/usr/local/lib/fault-injection-rig
rm -rf "$lib"
install -d "$lib"
cp -a "$here"/bin "$here"/tools "$here"/crypto "$here"/README.md "$lib"/
rm -rf "$lib"/bin/__pycache__ "$lib"/tools/__pycache__ "$lib"/crypto/__pycache__
for tool in "$lib"/bin/*; do
    ln -sf "$tool" "/usr/local/sbin/$(basename "$tool")"
done

echo retired > /etc/faultlab/mode
systemctl daemon-reload
systemctl enable faultlab-retire.service

echo
echo "installed. Reboot to activate isolcpus/nohz_full/rcu_nocbs/irqaffinity."
echo "After reboot: sudo faultlab-mode status && sudo faultlab-verify"
