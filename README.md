# Fault Injection Hatch

Classify, isolate and exercise a degrading CPU core against a healthy control core.
Install: `sudo ./apply.sh --fault-cpu N [--control-cpu M]`, then reboot.
`--fault-cpu` is any logical CPU on the target physical core; siblings are auto-detected.
Control defaults to another core (same package/SMT width when possible).
Lab: `sudo faultlab-mode lab`, then `sudo faultlab CMD`.
Verify: `sudo faultlab-verify`; rollback: `sudo ./rollback.sh`.
Rescue USB: `examples/rescue-usb/` (UEFI auto-restore).
Docs: `docs/fault-core-plan.md`; extended guide: `docs/overview.md`. MIT. Test keys and disposable data only.
