"""Talk to the DJI Mic Mini 2S receiver over its com.dji.mic vendor interface.

Interface 4 alt 1 carries DUML frames (bulk 0x04 OUT / 0x84 IN). The receiver
pushes status as cmd set 0x5B with payload [0x03][u16 len] followed by records of
[u8 field][u32 device][u8 len][value]."""
import sys, time, struct
import usb.core, usb.util
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import duml

VID, PIDS, IFACE = 0x2CA3, (0x4015, 0x4115), 4
EP_OUT, EP_IN = 0x04, 0x84


def parse_records(payload: bytes):
    if len(payload) < 3:
        return None
    op, blen = payload[0], payload[1] | payload[2] << 8
    body, recs, i = payload[3:3 + blen], [], 0
    while i + 6 <= len(body):
        field, dev, ln = body[i], struct.unpack_from("<I", body, i + 1)[0], body[i + 5]
        recs.append((field, dev, body[i + 6:i + 6 + ln]))
        i += 6 + ln
    return op, recs


class Link:
    def __init__(self):
        self.dev = usb.core.find(idVendor=VID, custom_match=lambda d: d.idProduct in PIDS)
        if self.dev is None:
            raise SystemExit("receiver not found")
        usb.util.claim_interface(self.dev, IFACE)
        self.dev.set_interface_altsetting(interface=IFACE, alternate_setting=1)
        self.buf = b""
        self.seq = 0x3000

    def close(self):
        try:
            self.dev.set_interface_altsetting(interface=IFACE, alternate_setting=0)
        finally:
            usb.util.release_interface(self.dev, IFACE)
            usb.util.dispose_resources(self.dev)

    def send(self, cmd_set, cmd_id, payload=b"", receiver=0x5A, sender=0x02, cmd_type=0x40):
        self.seq += 1
        frame = duml.build(sender, receiver, self.seq, cmd_set, cmd_id, payload, cmd_type)
        self.dev.write(EP_OUT, frame, timeout=1000)
        return frame

    def frames(self, secs):
        """Yield parsed DUML frames for `secs` seconds."""
        end = time.time() + secs
        while time.time() < end:
            try:
                self.buf += bytes(self.dev.read(EP_IN, 512, timeout=50))
            except usb.core.USBTimeoutError:
                pass
            while True:
                start = self.buf.find(b"\x55")
                if start < 0:
                    self.buf = b""
                    break
                self.buf = self.buf[start:]
                if len(self.buf) < 4:
                    break
                ln = self.buf[1] | (self.buf[2] & 3) << 8
                if duml.crc8(self.buf[:3]) != self.buf[3] or ln < 13:
                    self.buf = self.buf[1:]
                    continue
                if len(self.buf) < ln:
                    break
                p = duml.parse(self.buf[:ln])
                raw = self.buf[:ln]
                self.buf = self.buf[ln:]
                if p and p["crc_ok"]:
                    p["raw"] = raw
                    yield p


def fmt(p):
    s = f"{p['sender']:02x}->{p['receiver']:02x} seq={p['seq']:5d} type=0x{p['type']:02x} set=0x{p['set']:02x} id=0x{p['id']:02x}"
    if p["set"] == 0x5B and p["id"] == 0x03:
        r = parse_records(p["payload"])
        if r:
            op, recs = r
            parts = []
            for field, dev, val in recs:
                txt = val.decode("ascii", "replace") if val and all(32 <= c < 127 for c in val[-6:]) else val.hex()
                parts.append(f"f{field}@d{dev}={txt}")
            return s + f" op={op} " + " ".join(parts)
    return s + f" payload={p['payload'].hex()}"


if __name__ == "__main__":
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else 5
    skip_meter = "--meter" not in sys.argv
    link = Link()
    try:
        for p in link.frames(secs):
            if skip_meter and p["set"] == 0x5B and p["id"] == 0x03 and len(p["payload"]) == 10:
                continue
            if skip_meter and p["set"] == 0x5B and p["id"] == 0x04:
                continue
            print(f"{time.strftime('%H:%M:%S')} {fmt(p)}", flush=True)
    finally:
        link.close()
