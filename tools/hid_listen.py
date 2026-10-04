"""Passively print every HID input report from the receiver for N seconds."""
import sys, time, hid

VID, PID = 0x2CA3, 0x4015
secs = float(sys.argv[1]) if len(sys.argv) > 1 else 5

for d in hid.enumerate(VID, PID):
    print(f"hid path={d['path']} usage_page=0x{d['usage_page']:04x} usage=0x{d['usage']:02x} if={d['interface_number']}")

h = hid.device()
h.open(VID, PID)
h.set_nonblocking(True)
print("listening", secs, "s")
end = time.time() + secs
n = 0
while time.time() < end:
    r = h.read(64)
    if r:
        n += 1
        print(f"{time.time():.3f} id=0x{r[0]:02x} len={len(r)} {bytes(r).hex()}", flush=True)
    else:
        time.sleep(0.002)
print("reports:", n)
