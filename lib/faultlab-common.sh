#!/usr/bin/env bash
# Shared configuration and CPU-topology helpers for the fault-injection rig.
# Sourced by the tools; never executed directly. Requires bash.

: "${FAULTLAB_CONF:=/etc/faultlab/config}"

fl_warn() { printf '%s: %s\n' "${0##*/}" "$*" >&2; }
fl_die() { fl_warn "$*"; exit 1; }

# Load the install-time config (FAULTLAB_HOME, FAULT_CPU, CONTROL_CPU, ...).
fl_load_config() {
    [[ -r $FAULTLAB_CONF ]] || return 0
    # shellcheck disable=SC1090
    . "$FAULTLAB_CONF"
}

fl_cpu_exists() {
    [[ ${1:-} =~ ^[0-9]+$ ]] && [[ -d /sys/devices/system/cpu/cpu$1 ]]
}

# Expand a CPU list ("0-3,8") into one CPU number per line.
fl_expand_cpus() {
    local list=${1:-} part a b i
    local IFS=$' \t,'
    for part in $list; do
        [[ -z $part ]] && continue
        if [[ $part =~ ^([0-9]+)-([0-9]+)$ ]]; then
            a=${BASH_REMATCH[1]}
            b=${BASH_REMATCH[2]}
            ((a <= b)) || continue
            for ((i = a; i <= b; i++)); do printf '%s\n' "$i"; done
        elif [[ $part =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$part"
        fi
    done
}

# Normalize any CPU list to sorted, deduplicated ranges ("0-1,3-7").
fl_normalize_cpus() {
    local sorted
    sorted=$(fl_expand_cpus "${1:-}" | sort -n -u)
    [[ -n $sorted ]] || return 0
    awk '
        { c[NR] = $1 }
        END {
            if (NR == 0) exit
            start = prev = c[1]
            out = ""
            for (i = 2; i <= NR; i++) {
                if (c[i] == prev + 1) { prev = c[i]; continue }
                out = out (out ? "," : "") (start == prev ? start : start "-" prev)
                start = prev = c[i]
            }
            out = out (out ? "," : "") (start == prev ? start : start "-" prev)
            print out
        }' <<<"$sorted"
}

# Space-separated form used by systemd properties.
fl_cpus_spaces() {
    fl_expand_cpus "${1:-}" | sort -n -u | tr '\n' ' ' | sed 's/ *$//'
}

fl_cpu_count() {
    fl_expand_cpus "${1:-}" | wc -l | tr -d ' '
}

# fl_list_has LIST CPU
fl_list_has() {
    local c
    for c in $(fl_expand_cpus "${1:-}"); do
        [[ $c == "${2:-}" ]] && return 0
    done
    return 1
}

fl_cpu_attr() { # CPU ATTR
    cat "/sys/devices/system/cpu/cpu$1/topology/$2" 2>/dev/null
}

# Sibling threads of a logical CPU (a physical core can expose several).
# If the CPU is offline its topology file can disappear; try to find the
# sibling set from any online CPU before falling back to the CPU alone.
fl_siblings() {
    local cpu=$1 f=/sys/devices/system/cpu/cpu$1/topology/thread_siblings_list
    local other list
    if [[ -r $f ]]; then
        fl_normalize_cpus "$(<"$f")"
        return 0
    fi
    for other in /sys/devices/system/cpu/cpu*/topology/thread_siblings_list; do
        [[ -r $other ]] || continue
        list=$(<"$other")
        if fl_list_has "$list" "$cpu"; then
            fl_normalize_cpus "$list"
            return 0
        fi
    done
    printf '%s\n' "$cpu"
}

# Complement of EXCLUDE among possible CPUs.
fl_complement() {
    local exclude=$1 c out=()
    for c in $(fl_expand_cpus "$(< /sys/devices/system/cpu/possible)"); do
        fl_list_has "$exclude" "$c" || out+=("$c")
    done
    ((${#out[@]})) || return 0
    local IFS=,
    fl_normalize_cpus "${out[*]}"
}

# Choose one CPU on a healthy physical core. Prefers the same package and the
# same SMT width; avoids the boot core when an alternative exists.
fl_pick_control_cpu() {
    local exclude=$1 c sib pkg fpkg fn n boot_sib first
    local -a same=() same_pkg=() any=() boot=()
    first=$(fl_expand_cpus "$exclude")
    first=${first%%$'\n'*}
    fpkg=$(fl_cpu_attr "$first" physical_package_id)
    fn=$(fl_cpu_count "$exclude")
    boot_sib=$(fl_siblings 0)
    for c in $(fl_expand_cpus "$(< /sys/devices/system/cpu/possible)"); do
        fl_list_has "$exclude" "$c" && continue
        sib=$(fl_siblings "$c")
        [[ ${sib%%,*} == "$c" ]] || continue # one representative per core
        pkg=$(fl_cpu_attr "$c" physical_package_id)
        n=$(fl_cpu_count "$sib")
        if [[ $sib == "$boot_sib" ]]; then
            boot+=("$c")
            continue
        fi
        any+=("$c")
        [[ $pkg == "$fpkg" ]] && same_pkg+=("$c")
        [[ $pkg == "$fpkg" && $n == "$fn" ]] && same+=("$c")
    done
    if ((${#same[@]})); then printf '%s\n' "${same[0]}"
    elif ((${#same_pkg[@]})); then printf '%s\n' "${same_pkg[0]}"
    elif ((${#any[@]})); then printf '%s\n' "${any[0]}"
    elif ((${#boot[@]})); then printf '%s\n' "${boot[0]}"
    else return 1
    fi
}

# Populate FAULT_CPUS, CONTROL_CPUS, CONTROL_CPU and SAFE_CPUS from the seeds.
fl_load_topology() {
    [[ -n ${FAULT_CPU:-} ]] ||
        fl_die "FAULT_CPU is not configured; run apply.sh or set it in $FAULTLAB_CONF"
    fl_cpu_exists "$FAULT_CPU" || fl_die "FAULT_CPU=$FAULT_CPU does not exist"
    local configured_fault=${FAULT_CPUS:-}
    local configured_control=${CONTROL_CPUS:-}
    local fault_topology=/sys/devices/system/cpu/cpu$FAULT_CPU/topology/thread_siblings_list
    FAULT_CPUS=$(fl_siblings "$FAULT_CPU")
    # Offline CPUs lose their topology directory. Trust the install-time list
    # when the seed CPU has no topology file of its own.
    if [[ ! -r $fault_topology && -n $configured_fault ]] &&
        fl_list_has "$configured_fault" "$FAULT_CPU"; then
        FAULT_CPUS=$(fl_normalize_cpus "$configured_fault")
    fi

    if [[ -n ${CONTROL_CPU:-} ]]; then
        if fl_cpu_exists "$CONTROL_CPU"; then
            CONTROL_CPUS=$(fl_siblings "$CONTROL_CPU")
            if [[ ! -r /sys/devices/system/cpu/cpu$CONTROL_CPU/topology/thread_siblings_list &&
                -n $configured_control ]] &&
                fl_list_has "$configured_control" "$CONTROL_CPU"; then
                CONTROL_CPUS=$(fl_normalize_cpus "$configured_control")
            fi
        else
            fl_warn "CONTROL_CPU=$CONTROL_CPU does not exist; auto-selecting one"
            CONTROL_CPU=""
        fi
    fi
    if [[ -z ${CONTROL_CPU:-} ]]; then
        CONTROL_CPU=$(fl_pick_control_cpu "$FAULT_CPUS") ||
            fl_die "no healthy control core is available"
        CONTROL_CPUS=$(fl_siblings "$CONTROL_CPU")
    fi

    local c
    for c in $(fl_expand_cpus "$CONTROL_CPUS"); do
        if fl_list_has "$FAULT_CPUS" "$c"; then
            fl_warn "control core ($CONTROL_CPUS) overlaps the faulty core; auto-selecting one"
            CONTROL_CPU=$(fl_pick_control_cpu "$FAULT_CPUS") ||
                fl_die "no healthy control core is available"
            CONTROL_CPUS=$(fl_siblings "$CONTROL_CPU")
            break
        fi
    done
    [[ -n $FAULT_CPUS ]] || fl_die "could not determine the faulty core's CPUs"
    SAFE_CPUS=$(fl_complement "$FAULT_CPUS")
    [[ -n $SAFE_CPUS ]] || fl_die "could not determine the safe CPU set (is /sys mounted?)"
}

fl_print_topology() {
    printf 'fault cpu:     %s (core CPUs %s)\n' "$FAULT_CPU" "$FAULT_CPUS"
    printf 'control cpu:   %s (core CPUs %s)\n' "$CONTROL_CPU" "$CONTROL_CPUS"
    printf 'safe cpus:     %s\n' "$SAFE_CPUS"
}

# Set one CPU online/offline with retries. Returns 1 on failure.
fl_set_cpu_online() { # CPU STATE [TRIES]
    local cpu=$1 state=$2 tries=${3:-5} i
    local f=/sys/devices/system/cpu/cpu$cpu/online
    if [[ ! -e $f ]]; then
        [[ $state == 1 ]] && return 0
        fl_warn "CPU$cpu has no hotplug control (boot CPU)"
        return 1
    fi
    [[ $(<"$f") == "$state" ]] && return 0
    for ((i = 0; i < tries; i++)); do
        echo "$state" >"$f" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

fl_online_fault_cpus() {
    local rc=0 c
    for c in $(fl_expand_cpus "$FAULT_CPUS" | sort -n); do
        fl_set_cpu_online "$c" 1 3 || { fl_warn "could not online CPU$c"; rc=1; }
    done
    return "$rc"
}

fl_offline_fault_cpus() {
    local rc=0 c
    for c in $(fl_expand_cpus "$FAULT_CPUS" | sort -rn); do
        fl_set_cpu_online "$c" 0 5 || { fl_warn "could not offline CPU$c (busy?)"; rc=1; }
    done
    return "$rc"
}

fl_fault_cpus_online() {
    local c
    for c in $(fl_expand_cpus "$FAULT_CPUS"); do
        [[ $(cat /sys/devices/system/cpu/cpu$c/online 2>/dev/null || echo 1) == 1 ]] ||
            return 1
    done
    return 0
}
