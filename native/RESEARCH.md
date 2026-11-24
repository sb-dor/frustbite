# Opus crate research (stage 1, Task 3)

Date: 2026-11-24. Toolchain: Rust 1.100.0, macOS aarch64, release build with
`lto = "fat"`, `codegen-units = 1`.

Constraints: pure Rust (no C), builds for `wasm32-unknown-unknown`, licences
MIT / Apache-2.0 / BSD / Zlib / MPL-2.0 only.

## Decision

**Use `opus-pure` 0.2.5** (BSD-3-Clause) as the Opus decoder, wrapped in a
small custom Symphonia `AudioDecoder` registered in a `CodecRegistry`.
Fallback if the wrapper turns out to be a problem: `symphonia-opus` 0.1.3
(MPL-2.0), which is already a drop-in Symphonia 0.6 decoder.

Why `opus-pure`:

- It passes all 12 RFC 8251 vectors with the best quality score of the four
  (lowest Q 99.72 of 100), and matches `ffmpeg`/libopus float output to 134 dB
  SNR on `tone.opus`.
- It is the only candidate that is both fast (4.5 ms per `tone.opus` decode)
  and has an **encoder** (plus Ogg and CAF muxing) for stage 3, so stage 1
  and stage 3 use one codec implementation. No dependencies, no `build.rs`.
- `opus-decoder` is 85x slower and the least accurate. `ropus` is fast and
  has an encoder but is a fixed-point port, so its output differs from
  libopus float by up to 2.4e-4 (73 dB SNR) and about 30-45 % of i16 samples
  differ from the reference on some vectors.
- `symphonia-opus` is slightly faster and fully safe, but has no encoder (a
  second crate would be needed in stage 3), has only about 2.7k downloads and
  is a packaged copy of an unmerged Symphonia PR (#398).

Concerns with `opus-pure`: 162 `unsafe` occurrences (SIMD kernels behind
`cfg(target_arch)`, not forbidden; `opus-decoder` and `symphonia-opus` are
`forbid(unsafe_code)`), and it is a fork of an earlier crate maintained by one
author. Mitigations: it is checked against libopus 1.6.1 in its own CI, and
the wasm build and our conformance run both pass.

## Candidates

All crates listed on crates.io as pure-Rust Opus on 2026-11-24 were looked at.
Four were benchmarked. Others (`moosicbox_opus_native` MPL-2.0 v0.5.0,
`tpt-av-cadence-opus` v0.1.0 with 13 downloads, `mousiki`, `oporus`) were not
tested: they are small or experimental, and the four below already cover the
decision.

| | `opus-decoder` 0.1.1 | `ropus` 0.12.18 | `opus-pure` 0.2.5 | `symphonia-opus` 0.1.3 |
|---|---|---|---|---|
| Licence | MIT OR Apache-2.0 | BSD-3-Clause | BSD-3-Clause | MPL-2.0 |
| Pure Rust, no C | yes | yes | yes | yes |
| Runtime deps | none | none (bytemuck seen in tree) | none | symphonia-core, log, thiserror |
| `unsafe` | forbidden | present (12 in src) | present (162) | forbidden |
| RFC 8251 vectors (opus_compare, ref `.dec`) | 12/12 pass, min Q 19.56 | 12/12 pass, min Q 97.50 | 12/12 pass, min Q 99.72 | 12/12 pass, min Q 81.31 |
| `tone.opus` vs ffmpeg (libopus) f32 | 91.4 dB, max 3.4e-5 | 73.2 dB, max 2.5e-4 | 133.8 dB, max 2.5e-6 | 135.0 dB, max 2.4e-6 |
| Speed, `tone.opus` x100 | **381.5 ms** | 5.41 ms | 4.52 ms | 3.93 ms |
| `wasm32-unknown-unknown` release build | passes (250 KB) | passes (312 KB) | passes (314 KB) | passes (39 KB, with symphonia-core) |
| Encoder | no | yes (`Encoder`, `OpusMSEncoder`) | yes (+ Ogg and CAF mux) | no |
| Symphonia integration | none (raw packets) | none | none (raw packets) | ready-made `AudioDecoder` + `RegisterableAudioDecoder` |

### Conformance method

Vectors: `opus_testvectors-rfc8251.tar.gz` from
https://opus-codec.org/static/testvectors/ (12 `.bit` streams, reference
`.dec` output, 48 kHz stereo). Each candidate decoded every packet at 48 kHz
stereo and the result was compared with the `.dec` reference using a Rust
port of the RFC 6716 Appendix A `opus_compare` quality metric (taken from the
`symphonia-opus` test suite; Q >= 0 passes, Q = 100 is identical). The port
was not cross-checked against the C tool, which is not installed here.

Q per vector against the RFC 8251 `.dec` (all PASS):

| vec | opus-decoder | ropus | opus-pure | symphonia-opus |
|---|---|---|---|---|
| 01 | 99.46 | 98.81 | 99.90 | 86.20 |
| 02-04 | 100.00 | 100.00 | 100.00 | 100.00 |
| 05 | 56.77 | 98.26 | 99.83 | 81.74 |
| 06 | 37.68 | 98.44 | 99.80 | 81.31 |
| 07 | 99.52 | 98.28 | 99.86 | 88.49 |
| 08 | 98.99 | 98.20 | 99.83 | 83.57 |
| 09 | 99.41 | 97.98 | 99.82 | 85.71 |
| 10 | 19.56 | 98.21 | 99.72 | 87.44 |
| 11 | 99.12 | 98.55 | 99.80 | 95.39 |
| 12 | 26.34 | 97.50 | 99.85 | 82.93 |

Notes:

- The `m.dec` files are the older (pre-RFC 8251) alternate references. Vector
  07 fails against `m.dec` for all four candidates identically (about -21.9),
  so it does not discriminate; the RFC 8251 `.dec` is the one that counts.
- For `symphonia-opus` the "exact-diff" rate is about 49 % of i16 samples but
  max difference is 1 LSB, i.e. float to i16 rounding in my f32 to i16
  conversion, not a decode error. Its f32 output on `tone.opus` is the closest
  to libopus of all four.
- `tone.opus` check: ffmpeg (libopus) `-f f32le` output vs each decoder's f32
  output after dropping the 312 sample pre-skip (ffmpeg also trims the 648
  end samples). Only the first 144000 frames were compared.
- Only 48 kHz stereo was exercised (the output rate we will use). Mono, other
  rates, multistream and packet-loss concealment were not tested by me.

### Speed method

`tone.opus` (3.0 s, stereo, 151 packets) demuxed once with Symphonia, then all
packets decoded to a fresh `Vec` x100 after one warm-up pass, mean ms per
full decode. Each candidate's wrapper zero-fills a 5760-frame buffer per
packet, so absolute numbers are slightly pessimistic but comparable.
`opus-decoder` is 70-100x slower than the others on every vector too
(1.5-3.9 s vs 40-70 ms on the 60 s test vectors), so it is unusable for
anything but short clips. It is roughly 8x realtime at best. No cause was
investigated.

## Encoder availability (for stage 3)

- `opus-pure` 0.2.5: full encoder (SILK, CELT, hybrid; mono/stereo; all frame
  sizes), multistream encoder, `OggOpusWriter`, `OpusHead::for_encoder`
  (derives the correct pre-skip), CAF mux/demux.
- `ropus` 0.12.18: `Encoder`, `OpusMSEncoder`; no container code.
- `opus-decoder`, `symphonia-opus`: decode only.

## Symphonia 0.6.1 notes

- There is **no Opus decoder in Symphonia 0.6.1** (no `opus` feature in
  `symphonia`). The demuxers do support Opus: codec id is
  `symphonia::core::codecs::audio::well_known::CODEC_ID_OPUS` (0x1001; 0.6
  renamed `CODEC_TYPE_*` to `CODEC_ID_*`, and `CodecParameters::Audio(..)` /
  `AudioCodecParameters`).
- **Ogg** (`.opus`, `.ogg`): codec params have `codec = CODEC_ID_OPUS`,
  `sample_rate = 48000`, channels from OpusHead, and `extra_data` = the whole
  `OpusHead` packet (19 bytes for `tone.opus`). Pre-skip is also exposed as
  `Track::delay` (312 for `tone.opus`). Packets carry `dur` 960 and the last
  packet has `trim_end = 648`. The first packet has **no** `trim_start`, so
  the start pre-skip must be dropped by us.
- **Matroska / WebM** (`A_OPUS`): `extra_data` = `CodecPrivate` = `OpusHead`
  (19 bytes for `tone.webm`), channels `Discrete(2)`, `Track::delay` is `None`
  (codec delay is applied to timestamps instead). So always read pre-skip
  from `OpusHead` bytes 10-11 (little-endian), not from `Track::delay`.
- **MP4** (`Opus` + `dOps`): reader exists and builds an `OpusHead`-prefixed
  `extra_data`, but by reading the 0.6.1 source it copies the big-endian
  `dOps` fields verbatim, so pre-skip and output gain are byte-swapped
  (`symphonia-opus` README says the same, fixed upstream in PR #617). There is
  no Opus-in-MP4 fixture, so I did not test it. Stage 1 should either not
  claim Opus-in-MP4 or byte-swap those two fields.
- `AudioDecoder` implementations do not trim: `decode()` only calls
  `decode_ref()`. Trimming from `Packet::trim_start` / `trim_end` and the
  pre-skip is up to the caller (frustbite).
- Registry API: `CodecRegistry::new()`, then
  `symphonia::default::register_enabled_codecs(&mut reg)`, then
  `reg.register_audio_decoder::<D>()` (or `register_audio_decoder_at_tier`),
  and `reg.make_audio_decoder(&AudioCodecParameters, &AudioDecoderOptions)`.
  `D` implements `AudioDecoder` and `RegisterableAudioDecoder`
  (`try_registry_new`, `supported_codecs`).

## How to plug `opus-pure` into Symphonia (Task 4)

1. Add `opus-pure = "=0.2.5"` behind the `opus` feature of `native`, and no
   `symphonia-opus`.
2. Write `OpusDecoder` implementing `AudioDecoder` + `RegisterableAudioDecoder`
   for `CODEC_ID_OPUS`:
   - Parse `extra_data` as `OpusHead` yourself (`OpusHead::parse` is
     `pub(crate)`): byte 9 channel count, bytes 10-11 pre-skip (LE `u16`),
     bytes 16-17 output gain (LE `i16`, Q7.8 dB), byte 18 mapping family.
     If `extra_data` is missing, assume stereo/mono from the params, pre-skip
     0, gain 0.
   - Family 0 (1-2 channels): `opus_pure::OpusDecoder::new(48_000, channels)`
     and set `decoder.gain_q8 = output_gain`. Family 1 or other: use
     `OpusMSDecoder::new(48_000, channels, family)`, or return
     `unsupported` in stage 1.
   - `decode_ref`: `decode(packet, 5760, &mut buf)` (f32 interleaved, 5760
     frames per channel is the 120 ms maximum), then copy into a Symphonia
     `AudioBuffer<f32>` as planar. Use `decode_s16` only if i16 is wanted
     (it soft-clips). An empty packet means loss: call `decode` with an empty
     slice for PLC. Clear the buffer on error, as the trait requires.
   - `reset()`: `reset_state()`.
3. **Output is always 48 kHz.** Report `sample_rate = 48_000` (what the Ogg
   mapper already sets), and do not resample in Rust in stage 1. If a lower
   output rate is wanted later, `OpusDecoder` supports 8/12/16/24 kHz natively
   (pre-skip then scales by `rate / 48000`).
4. **Pre-skip**: drop the first `pre_skip` frames of decoded output at 48 kHz
   (312 for `tone.opus`) in the frustbite reader loop, not inside the
   decoder, and drop `trim_end` frames from the last packet (Symphonia
   already provides it for Ogg). This reproduces ffmpeg's 144000 frames for
   `tone.opus` (151 packets x 960 = 144960, minus 312 pre-skip, minus 648
   end trim). Use `OpusHead` pre-skip for all containers (see WebM / MP4
   notes above), not `Track::delay`.
5. Register with `register_audio_decoder` (Standard tier) in the registry that
   `native` builds, after `register_enabled_codecs`, only when the `opus`
   feature is on.
6. Add a regression test that decodes `tone.opus` and `tone.webm` and checks
   frame count (144000) and the first non-silent frame against the ffmpeg
   output.

## Reproduction

Throwaway crates (not committed) lived under the session scratchpad:
`opus-research/` (harness: vectors, `tone` speed, `probe` of Symphonia
tracks) and `wasmcheck/` (`cargo +1.100.0 build --release --target
wasm32-unknown-unknown --no-default-features --features od|ro|op|so`).
