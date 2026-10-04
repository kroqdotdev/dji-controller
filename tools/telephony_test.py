"""Toggle telephony LED output report 7 and watch the DUML status stream and HID input for reactions."""
import sys, time, hid
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from djimic import Link, parse_records

# report 7 output: 15 LED bits in descriptor order, then 1 pad bit
LEDS = ["DND", "OffHook", "Ring", "MsgWaiting", "DataMode", "Speaker", "Headset", "Hold",
        "Microphone", "Coverage", "Night", "SendCalls", "CallPickup", "Conference", "Mute"]

def bits(*names):
    v = sum(1 << LEDS.index(n) for n in names)
    return bytes([0x07, v & 0xFF, v >> 8])

h = hid.device(); h.open(0x2CA3, 0x4015); h.set_nonblocking(True)
link = Link()
state = {}

def watch(secs, label):
    levels = []
    for p in link.frames(secs):
        if p["set"] == 0x5B and p["id"] == 0x03:
            op, recs = parse_records(p["payload"])
            for field, dev, val in recs:
                if field == 5:
                    levels.append(val[0])
                    continue
                k = (field, dev)
                if state.get(k) != val:
                    if k in state:
                        print(f"   CHANGE f{field}@d{dev}: {state[k].hex()} -> {val.hex()}")
                    state[k] = val
        elif not (p["set"] == 0x5B and p["id"] == 0x04):
            print("   frame", p["raw"].hex())
    hid_in = []
    while (r := h.read(64)):
        hid_in.append(bytes(r).hex())
    print(f"[{label}] meter max={max(levels, default=None)} hid_in={hid_in}")

try:
    watch(2.5, "baseline")
    for names in [("OffHook",), ("OffHook", "Mute"), ("OffHook",), ("Mute",), ("Ring",), ()]:
        h.write(bits(*names))
        watch(2.5, "+".join(names) or "clear")
finally:
    h.write(bits())
    link.close()
