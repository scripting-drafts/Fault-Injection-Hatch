#!/usr/bin/env python3
"""Deterministic ALU-heavy checksum probe for silent-corruption testing."""
import argparse

parser = argparse.ArgumentParser()
parser.add_argument("-n", "--iterations", type=int, default=20_000_000)
args = parser.parse_args()

x = 0xC0FFEE
for _ in range(args.iterations):
    x = (x * 1664525 + 1013904223) & 0xFFFFFFFF
    x ^= x >> 13
    x = (x + (x << 7)) & 0xFFFFFFFF
print(f"{x:08x}")
