"""Send read-only DUML requests over vendor HID report 0x41 and print any replies."""
import sys, time, hid
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import duml

VID, PID = 0x2CA3, 0x4015
h = hid.device()
h.open(VID, PID)
h.set_nonblocking(True)

def drain(secs):
    out, end = [], time.time() + secs
    while time.time() < end:
        r = h.read(64)
        if r:
            out.append(bytes(r))
        else:
            time.sleep(0.002)
    return out

def send(report_id, data, label):
    pkt = bytes([report_id]) + data.ljust(63, b"\x00")
    try:
        n = h.write(pkt)
    except Exception as e:
        n = f"err {e}"
    replies = drain(0.4)
    print(f"[{label}] wrote={n} replies={len(replies)}")
    for r in replies:
        print(f"    id=0x{r[0]:02x} {r.hex()}")
        for off in (0, 1, 2):
            p = duml.parse(r[off:]) if off else duml.parse(r)
            if p:
                print(f"    DUML@{off}: {p}")
    return replies

seq = 0x1000
# get version (set 0x00 id 0x01) to a range of receiver addresses, from "PC" (0x0a) and "app" (0x02)
for sender in (0x2a, 0x02):
    for receiver in (0x00, 0x01, 0x02, 0x0a, 0x09, 0x1f, 0x20, 0x21):
        seq += 1
        frame = duml.build(sender, receiver, seq, 0x00, 0x01)
        send(0x41, frame, f"getver s=0x{sender:02x} r=0x{receiver:02x}")
