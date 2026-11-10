# Faulty physical core 2 — classification and isolation plan

## 0. Reference machine (example)

| Item | Value |
|---|---|
| CPU | AMD Ryzen 5 3600X (Zen 2), 6C/12T, SMT active |
| Physical core 2 | logical CPUs **2 and 8** (`thread_siblings_list = 2,8`) |
| Kernel | 6.8.0-138-generic, Ubuntu 22.04, systemd 249, cgroup v2 |
| Microcode | 0x8701033, `acpi-cpufreq`, boost on |
| Current cmdline | no `isolcpus` / `nohz_full` / `rcu_nocbs` |
| RAS | `rasdaemon` active, MCE decoding on; no MCE logged so far |
| Privilege | `sudo` needs a password → apply/rollback must be run by the user |

**Lowest possible level:** CPU hotplug offline is the only layer that stops
*everything*, including per-CPU kernel threads (`ksoftirqd/2`, `kworker/2:*`,
`migration/2`). `isolcpus` only removes a CPU from load balancing; those
threads still run there. So the design has two modes:

- **RETIRED (default):** CPUs 2 and 8 offlined at boot. Nothing runs there.
- **LAB (opt-in):** CPUs online, scheduler/IRQ/RCU isolation plus a cgroup
  fence. Only `faultlab.slice` (root) can place work there.

## 1. Layer model

| Layer | Mechanism | What it stops |
|---|---|---|
| Scheduler | `isolcpus=managed_irq,2,8` | automatic user-task placement |
| Ticks / RCU | `nohz_full=2,8` `rcu_nocbs=2,8` | timer ticks, RCU callbacks |
| Interrupts | `irqaffinity=0-1,3-7,9-11` | device IRQs |
| Cgroup | `AllowedCPUs` on `system.slice`/`user.slice`; `faultlab.slice` = 2,8 | every service and login session |
| Hotplug | `faultlab-retire.service` | everything, incl. per-CPU kthreads |

Kernel threads and PID 1 are not cgroup-fenceable; only the RETIRED mode
removes them from core 2.

## 2. Phase 1 — classify the fault (before trusting it)

Run with CPUs online (`sudo faultlab-mode lab`), one change at a time.

1. **Baseline:** `sudo ras-mc-ctl --summary` and `sudo ras-mc-ctl --errors`
   (the DB is created on first root query).
2. **Load soak, faulty core:** `sudo faultlab stress-ng --cpu 2 --cpu-method all --timeout 300 --metrics-brief`
3. **Load soak, control core:** `taskset -c 3,9 stress-ng --cpu 2 --cpu-method all --timeout 300 --metrics-brief`
4. **Thermal:** `sensors` and `sudo turbostat --cpu 2,8 --interval 5 --show CPU,Busy%,Bzy_MHz,PkgTmp,PkgWatt` during both soaks.
5. **Error delta:** repeat the `ras-mc-ctl` queries and `journalctl -k | grep -iE 'mce|machine check|hardware error'`.
6. **Silent-corruption probe:** from the repository root,
   `sudo faultlab-ab --runs 5 -- python3 tools/sdc_probe.py`
   (`faultlab-ab` runs the faulty and control branches itself; do not wrap it in `faultlab`).
7. Optional gold standard: `mprime -t` pinned to 2,8 (not packaged; fetch from mersenne.org).

### Decision matrix

| Observation | Classification | Action |
|---|---|---|
| No errors, identical outputs | not reproducible | keep as lab, low priority |
| Corrected errors (CE) in MCA banks, outputs match | correctable | lab-safe; watch the rate |
| Uncorrected error (UE) / panic / MCE kill | uncorrectable | RETIRED permanently |
| Output mismatch, control clean | silent data corruption | never in trusted path; lab-only |
| High temp / throttling on 2,8 only | thermal | fix cooling first, re-test |
| CE rate rising across sessions | degrading package | retire, stop lab use |

Record every session in `sessions.log`: date, test, CE/UE before/after, max temp.

## 3. Phase 2 — apply isolation

`sudo ./apply.sh` (then reboot). It:

- backs up `/etc/default/grub` and appends
  `isolcpus=managed_irq,2,8 nohz_full=2,8 rcu_nocbs=2,8 irqaffinity=0-1,3-7,9-11`
  (Ubuntu's `/etc/default/grub` here has no `grub.d` include, so a drop-in will not work);
- installs `faultlab.slice` (AllowedCPUs=2 8) and `faultlab-retire.service`;
- restricts `system.slice` and `user.slice` to `0-1 3-7 9-11`;
- sets mode `retired`, enables the retire service, installs the CLI tools.

Until the reboot, the cgroup fence is not active (the drop-ins only apply when
the slices are next started), so a pre-reboot `lab` session is suitable for
classification only, not for fenced work.

Consequences to expect:

- `nproc` becomes 10 after the retire service runs.
- Docker/containers inherit `system.slice` and therefore cannot use 2,8.
  To run a container on the lab core: `sudo faultlab docker run ...`.
- The user session cannot reach 2,8 by design; only root via `faultlab.slice`.

## 4. Phase 3 — verify

`sudo faultlab-verify` checks: cmdline tokens, `isolated`/`nohz_full` sysfs,
effective cpusets, online state, IRQ deltas on 2,8, and any task sampled there.
Expected: IRQ delta 0 and no user tasks; per-CPU kthreads are reported
separately and only disappear in RETIRED mode.

Also run `sudo faultlab-mode status`.

## 5. Phase 4 — QA and security test programme

1. **Exclusion proof:** full-system `stress-ng --all` on allowed CPUs; no task
   or IRQ should appear on 2,8.
2. **Silent corruption:** checksums, Merkle trees, replica divergence,
   dedup, transactional integrity. Use `faultlab-ab` as the oracle.
3. **Crypto fault attack (DFA):** generate a throwaway key on the control core,
   sign on the faulty core, verify on the control core:
   ```
   cd fault-injection-rig
   sudo taskset -c 3,9 faultlab-crypto keygen
   sudo faultlab faultlab-crypto sign --out /tmp/dfa.jsonl --iterations 2000
   sudo taskset -c 3,9 faultlab-crypto verify --in /tmp/dfa.jsonl
   ```
   A recovered factor is a critical finding (Bellcore attack class).
4. **Failover:** `systemd` `OnFailure=`, watchdog, health checks — does a
   service on a degrading core get moved or restarted?
5. **Hotplug races:** offline/online CPU 8 under load; check affinity migration,
   thread pools, per-CPU counters.
6. **Telemetry/SIEM:** pipe real `rasdaemon` CE records into the QA Sentinel
   pipeline; validate thresholds, dedup and escalation against genuine events.
7. **Microcode/AGESA regression:** re-run phases 1 and 3 after updates.

## 6. Guardrails

- Never generate keys, sign, hash passwords, seed RNG, or run TLS on 2,8.
- Test keys and disposable data only; never the only copy of evidence.
- One UE, or a rising CE trend, ends lab use immediately.
- Do not run lab workloads while doing trusted work on the same machine.
- Keep the control core (3,9) in every A/B so software bugs are distinguishable.

## 7. Rollback

`sudo ./rollback.sh` restores the newest
`/etc/default/grub.faultlab.*` backup, removes the units, runs `update-grub`.
Then `sudo faultlab-mode retired` or reboot.

## 8. QA Sentinels and QA SIEM integration

`faultlab-ab` appends one JSON object per verdict to
`/var/log/faultlab/ab.jsonl` (0640 root:adm). QA Sentinels consumes new lines
from a persisted byte cursor and emits `core2.ab.divergence` (critical),
`core2.ab.hw_suspect` and `core2.ab.control_unstable` (warning). Each cycle it
also checks the isolation policy and emits `core2.retired.online`,
`core2.isolation.unfenced`, `core2.isolation.missing`, `core2.lab.*`,
`core2.irq.affinity` and `core2.topology.*`.

QA SIEM carries matching thresholds in `config/siem.rules.json`; apply them
with `sudo scripts/sync-rules.sh` in the QA SIEM repository. MCE/EDAC events
keep their existing `kernel.hardware` and `hardware.edac.*` rules, so there is
no duplicate core-2 error trigger.
