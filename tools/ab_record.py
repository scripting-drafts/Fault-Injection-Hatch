#!/usr/bin/env python3
"""Append one faultlab-ab verdict to the QA Sentinels JSONL feed."""
import json
import os
import sys
from datetime import datetime, timezone


def text(path: str, default: str = "") -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read().strip()
    except OSError:
        return default


def main(argv: list[str]) -> int:
    if len(argv) != 7:
        print("usage: ab_record.py OUT VERDICT EXIT RUNS FAULTY_HASH CONTROL_HASH",
              file=sys.stderr)
        return 2
    out, verdict, rc, runs, fhash, chash, command = argv
    record = {
        "schema": "faultlab.ab/1",
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "verdict": verdict,
        "exit": int(rc),
        "runs": int(runs),
        "faulty_cpus": os.environ.get("FAULTLAB_FAULTY_CPUS", "unknown"),
        "control_cpus": os.environ.get("FAULTLAB_CONTROL_CPUS", "unknown"),
        "faulty_hashes": [fhash] if fhash else [],
        "control_hashes": [chash] if chash else [],
        "command": command.strip(),
        "mode": text("/etc/faultlab/mode", "unknown"),
        "boot_id": text("/proc/sys/kernel/random/boot_id"),
    }
    with open(out, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, separators=(",", ":")) + "\n")
    try:
        os.chmod(out, 0o640)
        import grp
        os.chown(out, 0, grp.getgrnam("adm").gr_gid)
    except (OSError, KeyError):
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
