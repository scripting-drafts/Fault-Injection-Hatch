# fault-injection-rig

Classify, isolate and exercise a degrading CPU core (example: physical core 2).
Default mode RETIRED: the core's CPUs are offlined at boot.
Lab mode is fenced by `isolcpus`, `nohz_full`, `rcu_nocbs`, `irqaffinity` and cgroup v2.
Docs: `docs/fault-core-plan.md`
Install: `sudo ./apply.sh` then reboot
Lab: `sudo faultlab-mode lab`, then `sudo faultlab CMD`
Verify: `sudo faultlab-verify`; rollback: `sudo ./rollback.sh`
MIT. Test keys and disposable data only.
