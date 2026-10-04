"""Try a DUML ping to 0x5a over HID report 0x41 with several framings."""
import sys, time, hid
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import duml

h = hid.device(); h.open(0x2CA3, 0x4015); h.set_nonblocking(True)

def drain(secs):
    out, end = [], time.time() + secs
    while time.time() < end:
        r = h.read(64)
        if r: out.append(bytes(r))
        else: time.sleep(0.002)
    return out

seq = 0x4000
for label, wrap in [
    ("raw", lambda f: f),
    ("len8", lambda f: bytes([len(f)]) + f),
    ("0,len8", lambda f: b"\x00" + bytes([len(f)]) + f),
    ("len16le", lambda f: len(f).to_bytes(2, "little") + f),
    ("len16be", lambda f: len(f).to_bytes(2, "big") + f),
]:
    for sender in (0x02, 0x2a):
        seq += 1
        f = duml.build(sender, 0x5A, seq, 0x00, 0x00)
        pkt = bytes([0x41]) + wrap(f).ljust(63, b"\x00")
        n = h.write(pkt)
        rep = drain(0.4)
        print(f"{label:8s} s=0x{sender:02x} wrote={n} replies={[r.hex() for r in rep]}")
