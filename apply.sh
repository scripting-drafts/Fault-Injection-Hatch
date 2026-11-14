#!/usr/bin/env bash
# Install the fault-injection rig for the physical core that contains FAULT_CPU.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/faultlab-common.sh
. "$here/lib/faultlab-common.sh"

usage() {
    cat <<EOF
usage: sudo ./apply.sh --fault-cpu N [--control-cpu M] [--dry-run]

  --fault-cpu N    any logical CPU on the faulty physical core (required)
  --control-cpu M  any logical CPU on a healthy core (default: auto-select)
  --dry-run        show the detected topology and generated config, change nothing

Re-run with the current config: sudo ./apply.sh
EOF
}

fault_cpu=""
control_cpu=""
control_cli=0
dry_run=0
while [[ $# -gt 0 ]]; do
    case $1 in
    --fault-cpu) fault_cpu=${2:?missing value}; shift 2 ;;
    --control-cpu) control_cpu=${2:?missing value}; control_cli=1; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "apply.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Reuse seeds from an existing install unless overridden on the command line.
if [[ -r /etc/faultlab/config ]]; then
    # shellcheck disable=SC1091
    . /etc/faultlab/config
fi
fault_cpu=${fault_cpu:-${FAULT_CPU:-}}
control_cpu=${control_cpu:-${CONTROL_CPU:-}}
if [[ -n $control_cpu && -n $fault_cpu ]] &&
    [[ $(fl_siblings "$control_cpu") == "$(fl_siblings "$fault_cpu")" ]]; then
    if ((control_cli)); then
        echo "apply.sh: control CPU $control_cpu is on the faulty core" >&2
        exit 2
    fi
    control_cpu=""
fi

print_cores() {
    local c sib
    echo "Detected physical cores:"
    for c in $(fl_expand_cpus "$(< /sys/devices/system/cpu/possible)"); do
        sib=$(fl_siblings "$c")
        [[ ${sib%%,*} == "$c" ]] || continue
        printf '  CPU %-3s -> CPUs %-12s package %s\n' \
            "$c" "$sib" "$(fl_cpu_attr "$c" physical_package_id)"
    done
}

if [[ -z $fault_cpu ]]; then
    print_cores >&2
    echo >&2
    echo "apply.sh: choose the faulty core, e.g. sudo ./apply.sh --fault-cpu 2" >&2
    exit 2
fi
fl_cpu_exists "$fault_cpu" || { echo "apply.sh: CPU $fault_cpu does not exist" >&2; exit 2; }
if [[ -n $control_cpu ]]; then
    fl_cpu_exists "$control_cpu" || { echo "apply.sh: CPU $control_cpu does not exist" >&2; exit 2; }
fi

FAULT_CPU=$fault_cpu
CONTROL_CPU=$control_cpu
fl_load_topology
fault_cpu=$FAULT_CPU
control_cpu=$CONTROL_CPU

if fl_list_has "$FAULT_CPUS" 0; then
    echo "apply.sh: warning: the faulty core contains CPU0 (the boot CPU); hotplug retirement may be refused." >&2
fi

fault_spaces=$(fl_cpus_spaces "$FAULT_CPUS")
safe_spaces=$(fl_cpus_spaces "$SAFE_CPUS")

if ((dry_run)); then
    echo "dry run: no changes will be made"
    fl_print_topology
    echo "grub: isolcpus=domain,managed_irq,$FAULT_CPUS nohz_full=$FAULT_CPUS rcu_nocbs=$FAULT_CPUS irqaffinity=$SAFE_CPUS"
    echo
    echo "--- /etc/systemd/system/faultlab.slice.d/50-faultlab-cpus.conf"
    printf '[Slice]\nAllowedCPUs=%s\n' "$fault_spaces"
    echo "--- /etc/systemd/system/system.slice.d/50-faultlab-allowedcpus.conf"
    printf '[Slice]\nAllowedCPUs=%s\n' "$safe_spaces"
    echo "--- /etc/systemd/system/user.slice.d/50-faultlab-allowedcpus.conf"
    printf '[Slice]\nAllowedCPUs=%s\n' "$safe_spaces"
    echo "--- /etc/faultlab/config"
    printf 'FAULTLAB_HOME=/usr/local/lib/fault-injection-rig\nFAULT_CPU=%s\nCONTROL_CPU=%s\nFAULT_CPUS=%s\nCONTROL_CPUS=%s\nSAFE_CPUS=%s\n' \
        "$fault_cpu" "$control_cpu" "$FAULT_CPUS" "$CONTROL_CPUS" "$SAFE_CPUS"
    exit 0
fi

[[ $EUID -eq 0 ]] || { echo "apply.sh: run with sudo" >&2; exit 1; }
[[ -r /etc/default/grub ]] || { echo "apply.sh: /etc/default/grub not found; this installer expects a GRUB system" >&2; exit 1; }

# Install the USB recovery entrypoint before changing anything boot-related.
install -d /usr/local/sbin
install -m 0755 -o root -g root "$here/bin/faultlab-usb-restore" /usr/local/sbin/faultlab-usb-restore

fl_print_topology

# Keep the first clean pre-faultlab backup. Re-runs and upgrades must not
# replace it with an already-modified file.
if ! grep -qE '(^|[[:space:]])(isolcpus|nohz_full|rcu_nocbs|irqaffinity)=' /etc/default/grub; then
    backup=/etc/default/grub.faultlab.$(date +%Y%m%d-%H%M%S)
    cp -a /etc/default/grub "$backup"
    echo "grub backup: $backup"
fi

params=("isolcpus=domain,managed_irq,$FAULT_CPUS" "nohz_full=$FAULT_CPUS" "rcu_nocbs=$FAULT_CPUS" "irqaffinity=$SAFE_CPUS")
param_line="${params[*]}"

python3 - "$param_line" <<'PY'
import re, sys
path = "/etc/default/grub"
params = sys.argv[1]
# Older faultlab installs omitted the scheduler-domain flag. Accept that exact
# line as an in-place upgrade; anything else is still treated as foreign.
legacy = params.replace("isolcpus=domain,", "isolcpus=", 1)
text = open(path).read()
match = re.search(r'(?m)^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"', text)
if match:
    current = match.group(1).strip()
    if "isolcpus=" in current or "nohz_full=" in current:
        if params in current:
            print("grub: faultlab parameters already present, leaving file unchanged")
        elif legacy in current:
            value = current.replace(legacy, params, 1)
            text = text[:match.start(1)] + value + text[match.end(1):]
            open(path, "w").write(text)
            print("grub: upgraded faultlab parameters (added domain isolation)")
        else:
            sys.exit("grub: existing isolation parameters differ; run rollback.sh before changing the faulty core")
    else:
        value = (current + " " + params).strip()
        text = text[:match.start(1)] + value + text[match.end(1):]
        open(path, "w").write(text)
        print("grub: parameters appended to GRUB_CMDLINE_LINUX_DEFAULT")
else:
    text = text.rstrip("\n") + '\nGRUB_CMDLINE_LINUX_DEFAULT="' + params + '"\n'
    open(path, "w").write(text)
    print("grub: GRUB_CMDLINE_LINUX_DEFAULT added")
PY

if command -v update-grub >/dev/null 2>&1; then
    update-grub
elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg
else
    echo "apply.sh: warning: neither update-grub nor grub-mkconfig found; regenerate grub manually" >&2
fi

install -d /etc/faultlab /usr/local/sbin /usr/local/lib \
    /etc/systemd/system/system.slice.d /etc/systemd/system/user.slice.d \
    /etc/systemd/system/faultlab.slice.d
install -d -m 0750 /var/log/faultlab
if getent group adm >/dev/null 2>&1; then chgrp adm /var/log/faultlab; fi

install -m 0644 "$here/systemd/faultlab.slice" /etc/systemd/system/faultlab.slice
install -m 0644 "$here/systemd/faultlab-retire.service" /etc/systemd/system/faultlab-retire.service
cat >/etc/systemd/system/faultlab.slice.d/50-faultlab-cpus.conf <<EOF
[Slice]
AllowedCPUs=$fault_spaces
EOF
cat >/etc/systemd/system/system.slice.d/50-faultlab-allowedcpus.conf <<EOF
[Slice]
AllowedCPUs=$safe_spaces
EOF
cat >/etc/systemd/system/user.slice.d/50-faultlab-allowedcpus.conf <<EOF
[Slice]
AllowedCPUs=$safe_spaces
EOF

lib=/usr/local/lib/fault-injection-rig
rm -rf "$lib"
install -d "$lib"
cp -a "$here"/bin "$here"/lib "$here"/tools "$here"/crypto "$here"/README.md "$lib"/
rm -rf "$lib"/bin/__pycache__ "$lib"/tools/__pycache__ "$lib"/crypto/__pycache__
chown -R root:root "$lib"
find "$lib" -type d -exec chmod 0755 {} +
find "$lib" -type f -exec chmod 0644 {} +
find "$lib/bin" -type f -exec chmod 0755 {} +
for tool in "$lib"/bin/*; do
    [[ -f $tool ]] || continue
    [[ ${tool##*/} == faultlab-usb-restore ]] && continue
    ln -sf "$tool" "/usr/local/sbin/$(basename "$tool")"
done
install -m 0755 -o root -g root "$here/bin/faultlab-usb-restore" /usr/local/sbin/faultlab-usb-restore

cat >/etc/faultlab/config <<EOF
# Generated by faultlab apply.sh on $(date -Is)
FAULTLAB_HOME=$lib
FAULT_CPU=$fault_cpu
CONTROL_CPU=$control_cpu
FAULT_CPUS=$FAULT_CPUS
CONTROL_CPUS=$CONTROL_CPUS
SAFE_CPUS=$SAFE_CPUS
EOF
chmod 0644 /etc/faultlab/config

# First install starts in RETIRED. Re-runs preserve the live session; the boot
# service always retires on the next boot.
if [[ ! -e /etc/faultlab/mode ]]; then
    echo retired >/etc/faultlab/mode
fi
systemctl daemon-reload
systemctl enable faultlab-retire.service

echo
echo "installed. Reboot to activate domain isolation and the boot-time retire policy."
echo "LAB is session-only: after reboot run 'sudo faultlab-mode lab' for each session."
printf 'current session mode: %s; next boot: retired\n' "$(cat /etc/faultlab/mode 2>/dev/null || echo unset)"
echo "After reboot: sudo faultlab-mode status && sudo faultlab-verify"
