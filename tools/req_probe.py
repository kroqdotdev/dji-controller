"""Send read-only general DUML requests to the receiver and print anything that is not routine status."""
import sys
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from djimic import Link, fmt

def routine(p):
    return p["set"] == 0x5B and p["id"] in (0x03, 0x04)

link = Link()
try:
    list(link.frames(0.3))
    tests = [
        ("ping", 0x00, 0x00, b""),
        ("get version", 0x00, 0x01, b""),
        ("get device info", 0x00, 0x4F, b""),
        ("get sn", 0x00, 0x51, b""),
    ]
    for receiver in (0x5A, 0x1A, 0x00):
        for cmd_type in (0x40, 0x20):
            for label, cs, ci, pl in tests:
                frame = link.send(cs, ci, pl, receiver=receiver, cmd_type=cmd_type)
                hits = [p for p in link.frames(0.35) if not routine(p)]
                print(f"{label:16s} r=0x{receiver:02x} type=0x{cmd_type:02x} -> {len(hits)} replies")
                for p in hits:
                    print("    ", fmt(p), p["raw"].hex())
finally:
    link.close()
