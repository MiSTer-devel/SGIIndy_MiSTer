#!/usr/bin/env python3
"""The IP24 PROM's startup tunes, decoded exactly as the PROM decodes them -
and a check that a WAV of the core's DAC plays one of them.

WHY. The PROM's tune is the one piece of audio every boot produces, and it is
fully determined by the PROM image: ADPCM data, a step table and an index table
in the PROM, a decoder the PROM copies to RAM and runs (0xBFC032CC), and a DMA
chain into HAL2. Decoding it here, independently, gives the audio path an
end-to-end reference that owes nothing to the RTL: tests/run-audio.sh boots the
PROM in the simulator with --wav and hands the file to this.

The decoder, from the disassembly (docs/design/audio.md):
  * IMA-style 4-bit ADPCM, HIGH nibble of each byte first;
  * index += index_table[code]; clamped to 0..88;
  * diff = ((code & 7) * step) >> 2 + (step >> 3), SUBTRACTED when code & 8,
    with the predictor clamped to -0x8000..0x7FFF;
  * step is looked up AFTER the index moves, and the diff uses the OLD step;
  * each sample is stored as sample << 8 in a 32-bit word (bits 23:8).
Tune n's data and length (bytes; the PROM plays 2 x length samples):
  0  0x55AC0, length word at 0x60EBC     1  0x60EC0, 0x6A030
  2  0x6A034, 0x6DB30

    python3 tools/prom_tune.py PROM decode N out.wav      # the reference
    python3 tools/prom_tune.py PROM check  N dac.wav VOL  # does dac.wav play it?
"""
import struct
import sys
import wave

TUNES = {0: (0x55AC0, 0x60EBC), 1: (0x60EC0, 0x6A030), 2: (0x6A034, 0x6DB30)}
STEP_TABLE = 0x55954     # 89 words
INDEX_TABLE = 0x55914    # 16 words


def decode(prom, n, pred=0, index=0):
    data_at, len_at = TUNES[n]
    nbytes = struct.unpack(">I", prom[len_at:len_at + 4])[0]
    steps = struct.unpack(">89i", prom[STEP_TABLE:STEP_TABLE + 89 * 4])
    idxs = struct.unpack(">16i", prom[INDEX_TABLE:INDEX_TABLE + 16 * 4])
    out = []
    step = steps[index]
    for b in prom[data_at:data_at + nbytes]:
        for code in (b >> 4, b & 0xF):
            index += idxs[code]
            index = 0 if index < 0 else 88 if index > 88 else index
            mag = code & 7
            diff = ((mag * step) >> 2) + (step >> 3)
            if code & 8:
                pred = max(pred - diff, -0x8000)
            else:
                pred = min(pred + diff, 0x7FFF)
            step = steps[index]
            out.append(pred)
    return out


def dac(s, vol):
    """hal2.sv's output stage: volume register vol, no codec attenuation."""
    vm = vol + (vol >> 7)
    g = (65535 * vm) >> 8
    return (s * g) >> 16


def write_wav(path, samples, rate=44100):
    w = wave.open(path, "wb")
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(rate)
    w.writeframes(b"".join(struct.pack("<h", s) for s in samples))
    w.close()


def read_wav(path):
    w = wave.open(path, "rb")
    ch = w.getnchannels()
    raw = w.readframes(w.getnframes())
    vals = struct.unpack("<%dh" % (len(raw) // 2), raw)
    return [vals[i:i + ch] for i in range(0, len(vals), ch)], w.getframerate()


def main():
    prom = open(sys.argv[1], "rb").read()
    mode, n = sys.argv[2], int(sys.argv[3])
    ref = decode(prom, n)
    if mode == "decode":
        write_wav(sys.argv[4], ref)
        print("tune %d: %d samples, %.2f s at 44.1 kHz, peak %d"
              % (n, len(ref), len(ref) / 44100, max(abs(s) for s in ref)))
        return 0
    frames, rate = read_wav(sys.argv[4])
    vol = int(sys.argv[5])
    want = [dac(s, vol) for s in ref]
    left = [f[0] for f in frames]
    right = [f[1] if len(f) > 1 else f[0] for f in frames]
    # Where the tune starts in the capture: the first place the first 64
    # expected samples line up exactly (they are not all zero: the tune opens
    # with sound).
    first = next((i for i, s in enumerate(want) if s != 0), 0)
    key = want[first:first + 64]
    start = -1
    for i in range(len(left) - len(key)):
        if left[i:i + len(key)] == key:
            start = i - first
            break
    if start < 0:
        print("TUNE CHECK FAIL: the tune's opening was not found in %s (%d frames, "
              "peak %d)" % (sys.argv[4], len(left), max(abs(s) for s in left) if left else 0))
        return 1
    got = left[start:start + len(want)]
    bad = sum(1 for a, b in zip(got, want) if a != b)
    short = len(want) - len(got)
    rbad = sum(1 for a, b in zip(right[start:start + len(want)], got) if a != b)
    print("tune %d found at frame %d of %d: %d/%d samples exact, %d missing at the "
          "end, right channel differs from left at %d"
          % (n, start, len(left), len(want) - bad - short, len(want), short, rbad))
    ok = bad == 0 and short == 0 and rbad == 0
    print("TUNE CHECK %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
