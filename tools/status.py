"""Print a decoded snapshot of the receiver and every connected transmitter.
Offsets follow usokawa/dji-mic-mo (status record value starts 6 bytes after the record header)."""
import sys
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from djimic import Link, parse_records

SLOT = {1: "TX1", 2: "TX2", 4: "TX3", 8: "TX4"}


def snapshot(link, secs=3.0):
    recs = {}
    levels = {}
    for p in link.frames(secs):
        if p["set"] != 0x5B or p["id"] != 0x03:
            continue
        _, rr = parse_records(p["payload"])
        for field, dev, val in rr:
            if field == 5:
                levels.setdefault(dev, []).append(val[0])
            else:
                recs[(field, dev)] = val
    return recs, levels


def tx_state(v):
    return {
        "battery(1=full)": (v[1] >> 2) & 7,
        "charging": bool(v[1] & 0x02),
        "gain_dB": int.from_bytes(v[7:8], "little", signed=True),
        "nc": bool(v[1] & 0x01),
        "ncStrong": bool(v[0] & 0x20),
        "lowCut": bool(v[3] & 0x20),
        "rec": bool(v[3] & 0x10),
        "recTotal_h": int.from_bytes(v[8:10], "little") / 10,
        "recLeft_h": int.from_bytes(v[10:12], "little") / 10,
    }


if __name__ == "__main__":
    link = Link()
    try:
        recs, levels = snapshot(link)
    finally:
        link.close()
    rx = recs.get((3, 0))
    if rx:
        print(f"RX  stereo={bool(rx[1] & 0x04)} quad={bool(rx[1] & 0x08)} battery={(rx[1] >> 5) & 7} "
              f"byte20=0x{rx[20]:02x} connectedMask=0x{rx[24]:02x} raw={rx.hex()}")
    for dev in sorted({d for (_, d) in recs if d}):
        ident = recs.get((1, dev))
        serial = ident[4:].decode(errors="replace") if ident else "?"
        st = recs.get((2, dev))
        lv = levels.get(dev, [])
        print(f"{SLOT.get(dev, dev)} (dev {dev}) sn={serial} meter[max={max(lv, default=None)}]")
        if st:
            print("    ", tx_state(st), "raw=", st.hex())
