"""Map quad-mode USB audio channels to transmitter slots.

Captures the 4 USB audio channels while recording each transmitter's level meter
from the control channel, then correlates the two. Tap the mics one at a time."""
import json, sys, threading, time
import numpy as np
import sounddevice as sd
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from djimic import Link, parse_records

DURATION = 75
SLOT = {1: "TX1", 2: "TX2", 4: "TX3", 8: "TX4"}
OUT = "/tmp/djimap.json"


def find_input(name):
    return next(i for i, d in enumerate(sd.query_devices()) if name in d["name"] and d["max_input_channels"] > 0)


def wait_for_permission():
    probe = find_input("MacBook Pro Microphone")
    print("Checking microphone permission (click Allow if macOS asks)...", flush=True)
    end = time.time() + 90
    while time.time() < end:
        rec = sd.rec(4800, samplerate=48000, channels=1, device=probe, dtype="float32")
        sd.wait()
        if (rec != 0).any():
            print("Microphone access OK.\n", flush=True)
            return True
        time.sleep(0.5)
    print("No microphone access. Allow Terminal in System Settings > Privacy & Security > Microphone.")
    return False


def db(x):
    return 20 * np.log10(max(float(x), 1e-9))


def main():
    if not wait_for_permission():
        return
    audio, meters = [], []
    live = {"ch": [-120.0] * 4, "tx": {}}

    def callback(indata, frames, t, status):
        rms = np.sqrt((indata.astype(np.float64) ** 2).mean(axis=0))
        now = time.time()
        audio.append((now, [db(r) for r in rms]))
        live["ch"] = [max(a, db(r)) for a, r in zip(live["ch"], rms)]

    dji = find_input("Wireless Mic")
    stream = sd.InputStream(device=dji, channels=4, samplerate=48000, blocksize=480, dtype="float32", callback=callback)
    link = Link()
    stop = threading.Event()

    def control():
        for p in link.frames(DURATION):
            if p["set"] == 0x5B and p["id"] == 0x03:
                _, recs = parse_records(p["payload"])
                for field, dev, val in recs:
                    if field == 5:
                        meters.append((time.time(), dev, val[0]))
                        live["tx"][dev] = max(live["tx"].get(dev, 0), val[0])
        stop.set()

    print("TAP OR SPEAK INTO ONE MIC AT A TIME: a few taps each, then wait ~3 s before the next mic.")
    print(f"Capturing for {DURATION} s...\n", flush=True)
    th = threading.Thread(target=control, daemon=True)
    with stream:
        th.start()
        t0 = time.time()
        while not stop.is_set():
            time.sleep(0.25)
            chs = "  ".join(f"ch{i+1} {'#' * max(0, int((v + 80) / 4)):<20s}" for i, v in enumerate(live["ch"]))
            txs = " ".join(f"{SLOT.get(d, d)}={live['tx'].get(d, 0):3d}" for d in (1, 2, 4, 8))
            print(f"\r{int(time.time() - t0):3d}s  {chs} | {txs}   ", end="", flush=True)
            live["ch"] = [-120.0] * 4
            live["tx"] = {}
    link.close()
    print("\n")

    # 100 ms bins: max channel dB and max meter value per transmitter
    t_start = audio[0][0]
    nbins = int((audio[-1][0] - t_start) / 0.1) + 1
    ch = np.full((nbins, 4), -120.0)
    for t, vals in audio:
        b = int((t - t_start) / 0.1)
        ch[b] = np.maximum(ch[b], vals)
    tx = {d: np.zeros(nbins) for d in (1, 2, 4, 8)}
    for t, d, v in meters:
        b = int((t - t_start) / 0.1)
        if 0 <= b < nbins and d in tx:
            tx[d][b] = max(tx[d][b], v)

    print("Correlation (rows = USB channel, columns = transmitter meter):")
    print("        " + "  ".join(f"{SLOT[d]:>6s}" for d in (1, 2, 4, 8)))
    mapping, matrix = {}, {}
    for c in range(4):
        row = []
        for d in (1, 2, 4, 8):
            a, m = ch[:, c], tx[d]
            r = float(np.corrcoef(a, m)[0, 1]) if a.std() > 0 and m.std() > 0 else 0.0
            row.append(r)
        matrix[f"ch{c+1}"] = row
        best = (1, 2, 4, 8)[int(np.argmax(row))]
        mapping[f"ch{c+1}"] = SLOT[best] if max(row) > 0.3 else "unclear"
        print(f"  ch{c+1}  " + "  ".join(f"{r:6.2f}" for r in row) + f"   -> {mapping[f'ch{c+1}']}")
    peaks = {f"ch{c+1}": round(float(ch[:, c].max()), 1) for c in range(4)}
    print("\nPeak level per channel (dBFS):", peaks)
    json.dump({"mapping": mapping, "matrix": matrix, "peaks": peaks,
               "noise_floor": {f"ch{c+1}": round(float(np.percentile(ch[:, c], 10)), 1) for c in range(4)}},
              open(OUT, "w"), indent=2)
    print(f"\nSaved to {OUT}. You can close this window.")


if __name__ == "__main__":
    main()
