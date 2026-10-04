"""Dump and decode the full USB configuration descriptor of the DJI Mic receiver."""
import usb.core, usb.util

VID = 0x2CA3
dev = usb.core.find(idVendor=VID, custom_match=lambda d: d.idProduct in (0x4015, 0x4115))
assert dev, "receiver not found"

raw = bytes(dev.ctrl_transfer(0x80, 6, 0x0200, 0, 4096))
print(f"config descriptor: {len(raw)} bytes")
print(raw.hex())
print()

for i in range(1, 8):
    try:
        print(f"string {i}: {usb.util.get_string(dev, i)!r}")
    except Exception as e:
        print(f"string {i}: <{e}>")
print()

AC_SUB = {1: "HEADER", 2: "INPUT_TERMINAL", 3: "OUTPUT_TERMINAL", 4: "MIXER_UNIT",
          5: "SELECTOR_UNIT", 6: "FEATURE_UNIT", 7: "PROCESSING_UNIT", 8: "EXTENSION_UNIT"}
AS_SUB = {1: "AS_GENERAL", 2: "FORMAT_TYPE"}
FU_BITS = ["Mute", "Volume", "Bass", "Mid", "Treble", "GraphicEQ", "AGC", "Delay", "BassBoost", "Loudness"]
TERM = {0x0101: "USB Streaming", 0x0201: "Microphone", 0x0301: "Speaker", 0x0402: "Headset",
        0x0603: "Line connector", 0x0205: "Mic array"}

i, cur_if, cur_cls, cur_sub = 0, None, None, None
while i < len(raw):
    L, T = raw[i], raw[i + 1]
    d = raw[i:i + L]
    if T == 2:
        print(f"CONFIG wTotalLength={d[2]|d[3]<<8} nIf={d[4]} attr=0x{d[7]:02x} maxPower={d[8]*2}mA")
    elif T == 11:
        print(f"  IAD firstIf={d[2]} count={d[3]} class={d[4]:02x}/{d[5]:02x}/{d[6]:02x}")
    elif T == 4:
        cur_if, cur_cls, cur_sub = d[2], d[5], d[6]
        print(f"  INTERFACE {d[2]} alt={d[3]} nEP={d[4]} class={d[5]:02x}/{d[6]:02x}/{d[7]:02x} iIf={d[8]}")
    elif T == 5:
        addr = d[2]
        kind = ["CTRL", "ISO", "BULK", "INT"][d[3] & 3]
        extra = f" sync={(d[3]>>2)&3}" if kind == "ISO" else ""
        print(f"    ENDPOINT 0x{addr:02x} {'IN' if addr & 0x80 else 'OUT'} {kind}{extra} maxPkt={d[4]|d[5]<<8} interval={d[6]}")
    elif T == 0x21 and cur_cls == 3:
        print(f"    HID bcd={d[2]|d[3]<<8:04x} country={d[4]} nDesc={d[5]} reportLen={d[7]|d[8]<<8}")
    elif T == 0x24 and cur_cls == 1 and cur_sub == 1:
        st = d[2]
        name = AC_SUB.get(st, hex(st))
        if st == 1:
            n = d[7]
            print(f"    AC {name} bcdADC={d[3]|d[4]<<8:04x} totalLen={d[5]|d[6]<<8} inCollection={list(d[8:8+n])}")
        elif st == 2:
            tt = d[4] | d[5] << 8
            print(f"    AC {name} id={d[3]} type=0x{tt:04x}({TERM.get(tt,'?')}) assocTerm={d[6]} nCh={d[7]} chCfg=0x{d[8]|d[9]<<8:04x}")
        elif st == 3:
            tt = d[4] | d[5] << 8
            print(f"    AC {name} id={d[3]} type=0x{tt:04x}({TERM.get(tt,'?')}) assocTerm={d[6]} srcId={d[7]}")
        elif st == 6:
            uid, src, csize = d[3], d[4], d[5]
            ctrls = d[6:L - 1]
            chunks = [int.from_bytes(ctrls[k:k + csize], "little") for k in range(0, len(ctrls), csize)]
            desc = []
            for ch, bm in enumerate(chunks):
                names = [FU_BITS[b] for b in range(len(FU_BITS)) if bm >> b & 1]
                desc.append(f"{'master' if ch == 0 else 'ch'+str(ch)}={names}")
            print(f"    AC {name} id={uid} src={src} " + " ".join(desc))
        elif st == 5:
            p = d[4]
            print(f"    AC {name} id={d[3]} sources={list(d[5:5+p])}")
        else:
            print(f"    AC {name} raw={d.hex()}")
    elif T == 0x24 and cur_cls == 1 and cur_sub == 2:
        st = d[2]
        if st == 1:
            print(f"    AS_GENERAL terminalLink={d[3]} delay={d[4]} format=0x{d[5]|d[6]<<8:04x}")
        elif st == 2:
            ftype, nch, sub, bits, nfreq = d[3], d[4], d[5], d[6], d[7]
            freqs = [int.from_bytes(d[8 + 3 * k:11 + 3 * k], "little") for k in range(nfreq)] if nfreq else \
                    [f"{int.from_bytes(d[8:11],'little')}-{int.from_bytes(d[11:14],'little')}"]
            print(f"    FORMAT_TYPE {ftype} channels={nch} subframe={sub} bits={bits} rates={freqs}")
        else:
            print(f"    AS raw={d.hex()}")
    elif T == 0x25:
        print(f"    CS_ENDPOINT raw={d.hex()}")
    else:
        print(f"    desc type=0x{T:02x} raw={d.hex()}")
    i += L
