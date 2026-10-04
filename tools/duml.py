"""DJI DUML v1 framing (0x55 packets), as documented by o-gs/dji-firmware-tools."""

def crc8(data: bytes, init: int = 0x77) -> int:
    crc = init
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8C if crc & 1 else crc >> 1
    return crc


def crc16(data: bytes, init: int = 0x3692) -> int:
    crc = init
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return crc


def build(sender: int, receiver: int, seq: int, cmd_set: int, cmd_id: int,
          payload: bytes = b"", cmd_type: int = 0x40) -> bytes:
    length = 13 + len(payload)
    hdr = bytes([0x55, length & 0xFF, ((length >> 8) & 0x03) | 0x04])
    hdr += bytes([crc8(hdr)])
    body = hdr + bytes([sender, receiver, seq & 0xFF, seq >> 8, cmd_type, cmd_set, cmd_id]) + payload
    return body + crc16(body).to_bytes(2, "little")


def parse(frame: bytes):
    """Return a dict for a DUML frame, or None if the bytes are not a valid frame."""
    if len(frame) < 13 or frame[0] != 0x55:
        return None
    length = frame[1] | ((frame[2] & 0x03) << 8)
    if length > len(frame) or crc8(frame[:3]) != frame[3]:
        return None
    f = frame[:length]
    ok = crc16(f[:-2]) == int.from_bytes(f[-2:], "little")
    return {"len": length, "sender": f[4], "receiver": f[5], "seq": f[6] | f[7] << 8,
            "type": f[8], "set": f[9], "id": f[10], "payload": f[11:-2], "crc_ok": ok}
