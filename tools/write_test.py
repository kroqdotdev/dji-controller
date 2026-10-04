"""Reversible write test: toggle a few harmless settings, confirm via status pushes, restore."""
import sys, time
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from djimic import Link

TX_ALL, TX2, RX = 0xFFFF, 0x0002, 0x0000

def set_param(link, target, param, value: bytes):
    payload = bytes([0x02]) + target.to_bytes(4, "little") + param.to_bytes(2, "little") + bytes([len(value)]) + value
    return link.send(0x5B, 0x01, payload)

def status(link, secs=1.6):
    """Return (rx_value, tx_value, acks) from the latest status push in the window."""
    rx = tx = None
    acks = []
    for p in link.frames(secs):
        if p["type"] & 0x80:
            acks.append((p["set"], p["id"], p["payload"].hex()))
        if p["set"] == 0x5B and p["id"] == 0x03 and len(p["payload"]) >= 41 and p["payload"][3] == 0x03:
            d = p["payload"]
            rx = d[9:9 + d[8]]
            tx = d[47:47 + d[46]] if len(d) > 47 else None
    return rx, tx, acks

def show(label, rx, tx, acks):
    lowcut = bool(tx[3] & 0x20) if tx else None
    gain = int.from_bytes(tx[7:8], "little", signed=True) if tx else None
    stereo = bool(rx[1] & 0x04) if rx else None
    print(f"{label:28s} lowCut={lowcut} txGain={gain}dB rxStereo={stereo} acks={acks}")

if __name__ == "__main__":
    link = Link()
    try:
        show("baseline", *status(link))
        steps = [
            ("tx lowCut ON", TX_ALL, 0x03, b"\x01"),
            ("tx lowCut OFF (restore)", TX_ALL, 0x03, b"\x00"),
            ("tx2 gain +3dB", TX2, 0x39, b"\x03"),
            ("tx2 gain 0dB (restore)", TX2, 0x39, b"\x00"),
            ("rx stereo ON", RX, 0x08, b"\x02"),
            ("rx mono (restore)", RX, 0x08, b"\x00"),
        ]
        for label, target, param, val in steps:
            frame = set_param(link, target, param, val)
            time.sleep(0.05)
            show(label, *status(link, 2.2))
    finally:
        link.close()
