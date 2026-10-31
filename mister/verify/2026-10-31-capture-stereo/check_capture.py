#!/usr/bin/env python3
"""Auswertung der Capture-Aufnahmen fuer PR #1.

Nur Standardbibliothek. Erwartet im selben Ordner:
  before-stream.raw   Aufnahme vor dem Fix (liegt bei)
  stream.raw          Aufnahme nach dem Fix (muss noch abgelegt werden)

Format: Big-Endian int16, stereo verschraenkt, 4 Byte pro Frame.
"""

import collections
import os
import struct
import hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
FRAME = 4  # 2 x int16


def load(name):
    path = os.path.join(HERE, name)
    if not os.path.exists(path):
        return None
    raw = open(path, "rb").read()
    frames = [struct.unpack_from(">hh", raw, i * FRAME) for i in range(len(raw) // FRAME)]
    return raw, frames


def sha(data):
    return hashlib.sha256(data).hexdigest()


def report(tag, raw, frames):
    left = [a for a, _ in frames]
    right = [b for _, b in frames]
    mism = [i for i, (a, b) in enumerate(frames) if a != b]

    print(f"\n== {tag} ==")
    print(f"SHA256      : {sha(raw)}")
    print(f"Frames      : {len(frames)}  ({len(raw)} Bytes)")
    print(f"Wertebereich: {min(left + right)} .. {max(left + right)}")
    print(f"L != R      : {len(mism)}")

    if mism:
        hist = collections.Counter(i % 32 for i in mism)
        print(f"  frame % 32: {dict(sorted(hist.items()))}")
        pairs = sorted({frames[i] for i in mism})
        print(f"  verschiedene Paare: {len(pairs)}, |L-R| max {max(abs(a - b) for a, b in pairs)}")
        print(f"  erste: {mism[:8]}")
    return frames, mism


def find_offset(new_raw, old_raw, frames):
    """Exakter Fenstertreffer, um den Versatz zweier Aufnahmen zu bestimmen."""
    votes = collections.Counter()
    for start in (frames // 4, frames // 2, 3 * frames // 4):
        start -= start % 4
        window = new_raw[start * FRAME:(start + 512) * FRAME]
        if len(window) < 512 * FRAME:
            continue
        pos = old_raw.find(window)
        while pos != -1 and pos % FRAME:
            pos = old_raw.find(window, pos + 1)
        if pos != -1:
            votes[(pos - start * FRAME) // FRAME] += 1
        else:
            print(f"  kein exakter Treffer fuer Fenster ab Frame {start}")
    return votes.most_common(1)[0][0] if votes else None


def main():
    before = load("before-stream.raw")
    after = load("stream.raw")

    if before is None:
        print("before-stream.raw fehlt — die Voraufnahme gehoert hierher.")
        return 1
    if after is None:
        print("stream.raw fehlt noch.")
        print("Format: Big-Endian int16, stereo verschraenkt, 65.536 Frames.")
        print("Danach dieses Skript erneut ausfuehren.")
        return 1

    report("vorher", *before)
    after_frames, mism_after = report("nachher", *after)

    print("\n== Stereo-Kohaerenz ==")
    print("BESTANDEN" if not mism_after else f"NICHT BESTANDEN: {len(mism_after)} Frames mit L != R")

    print("\n== Vergleich gegen die Voraufnahme ==")
    offset = find_offset(after[0], before[0], len(after_frames))
    if offset is None:
        print("Versatz nicht bestimmbar — Aufnahmen teilen kein gemeinsames Fenster.")
        print("Das ist kein Fehler, aber ohne Versatz ist kein Bytevergleich moeglich.")
        return 0

    print(f"Versatz: {offset:+d} Frames (~{offset / 48.0:+.2f} ms bei 48 kHz)")

    old = before[1]
    diffs = []
    for i, frame in enumerate(after_frames):
        j = i + offset
        if 0 <= j < len(old) and frame != old[j]:
            diffs.append(i)

    print(f"Abweichende Frames nach Ausrichtung: {len(diffs)}")
    if diffs:
        print(f"  erste: {diffs[:10]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
