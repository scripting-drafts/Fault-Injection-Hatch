# Faulty physical core — classification and isolation plan

## 0. Topology model

The rig never assumes fixed CPU numbers. `apply.sh --fault-cpu N` takes any
logical CPU on the bad physical core and derives the core's sibling threads
from `/sys/devices/system/cpu/cpuN/topology/thread_siblings_list`. The control
core is another physical core, auto-selected from the same package and SMT
width when possible, or supplied with `--control-cpu M`. The resulting seeds
are stored in `/etc/faultlab/config` (`FAULT_CPU`, `CONTROL_CPU`); every tool
re-derives `FAULT_CPUS`/`CONTROL_CPUS` from sysfs at runtime.

Reference example used during development (values are illustrative):

| Item | Value |
|---|---|
| CPU | AMD Ryzen 5 3600X (Zen 2), 6C/12T, SMT active |
| Faulty core | CPUs 2 and 8 (`thread_siblings_list = 2,8`) |
| Control core | CPUs 3 and 9 (auto-selected) |
| Kernel | 6.18, systemd, cgroup v2 |

**Lowest possible level:** CPU hotplug offline is the only layer that stops
*everything*, including per-CPU kernel threads (`ksoftirqd/N`, `kworker/N:*`,
`migration/N`). `isolcpus` only removes a CPU from load balancing; those
threads still run there. So the design has two modes:

- **RETIRED (default):** every CPU on the faulty core is offlined at boot.
  Nothing runs there.
- **LAB (opt-in):** those CPUs are online, scheduler/IRQ/RCU isolation plus a
  cgroup fence. Only `faultlab.slice` (root) can place work there.

## 1. Layer model

| Layer | Mechanism | What it stops |
|---|---|---|
| Scheduler | `isolcpus=managed_irq,${FAULT_CPUS}` | automatic user-task placement |
| Ticks / RCU | `nohz_full=${FAULT_CPUS}` `rcu_nocbs=${FAULT_CPUS}` | timer ticks, RCU callbacks |
| Interrupts | `irqaffinity=${SAFE_CPUS}` | device IRQs |
| Cgroup | `AllowedCPUs` on `system.slice`/`user.slice`; `faultlab.slice` = faulty CPUs | every service and login session |
| Hotplug | `faultlab-retire.service` → `faultlab-retire` | everything, incl. per-CPU kthreads |

Kernel threads and PID 1 are not cgroup-fenceable; only RETIRED mode removes
them from the faulty core.

## 2. Phase 1 — classify the fault (before trusting it)

Run with the core online (`sudo faultlab-mode lab`), one change at a time.
`faultlab-classify` automates the sequence below; `faultlab-mode status` prints
the current CPU sets.

1. **Baseline:** `sudo ras-mc-ctl --summary` and `sudo ras-mc-ctl --errors`.
2. **Load soak, faulty core:** `sudo faultlab stress-ng --cpu $WORKERS --cpu-method all --timeout 300 --metrics-brief`
3. **Load soak, control core:** `taskset -c "${CONTROL_CPUS}" stress-ng --cpu $WORKERS --cpu-method all --timeout 300 --metrics-brief`
4. **Thermal:** `sensors` and `sudo turbostat --cpu ${FAULT_CPUS} --interval 5 --show CPU,Busy%,Bzy_MHz,PkgTmp,PkgWatt` during both soaks.
5. **Error delta:** repeat the `ras-mc-ctl` queries and `journalctl -k | grep -iE 'mce|machine check|hardware error'`.
6. **Silent-corruption probe:** `sudo faultlab-ab --runs 5 -- python3 tools/sdc_probe.py`
   (`faultlab-ab` runs both branches itself; do not wrap it in `faultlab`).
7. Optional gold standard: `mprime -t` pinned to the faulty CPUs (fetch it yourself).

### Decision matrix

| Observation | Classification | Action |
|---|---|---|
| No errors, identical outputs | not reproducible | keep as lab, low priority |
| Corrected errors (CE) in MCA banks, outputs match | correctable | lab-safe; watch the rate |
| Uncorrected error (UE) / panic / MCE kill | uncorrectable | RETIRED permanently |
| Output mismatch, control clean | silent data corruption | never in trusted path; lab-only |
| High temp / throttling on faulty core only | thermal | fix cooling first, re-test |
| CE rate rising across sessions | degrading package | retire, stop lab use |

Record every session in the session log: date, test, CE/UE before/after, max temp.

## 3. Phase 2 — apply isolation

`sudo ./apply.sh --fault-cpu N [--control-cpu M]` (then reboot). It:

- detects sibling threads and writes `/etc/faultlab/config`;
- backs up `/etc/default/grub` and adds
  `isolcpus=managed_irq,${FAULT_CPUS} nohz_full=${FAULT_CPUS} rcu_nocbs=${FAULT_CPUS} irqaffinity=${SAFE_CPUS}`;
- installs `faultlab.slice` with an `AllowedCPUs=${FAULT_CPUS}` drop-in;
- restricts `system.slice` and `user.slice` to `SAFE_CPUS`;
- sets mode `retired`, enables `faultlab-retire.service`, installs the CLI tools.

Until the reboot, the cgroup fence is not active (the drop-ins only apply when
the slices are next started), so a pre-reboot `lab` session is suitable for
classification only, not for fenced work.

Consequences to expect:

- `nproc` drops by the number of faulty-core threads after the retire unit runs.
- Docker/containers inherit `system.slice` and cannot use the faulty core.
  To run a container on the lab core: `sudo faultlab docker run ...`.
- The user session cannot reach the faulty core; only root via `faultlab.slice`.

## 4. Phase 3 — verify

`sudo faultlab-verify` checks: cmdline tokens, `isolated`/`nohz_full` sysfs,
effective cpusets, online state, IRQ deltas on the faulty CPUs, control-core
availability, and any task sampled there. Expected: IRQ delta 0 and no user
tasks; per-CPU kthreads are reported separately and only disappear in RETIRED
mode.

Also run `sudo faultlab-mode status`.

## 5. Phase 4 — QA and security test programme

1. **Exclusion proof:** full-system `stress-ng --all` on allowed CPUs; no task
   or IRQ should appear on the faulty core.
2. **Silent corruption:** checksums, Merkle trees, replica divergence,
   dedup, transactional integrity. Use `faultlab-ab` as the oracle.
3. **Crypto fault attack (DFA):** generate a throwaway key on the control core,
   sign on the faulty core, verify on the control core:
   ```
   sudo taskset -c "${CONTROL_CPUS}" faultlab-crypto keygen
   sudo faultlab faultlab-crypto sign --out /tmp/dfa.jsonl --iterations 2000
   sudo taskset -c "${CONTROL_CPUS}" faultlab-crypto verify --in /tmp/dfa.jsonl
   ```
   A recovered factor is a critical finding (Bellcore attack class).
4. **Failover:** systemd `OnFailure=`, watchdog, health checks — does a
   service on a degrading core get moved or restarted?
5. **Hotplug races:** offline/online a faulty-core sibling under load; check
   affinity migration, thread pools, per-CPU counters.
6. **Telemetry/SIEM:** pipe real `rasdaemon` CE records into the QA Sentinel
   pipeline; validate thresholds, dedup and escalation against genuine events.
7. **Microcode/AGESA regression:** re-run phases 1 and 3 after updates.

## 6. Guardrails

- Never generate keys, sign, hash passwords, seed RNG, or run TLS on the faulty core.
- Test keys and disposable data only; never the only copy of evidence.
- One UE, or a rising CE trend, ends lab use immediately.
- Do not run lab workloads while doing trusted work on the same machine.
- Keep the configured control core in every A/B so software bugs are distinguishable.

## 7. Rollback

`sudo ./rollback.sh` restores the newest `/etc/default/grub.faultlab.*` backup,
brings the faulty CPUs online, removes the units and drop-ins, and runs the
GRUB generator. Then `sudo faultlab-mode retired` or reboot.

### Rescue USB

A UEFI FAT32 USB can carry GRUB plus a modified initramfs whose `init-bottom`
hook restores the newest GRUB backup, removes the faultlab units, regenerates
`grub.cfg`, and then boots the installed system. The USB entry uses the
installed kernel but its own initramfs, so it works even when the host
initramfs is unusable. Rebuild it after a kernel or root-UUID change.
`apply.sh` installs a host-side fallback at
`/usr/local/sbin/faultlab-usb-restore`; `rollback.sh` leaves that file in place
so the rescue USB entry keeps working.

## 8. QA Sentinels and QA SIEM integration

`faultlab-ab` appends one JSON object per verdict to
`/var/log/faultlab/ab.jsonl` (0640 root:adm). The record carries
`faulty_cpus`/`control_cpus` from the live configuration, so consumers must not
assume fixed CPU numbers. QA Sentinels consumes new lines from a persisted byte
cursor and emits `ab.divergence` (critical), `ab.hw_suspect` and
`ab.control_unstable` (warning). Each cycle it also checks the isolation policy
and emits `retired.online`, `isolation.unfenced`, `isolation.missing`,
`lab.*`, `irq.affinity` and `topology.*` events.

QA SIEM carries matching thresholds in `config/siem.rules.json`; apply them
with `sudo scripts/sync-rules.sh` in the QA SIEM repository. MCE/EDAC events
keep their existing `kernel.hardware` and `hardware.edac.*` rules, so there is
no duplicate error trigger.
