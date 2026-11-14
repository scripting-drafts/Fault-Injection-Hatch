# Fault Injection Hatch — extended guide

> **Reference-machine walkthrough.** This guide predates generic topology detection.
> The current `apply.sh` takes `--fault-cpu N` and auto-selects a control core; the
> literal CPU numbers below are examples from the original development machine.
> See `docs/fault-core-plan.md` for the current generic model.

A Linux CPU-isolation and fault-characterisation toolkit for investigating a suspected degrading processor core.

The rig is designed around a specific reference system: an **AMD Ryzen 5 3600X (6 cores / 12 threads)** where physical core 2 maps to logical CPUs **2 and 8**. It provides a conservative retired mode, an explicitly enabled lab mode, controlled A/B workload execution, isolation checks, and experimental integrity/cryptographic fault probes.

> **Experimental hardware-lab software — not a production reliability or security control.**
> The default policy is to keep the suspected core offline. Do not use this project on a machine you depend on until you have reviewed the scripts, verified the CPU topology, backed up important data, and prepared a recovery path.

## What it does

The project separates two operating modes:

| Mode | Behaviour | Intended use |
|---|---|---|
| **RETIRED** (default) | Offlines the configured fault CPUs (`FAULT_CPUS`) on every boot | Keep the suspected physical core out of normal operation |
| **LAB** (session-only) | Brings the configured fault CPUs online while restricting normal services and user sessions to the other CPUs | Run controlled diagnostic workloads on the suspected core |

In addition to CPU hotplug, the boot configuration requests several layers of isolation:

- **Scheduler:** `isolcpus=domain,managed_irq,$FAULT_CPUS` (reference example: `2,8`)
- **Tick and RCU:** `nohz_full=$FAULT_CPUS` and `rcu_nocbs=$FAULT_CPUS`
- **Interrupt affinity:** `irqaffinity=$SAFE_CPUS`
- **Service and session fencing:** systemd slice `AllowedCPUs` restrictions
- **Lab execution:** `faultlab.slice` is allowed to use the configured fault CPUs

CPU hotplug is the strongest retirement mechanism in this design: unlike scheduler isolation, taking a CPU offline also removes its per-CPU kernel threads. In LAB mode, isolation is not absolute; kernel threads and some kernel activity are not controlled by ordinary cgroup placement.

## Repository layout

| Path | Purpose |
|---|---|
| `apply.sh` | Installs the tools, systemd units and CPU-affinity configuration; updates GRUB |
| `rollback.sh` | Removes installed components, restores a clean GRUB backup, strips isolation parameters and brings the configured fault CPUs online |
| `bin/faultlab` | Runs a command as root inside the dedicated lab slice, pinned to the configured fault CPUs |
| `bin/faultlab-mode` | Switches between `retired`, `lab` and `status` |
| `bin/faultlab-verify` | Checks boot parameters, cpusets, task placement and interrupt activity |
| `bin/faultlab-classify` | Runs the baseline, load-soak, telemetry and A/B classification sequence |
| `bin/faultlab-ab` | Compares a command on the suspected core with a control core |
| `bin/faultlab-crypto` | Dispatches the experimental RSA-CRT differential-fault test |
| `bin/faultlab-watch` | Helper for watching the lab state |
| `bin/faultlab-retire` | Compatibility helper for `faultlab-mode retired`; the boot unit uses the same mode switch |
| `bin/faultlab-usb-restore` | Host-side fallback used by the rescue USB |
| `lib/faultlab-common.sh` | Shared config, CPU-list and topology helpers |
| `examples/rescue-usb/` | UEFI rescue USB builder and initramfs hook |
| `crypto/fault_crypto_test.py` | Throwaway-key RSA-CRT fault probe |
| `tools/sdc_probe.py` | Deterministic arithmetic/checksum probe |
| `tools/ab_record.py` | Writes machine-readable A/B verdict records |
| `docs/fault-core-plan.md` | Detailed classification, isolation, QA and integration plan |
| `systemd/` | systemd slice, CPU restrictions and retirement service |

## Before you install

### 1. Confirm the CPU topology

`apply.sh --fault-cpu N` derives the target core's sibling threads from sysfs and auto-selects a healthy control core. On the reference machine the faulty core is CPUs **2 and 8** and the control core is **3 and 9**. Check the topology first:

```bash
lscpu -e=CPU,CORE,SOCKET,NODE,ONLINE
cat /sys/devices/system/cpu/cpu2/topology/thread_siblings_list
```

For the reference Ryzen 5 3600X, the expected sibling list for the target core is `2,8`. The control workload in the supplied plan uses CPUs `3,9`.

If your topology differs, the CPU lists in the scripts, systemd units and GRUB parameters must be adapted consistently before installation.

### 2. Review the host-level changes

The installer requires root and modifies system configuration. In particular, `apply.sh`:

- backs up `/etc/default/grub` to `/etc/default/grub.faultlab.TIMESTAMP`;
- edits `GRUB_CMDLINE_LINUX_DEFAULT` and runs `update-grub`;
- installs files under `/etc/systemd/system`, `/etc/faultlab` and `/usr/local`;
- creates `/var/log/faultlab`;
- enables the boot-time retirement service.

**Inspect `apply.sh` before running it.** It appends the isolation parameters to `GRUB_CMDLINE_LINUX_DEFAULT`, preserves existing kernel arguments, and refuses to overwrite a different `isolcpus` configuration. Keep a known-good boot entry or recovery medium available.

### 3. Check the environment

The plan targets Ubuntu with systemd and cgroup v2. The diagnostic workflow expects tools such as:

- `stress-ng`
- `rasdaemon` / `ras-mc-ctl`
- `lm-sensors` (`sensors`)
- `turbostat` (for the optional per-CPU thermal/frequency inspection)
- Python 3 and the Python `cryptography` package (for the RSA-CRT probe)

Install only the tools needed for the tests you intend to run. Some optional utilities, such as `mprime`, are not included in this repository.

## Installation

Clone the repository and inspect the scripts:

```bash
git clone https://github.com/scripting-drafts/Fault-Injection-Hatch.git
cd Fault-Injection-Hatch

less apply.sh
less rollback.sh
less docs/fault-core-plan.md
```

When the topology and host changes have been checked:

```bash
sudo ./apply.sh --fault-cpu N
sudo reboot
```

The installer configures **RETIRED** as the default mode. The boot service retires the core on every boot; **LAB is session-only** and must be re-enabled after each reboot. After reboot, confirm the state:

```bash
sudo faultlab-mode status
sudo faultlab-verify
```

Do not proceed to lab testing unless the machine's topology and the verification output match the intended configuration. A successful command exit is not, by itself, proof that the hardware is healthy or that every source of kernel activity has been eliminated.

## Operating modes

### RETIRED — normal/default operation

```bash
sudo faultlab-mode retired
sudo faultlab-mode status
```

This offlines the configured fault CPUs (reference example: 2 and 8). The boot-time systemd service applies this policy on every boot, regardless of the mode left by the previous session, and runs before user sessions start.

### LAB — session-only diagnostic operation

```bash
sudo faultlab-mode lab
sudo faultlab-mode status
sudo faultlab-verify
```

LAB brings the configured fault CPUs online. Normal system and user slices remain restricted to the non-target CPUs; commands launched through `faultlab` are placed in the dedicated lab slice. A reboot retires the core again; re-run `sudo faultlab-mode lab` for each session.

Run a diagnostic command on the target core like this:

```bash
sudo faultlab stress-ng --cpu 2 --cpu-method all --timeout 60 --metrics-brief
```

Return to the safer state when the test is complete:

```bash
sudo faultlab-mode retired
sudo faultlab-verify
```

**Do not run lab workloads while doing trusted work on the same machine.** The LAB mode is for controlled experiments, not for normal application workloads.

## Typical diagnostic workflow

The full procedure and decision matrix are in [`docs/fault-core-plan.md`](docs/fault-core-plan.md). The high-level sequence is:

1. **Establish a baseline.** Record RAS/MCE counters and kernel hardware-error messages before stressing the CPU.
2. **Compare like with like.** Run the same deterministic workload on the suspected core and on a known-good control core.
3. **Observe thermal and frequency behaviour.** Compare temperatures, busy frequency and throttling under equivalent load.
4. **Check for repeatability.** Repeat tests and compare exit status and output hashes.
5. **Classify the result.** Separate hardware suspicion from an unstable control environment, software failure, thermal limitation or non-reproducible behaviour.
6. **Record the evidence.** Keep timestamps, test parameters, before/after error counts and logs.

A convenient starting point for the classification sequence is:

```bash
sudo faultlab-mode lab
sudo faultlab-classify 300
```

This sequence uses the supplied stress and A/B tooling. Review its commands and dependencies before running it; it writes a `sessions.log` file in the project directory.

### A/B verdicts

`faultlab-ab` runs the supplied command repeatedly on:

- **Faulty candidate:** configured `FAULT_CPUS`, through `faultlab.slice`
- **Control:** configured `CONTROL_CPUS`, using `taskset`

It compares return codes and SHA-256 hashes of standard output. The resulting verdicts are:

| Verdict | Meaning |
|---|---|
| `PASS` | Both sides completed consistently and produced matching output |
| `CONTROL-UNSTABLE` | The control run failed or was not repeatable; the experiment is inconclusive |
| `HW-SUSPECT` | The target-core run failed or was not repeatable while the control was stable |
| `DIVERGENCE` | Both sides completed consistently but produced different output |

Example:

```bash
sudo faultlab-ab --runs 5 -- python3 tools/sdc_probe.py
```

The A/B log is written by default to `/var/log/faultlab/ab.jsonl`. Set `FAULTLAB_RESULTS` to override the output path.

A divergence is a **candidate signal**, not conclusive proof of a hardware defect. Re-run under controlled conditions and investigate the workload, environment and control core before drawing conclusions.

## Experimental cryptographic probe

The repository includes an RSA-CRT differential-fault experiment. It generates a disposable test key, performs signing on the candidate core and verifies signatures on the control core. The verifier checks whether a faulty signature could reveal a factor of the RSA modulus.

Example sequence from the repository root:

```bash
# Generate a throwaway key on the control CPUs.
sudo taskset -c 3,9 faultlab-crypto keygen

# Sign using the candidate core.
sudo faultlab faultlab-crypto sign --out /tmp/dfa.jsonl --iterations 2000

# Verify on the control CPUs.
sudo taskset -c 3,9 faultlab-crypto verify --in /tmp/dfa.jsonl
```

The test requires Python 3 and `cryptography`. It is an experimental fault-injection probe, not a general-purpose cryptographic test suite.

> **Never use a real key.** The script deliberately restricts key paths and expects a filename containing `test`. Use only throwaway keys and disposable messages. Never generate production keys, sign trusted data, process credentials or run security-sensitive workloads on the suspected core.

## Interpreting results and safety rules

Stop using LAB mode and return to RETIRED if any of the following occurs:

- an uncorrected hardware error, machine-check event or system crash;
- repeatable output corruption on the candidate core while the control remains stable;
- a rising corrected-error trend;
- unexplained instability that prevents a trustworthy control comparison.

Corrected errors, temperature differences and isolated test failures require investigation; they should not be treated as interchangeable signals. Consult the detailed decision matrix in the plan before classifying the processor.

Additional guardrails:

- Keep independent backups of important data and test evidence.
- Never use the suspected core for trusted cryptography, password hashing, key generation, random-number generation or TLS workloads.
- Do not treat CPU isolation as a substitute for hardware repair or replacement.
- Do not rely on the rig as a safety mechanism for production systems.
- Preserve the control core in A/B tests so software and environment failures can be distinguished from candidate-core behaviour.

## Rollback

If you need to remove the configuration:

```bash
sudo ./rollback.sh
sudo reboot
```

The rollback script disables the retirement service, removes the installed systemd and tool files, restores the newest clean `/etc/default/grub.faultlab.*` backup it finds, strips any remaining faultlab parameters from `/etc/default/grub` and `grub.cfg`, runs `update-grub` and attempts to bring the configured fault CPUs online.

Review the script and confirm that the selected backup is the correct one before relying on it. If no clean backup is found, the script strips the parameters from the current file. Keep a recovery path available in case the boot configuration prevents normal startup.

## Documentation

- [Detailed fault-core plan](docs/fault-core-plan.md) — test phases, decision matrix, isolation model, QA programme and integration notes.
- [Repository](https://github.com/scripting-drafts/Fault-Injection-Hatch)

## License

[MIT](LICENSE).
