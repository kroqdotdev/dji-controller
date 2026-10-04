"""Read-only UAC1 probe of Feature Unit 5 (mute/volume). Bypasses pyusb's auto-claim
so the kernel audio driver keeps the interface."""
import usb.core

VID, PID = 0x2CA3, 0x4015
dev = usb.core.find(idVendor=VID, idProduct=PID)
dev._ctx.managed_open()
be, h = dev._ctx.backend, dev._ctx.handle

AC_IF, FU = 1, 5
REQ = {"CUR": 0x81, "MIN": 0x82, "MAX": 0x83, "RES": 0x84}

def get(req, cs, ch, n):
    buf = usb.util.create_buffer(n)
    got = be.ctrl_transfer(h, 0xA1, REQ[req], (cs << 8) | ch, (FU << 8) | AC_IF, buf, 1000)
    return bytes(buf[:got])

def s16(b): return int.from_bytes(b, "little", signed=True)

print("mute CUR:", get("CUR", 1, 0, 1).hex())
for r in ("CUR", "MIN", "MAX", "RES"):
    v = s16(get(r, 2, 0, 2))
    print(f"volume {r}: raw={v} ({v/256:.2f} dB)")
for ch in (1, 2):
    try:
        print(f"ch{ch} volume CUR:", s16(get("CUR", 2, ch, 2)) / 256, "dB")
    except Exception as e:
        print(f"ch{ch} volume: {e}")
# sample rate on the iso endpoint
buf = usb.util.create_buffer(3)
try:
    got = be.ctrl_transfer(h, 0xA2, 0x81, 0x0100, 0x81, buf, 1000)
    print("EP 0x81 sample rate CUR:", int.from_bytes(bytes(buf[:got]), "little"))
except Exception as e:
    print("sample rate read:", e)
