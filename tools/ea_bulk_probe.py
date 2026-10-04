"""Claim the com.dji.mic EA native-transport interface (4), select alt 1 and exchange
read-only DUML requests over its bulk endpoints. Restores alt 0 on exit."""
import sys, time
import usb.core, usb.util
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import duml

VID, PID, IFACE = 0x2CA3, 0x4015, 4
EP_OUT, EP_IN = 0x04, 0x84

dev = usb.core.find(idVendor=VID, idProduct=PID)
usb.util.claim_interface(dev, IFACE)
dev.set_interface_altsetting(interface=IFACE, alternate_setting=1)
print("claimed interface 4, alt 1")

def read_all(timeout_ms=300):
    out = []
    while True:
        try:
            out.append(bytes(dev.read(EP_IN, 512, timeout=timeout_ms)))
            timeout_ms = 100
        except usb.core.USBTimeoutError:
            return out

try:
    unsolicited = read_all(1500)
    print("unsolicited:", [u.hex() for u in unsolicited])
    seq = 0x2000
    for sender in (0x2a, 0x02):
        for receiver in (0x00, 0x01, 0x02, 0x09, 0x0a, 0x1f):
            seq += 1
            frame = duml.build(sender, receiver, seq, 0x00, 0x01)
            dev.write(EP_OUT, frame, timeout=1000)
            replies = read_all()
            print(f"getver s=0x{sender:02x} r=0x{receiver:02x}: {len(replies)} replies")
            for r in replies:
                print("   ", r.hex(), duml.parse(r))
finally:
    try:
        dev.set_interface_altsetting(interface=IFACE, alternate_setting=0)
    except Exception as e:
        print("restore alt0:", e)
    usb.util.release_interface(dev, IFACE)
    usb.util.dispose_resources(dev)
    print("released")
