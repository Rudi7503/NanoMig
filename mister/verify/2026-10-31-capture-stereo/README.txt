Capture stereo verification, 2026-10-31, Tobys KI

stream.raw: new single-channel capture after the coherence fix, Big-Endian signed int16 L/R interleaved, 65536 frames / 262144 bytes.
SHA256 9468d7a0e446cb839ece4c1eca557e9d6a08fdee41ea7c813523c086545955fd
Hardware RBF SHA256 541e947fd940300a74a7fe1e191cd9d5341eb8f2e002d6e43bcc98b9999f0921
Source basis 3fba796f7253e4df30b9baf58f5114ccf49db882 plus local project-path corrections, audio_ext signed mixer correction, and capture coherence correction. Compiled capture file equals 225e8d5d35051fc4223ce54783151dde06c55dd6 after CRLF/LF normalization. Not a clean checkout of that commit.

Verified: source recording hash/length; Rudi's unchanged check_capture.py executed locally; L!=R=0, previously57; full64blocks, no reported overrun/timeout, no fullscale clips; user heard steady undisturbed tone. WAV payload separately matched new raw after endian conversion.
Not verified: offset/whole-stream equivalence against old free-running recording (script found no exact512frame windows); full continuity; full32channel/ADPCM/filter/modulation coverage; timing qualification. This capture predates the later filter/PCM-loop builds. WAV deliberately excluded.

Run: python check_capture.py
See analysis.log and timing.json. Negative Setup/Hold values are from different corners of the same summary. SDC comparison and mixer-change diff remain pending.
