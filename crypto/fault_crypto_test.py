#!/usr/bin/env python3
"""RSA-CRT differential-fault test.

Sign on the faulty core, verify on a healthy core.  A single CRT fault can
leak the private key (Bellcore attack); the verifier attempts the gcd recovery.

  taskset -c 3,9 python3 crypto/fault_crypto_test.py keygen
  sudo faultlab python3 crypto/fault_crypto_test.py sign --out /tmp/dfa.jsonl
  taskset -c 3,9 python3 crypto/fault_crypto_test.py verify --in /tmp/dfa.jsonl

Throwaway test key only. Never point --key at a real key.
"""
import argparse
import json
import math
import os
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

SHA256_DIGEST_INFO = bytes.fromhex("3031300d060960864801650304020105000420")
DEFAULT_KEY = "/var/lib/faultlab/dfa-test-key.pem"


def ensure_test_key(path):
    real = os.path.realpath(path)
    forbidden = (os.path.expanduser("~/.ssh"), "/etc", "/root/.ssh")
    if any(real.startswith(p + os.sep) or real == p for p in forbidden):
        sys.exit("refusing to use a key outside the lab directory")
    if "test" not in os.path.basename(real):
        sys.exit("refusing: key filename must contain 'test'")


def keygen(path):
    ensure_test_key(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    with open(path, "wb") as f:
        f.write(
            key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
        )
    print(f"throwaway test key written to {path}")


def load(path):
    ensure_test_key(path)
    with open(path, "rb") as f:
        return serialization.load_pem_private_key(f.read(), password=None)


def emsa_pkcs1_v15(message, k):
    digest = hashes.Hash(hashes.SHA256())
    digest.update(message)
    t = SHA256_DIGEST_INFO + digest.finalize()
    ps = b"\xff" * (k - len(t) - 3)
    return b"\x00\x01" + ps + b"\x00" + t


def cmd_sign(args):
    key = load(args.key)
    cpus = sorted(os.sched_getaffinity(0))
    with open(args.out, "w") as f:
        for _ in range(args.iterations):
            message = os.urandom(32)
            signature = key.sign(message, padding.PKCS1v15(), hashes.SHA256())
            f.write(json.dumps({"m": message.hex(), "s": signature.hex()}) + "\n")
    print(f"signed {args.iterations} messages on CPUs {cpus}")


def cmd_verify(args):
    key = load(args.key)
    pub = key.public_key()
    numbers = key.private_numbers().public_numbers
    n, e = numbers.n, numbers.e
    k = (key.key_size + 7) // 8
    total = bad = 0
    factor = None
    with open(args.inp) as f:
        for line in f:
            record = json.loads(line)
            message = bytes.fromhex(record["m"])
            signature = bytes.fromhex(record["s"])
            total += 1
            try:
                pub.verify(signature, message, padding.PKCS1v15(), hashes.SHA256())
            except InvalidSignature:
                bad += 1
                s = int.from_bytes(signature, "big")
                m = int.from_bytes(emsa_pkcs1_v15(message, k), "big")
                g = math.gcd(pow(s, e, n) - m, n)
                if 1 < g < n:
                    factor = g
                    print(f"CRITICAL: faulty signature exposed a factor of n: {g}")
                    break
    print(f"verified {total} signatures on CPUs {sorted(os.sched_getaffinity(0))}, {bad} invalid")
    if factor:
        print("VERDICT: KEY RECOVERED — a CRT fault compromises the private key.")
        return 3
    if bad:
        print("VERDICT: FAULT OBSERVED — invalid signatures, no key recovery in this sample.")
        return 2
    print("VERDICT: CLEAN — no fault observed; raise --iterations or add load.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--key", default=DEFAULT_KEY)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("keygen")
    p.set_defaults(func=lambda a: keygen(a.key))

    p = sub.add_parser("sign")
    p.add_argument("--out", required=True)
    p.add_argument("--iterations", type=int, default=2000)
    p.set_defaults(func=cmd_sign)

    p = sub.add_parser("verify")
    p.add_argument("--in", dest="inp", required=True)
    p.set_defaults(func=cmd_verify)

    args = parser.parse_args()
    return args.func(args) or 0


if __name__ == "__main__":
    sys.exit(main())
