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

### Trade-off against `symphonia-opus`, stated plainly

`symphonia-opus` 0.1.3 is on the numbers at least as good as `opus-pure` for
decoding: slightly faster (3.93 vs 4.52 ms), equal or better fidelity to
libopus on `tone.opus` (135.0 vs 133.8 dB), `forbid(unsafe_code)`, and it is
already a Symphonia decoder (pre-skip, gain, multistream handled). Its
downsides are that it has **no encoder** and is a packaged copy of an unmerged
Symphonia PR (#398) with about 2.7k downloads.

We choose `opus-pure` for one reason: **one codebase can decode and encode**,
which pays off in stage 3 (no second Opus implementation in the binary, one
set of bugs, one pre-skip convention via `OpusHead::for_encoder`). We accept
a higher stage-1 risk to get that, plus about 100 lines of wrapper code that
`symphonia-opus` would have saved us.

Cost if stage 3 ends up using a different encoder (for example `ropus`, or
`symphonia-opus` for decoding plus another crate for encoding): the argument
for `opus-pure` disappears, we carry two Opus implementations (about 300 KB
each in wasm), and the wrapper written in Task 4 becomes dead weight that
should be replaced by `symphonia-opus`. Keep the wrapper small and isolated
(one module behind the `opus` feature) so that swap is cheap.

### Maturity risk of `opus-pure`

- Young: crates.io shows it was created 2026-08-27, under three months before
  this research. 0.2.4 and 0.2.5 were both published on 2026-11-23, so the
  release churn is high and a 0.3 with breaking API changes is plausible.
- Single maintainer (the README credits one author; the crate is a fork of an
  earlier crate from restsend.com).
- 162 `unsafe` sites, in SIMD kernels behind `cfg(target_arch)`; the crate does
  not forbid unsafe. The only evidence for their soundness is the crate's own
  CI (bit-exactness against libopus 1.6.1 on four platforms) and its fuzz
  targets. Our own conformance check covered only 48 kHz stereo; mono,
  multistream and packet-loss concealment were not exercised.
- Downloads are about 120k, so there is real use, but it is not a long-lived
  crate.

Pin the exact version (`=0.2.5`) and review the changelog before every bump.

### Fallback trigger: switch to `symphonia-opus`

Switch the stage-1 decoder to `symphonia-opus` (and drop the wrapper) if any
of these happens:

1. Any conformance failure on our own fixtures (`tone.opus`, `tone.webm`):
   frame count different from 144000, or decoded audio differing from the
   ffmpeg reference by more than 60 dB SNR.
2. A crash, panic on valid input, or undefined behaviour (for example found by
   Miri or fuzzing) in `opus-pure`'s decode path that upstream does not fix
   within one release.
3. The crate is yanked, is declared abandoned, or has no release and no reply
   to an issue for 6 months while a defect of ours is open.
4. A breaking release that we cannot adopt cheaply, or a licence change.
5. A platform build failure (wasm or mobile) that appears in a later version.

If the switch happens before stage 3, stage 3 chooses an encoder separately.

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
| Runtime deps | none | `wide` (pulls in `bytemuck`, MIT/Apache/Zlib) | none | symphonia-core, log, thiserror |
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
- **MP4** (`Opus` + `dOps`): the reader exists and builds an `OpusHead`
  prefixed `extra_data`, but by reading the 0.6.1 source it copies the
  big-endian `dOps` fields verbatim, so pre-skip and output gain are
  byte-swapped (`symphonia-opus` README says the same; fixed upstream in
  PR #617). There is no fixture and I did not test it. **Decision (ruling
  R8): Opus-in-MP4 is NOT supported in stage 1; opening it returns
  `UnsupportedFormat`.** The decoder wrapper must not be reached for MP4
  Opus tracks.
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
   - **Validate `OpusHead`** from `extra_data` (`OpusHead::parse` is
     `pub(crate)`, so parse it ourselves): length at least 19 bytes; magic
     `OpusHead`; version byte (byte 8) has major nibble 0 (`version >> 4 == 0`,
     as RFC 7845 requires); channel count (byte 9) not 0; for family 0 the
     count is 1 or 2. Then read pre-skip (bytes 10-11, LE `u16`), output gain
     (bytes 16-17, LE `i16`, Q7.8 dB) and mapping family (byte 18). A missing,
     short or invalid `extra_data` returns an error (`DecodeError`, or
     `Unsupported` for an unsupported mapping family); never guess channels
     from the params or default the pre-skip.
   - Family 0 (1-2 channels): `opus_pure::OpusDecoder::new(48_000, channels)`
     and set `decoder.gain_q8 = output_gain`. Family 1 or others: return
     `Unsupported` in stage 1 (`OpusMSDecoder` can be added later).
   - **Output layout**: planar `f32` Symphonia `AudioBuffer<f32>` (read via
     `GenericAudioBufferRef`) with spec rate 48 000 Hz and the channel count
     from `OpusHead`, capacity 5760 frames (120 ms). `decode_ref` calls
     `decode(packet, 5760, &mut interleaved)` and de-interleaves into the
     planes. Use `decode_s16` only if i16 is wanted (it soft-clips). An empty
     packet is loss: call `decode` with an empty slice (PLC). On error clear
     the buffer, as the trait requires. `reset()` calls `reset_state()`.
   - **Declare support** as `symphonia-opus` does: a static
     `SupportedAudioCodec { id: CODEC_ID_OPUS, info: CodecInfo { .. } }` array
     returned from `RegisterableAudioDecoder::supported_codecs()`, and
     `try_registry_new` returning `Box::new(Self::try_new(params, opts)?)`.
     Register with `registry.register_audio_decoder::<OpusDecoder>()` after
     `symphonia::default::register_enabled_codecs`, only when the `opus`
     feature is on.
3. **Output is always 48 kHz.** Report `sample_rate = 48_000` (what the Ogg
   mapper already sets) and do not resample in Rust in stage 1.
4. **Pre-skip and end trim** are done by frustbite's read loop, not by the
   decoder. Pre-skip: drop the first `pre_skip` frames (312 for `tone.opus`)
   of 48 kHz output, always taken from `OpusHead`, not `Track::delay`.
   - **Ogg**: Symphonia derives the end trim from the final granule position
     and sets `trim_end` on the last packet (648 for `tone.opus`); drop those
     frames. Result: 151 x 960 = 144960, minus 312, minus 648 = 144000, which
     matches ffmpeg.
   - **WebM**: Symphonia 0.6.1 applies `CodecDelay` to timestamps (negative
     start) but does **not** produce an end trim: the Matroska `DiscardPadding`
     element is parsed but never reaches `Packet::trim_end` (confirmed by
     reading the source; `tone.webm` packets have no trim). We therefore do
     not trim the end in WebM and accept the tail padding (up to one packet,
     at most 120 ms of extra trailing samples; for `tone.webm`, 3.0 s plus a
     few ms). Still drop `pre_skip` frames at the start.
   - **Duration reporting**: `frames = total decoded - pre_skip - end trim`
     for Ogg; for WebM report the container duration if present, else the
     decoded count minus pre-skip. `Track::num_frames` for Ogg already
     includes the trim logic (144312 for `tone.opus` is the granule value
     before the pre-skip, so subtract `pre_skip` (312) to get 144000).
   - **Seeking**: stage 1 has no seeking (ruling R9). A future seek must
     start decoding at least 80 ms (3840 frames) before the target and discard
     the output (RFC 7845 section 4.2).
5. Keep the wrapper in one module so it can be replaced by `symphonia-opus`
   (see the fallback trigger).
6. Add a regression test that decodes `tone.opus` and `tone.webm` and checks
   frame count (144000) and the first non-silent frame against the ffmpeg
   output.

## Reproduction

Throwaway crates (not committed) lived under the session scratchpad:
`opus-research/` (harness: vectors, `tone` speed, `probe` of Symphonia
tracks) and `wasmcheck/` (`cargo +1.100.0 build --release --target
wasm32-unknown-unknown --no-default-features --features od|ro|op|so`).
