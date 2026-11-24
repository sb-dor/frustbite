#ifndef FRUSTBITE_H
#define FRUSTBITE_H

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

/**
 * ABI contract version. Increment for incompatible signatures, layouts, or IDs.
 */
#define FRUSTBITE_ABI_VERSION 1

/**
 * Pass as `format` to detect the container from the content.
 */
#define FRUSTBITE_FORMAT_DETECT UINT32_MAX

/**
 * Result of every fallible Frustbite function.
 *
 * New codes may be added in minor versions, so do not switch exhaustively over this
 * without a default case.
 *
 */
enum FrustbiteErrorCode
#if defined(__cplusplus) || __STDC_VERSION__ >= 202311L
  : uint32_t
#endif // defined(__cplusplus) || __STDC_VERSION__ >= 202311L
 {
  /**
   * The operation succeeded.
   */
  FrustbiteErrorCode_Success = 0,
  /**
   * The provided path is empty, malformed, or refers to a non-existent file.
   */
  FrustbiteErrorCode_InvalidPath = 1,
  /**
   * The audio format is not recognised or not supported by this build.
   */
  FrustbiteErrorCode_UnsupportedFormat = 2,
  /**
   * The audio bytes are corrupt or do not match the expected format.
   */
  FrustbiteErrorCode_DecodingError = 3,
  /**
   * An underlying I/O operation (read/write) failed.
   */
  FrustbiteErrorCode_IoError = 4,
  /**
   * A handle or output pointer was null, or the handle has been freed.
   */
  FrustbiteErrorCode_InvalidPointer = 5,
  /**
   * A scalar parameter is out of range.
   */
  FrustbiteErrorCode_InvalidParameter = 6,
  /**
   * An unclassified error occurred.
   */
  FrustbiteErrorCode_Unknown = 99,
};
#ifndef __cplusplus
#if __STDC_VERSION__ >= 202311L
typedef enum FrustbiteErrorCode FrustbiteErrorCode;
#else
typedef uint32_t FrustbiteErrorCode;
#endif // __STDC_VERSION__ >= 202311L
#endif // __cplusplus

/**
 * Container formats. Values are part of the ABI.
 *
 */
enum FrustbiteContainer
#if defined(__cplusplus) || __STDC_VERSION__ >= 202311L
  : uint32_t
#endif // defined(__cplusplus) || __STDC_VERSION__ >= 202311L
 {
  /**
   * MPEG audio stream.
   */
  FrustbiteContainer_Mp3 = 0,
  /**
   * ISO MP4 / M4A.
   */
  FrustbiteContainer_Mp4 = 1,
  /**
   * Native FLAC.
   */
  FrustbiteContainer_Flac = 2,
  /**
   * Ogg.
   */
  FrustbiteContainer_Ogg = 3,
  /**
   * RIFF WAVE.
   */
  FrustbiteContainer_Wav = 4,
  /**
   * Matroska / WebM.
   */
  FrustbiteContainer_Mkv = 5,
  /**
   * Raw AAC in ADTS frames.
   */
  FrustbiteContainer_Adts = 6,
};
#ifndef __cplusplus
#if __STDC_VERSION__ >= 202311L
typedef enum FrustbiteContainer FrustbiteContainer;
#else
typedef uint32_t FrustbiteContainer;
#endif // __STDC_VERSION__ >= 202311L
#endif // __cplusplus

/**
 * Audio codecs. Values are part of the ABI.
 *
 */
enum FrustbiteCodec
#if defined(__cplusplus) || __STDC_VERSION__ >= 202311L
  : uint32_t
#endif // defined(__cplusplus) || __STDC_VERSION__ >= 202311L
 {
  /**
   * MPEG-1/2 Layer III.
   */
  FrustbiteCodec_Mp3 = 0,
  /**
   * AAC-LC.
   */
  FrustbiteCodec_Aac = 1,
  /**
   * Apple Lossless.
   */
  FrustbiteCodec_Alac = 2,
  /**
   * FLAC.
   */
  FrustbiteCodec_Flac = 3,
  /**
   * Vorbis.
   */
  FrustbiteCodec_Vorbis = 4,
  /**
   * Opus.
   */
  FrustbiteCodec_Opus = 5,
  /**
   * Uncompressed PCM.
   */
  FrustbiteCodec_Pcm = 6,
};
#ifndef __cplusplus
#if __STDC_VERSION__ >= 202311L
typedef enum FrustbiteCodec FrustbiteCodec;
#else
typedef uint32_t FrustbiteCodec;
#endif // __STDC_VERSION__ >= 202311L
#endif // __cplusplus

/**
 * How a bucket's amplitude is computed. Values are part of the ABI.
 *
 */
enum FrustbiteWaveformMode
#if defined(__cplusplus) || __STDC_VERSION__ >= 202311L
  : uint32_t
#endif // defined(__cplusplus) || __STDC_VERSION__ >= 202311L
 {
  /**
   * Largest absolute sample value.
   */
  FrustbiteWaveformMode_Peak = 0,
  /**
   * Root mean square.
   */
  FrustbiteWaveformMode_Rms = 1,
};
#ifndef __cplusplus
#if __STDC_VERSION__ >= 202311L
typedef enum FrustbiteWaveformMode FrustbiteWaveformMode;
#else
typedef uint32_t FrustbiteWaveformMode;
#endif // __STDC_VERSION__ >= 202311L
#endif // __cplusplus

/**
 * An opened audio source. Immutable, so it can be shared between threads.
 */
typedef struct FrustbiteAudio FrustbiteAudio;

/**
 * Description of an opened audio source.
 */
typedef struct FrustbiteAudioInfo {
  /**
   * A `FrustbiteContainer` value.
   */
  uint32_t container;
  /**
   * A `FrustbiteCodec` value.
   */
  uint32_t codec;
  /**
   * Sample rate in Hz (Opus is always 48000).
   */
  uint32_t sample_rate;
  /**
   * Channel count.
   */
  uint32_t channels;
  /**
   * Bits per sample for PCM, FLAC and ALAC; 0 when not applicable.
   */
  uint32_t bits_per_sample;
  /**
   * Average bitrate in bits per second; 0 when unknown.
   */
  uint32_t bitrate;
  /**
   * Frames per channel, with encoder delay and padding trimmed as far as the container
   * allows:
   * - exact: WAV, FLAC, MP3 with a LAME/Xing header, Vorbis, Ogg Opus and ALAC;
   * - includes the 1024-frame encoder priming: AAC in MP4 (m4a, from the mdhd duration
   *   without the edit list) and ADTS; decoding yields priming plus padding, so it is not
   *   exactly the number of playable frames;
   * - WebM Opus can carry up to one packet of tail padding;
   * - MP3 without a LAME/Xing header is counted from the packets.
   */
  uint64_t total_frames;
  /**
   * Duration in microseconds.
   */
  uint64_t duration_us;
} FrustbiteAudioInfo;

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

/**
 * Returns `FRUSTBITE_ABI_VERSION`, so the Dart side can refuse a mismatched library.
 */
uint32_t frustbite_abi_version(void);

/**
 * Opens audio from memory. The bytes are copied. `format` is a `FrustbiteContainer` value or
 * `FRUSTBITE_FORMAT_DETECT`. On success `*out` receives a handle to release with
 * `frustbite_free`.
 *
 * # Safety
 * `data` must point to `len` readable bytes (it may be null only when `len` is 0, which is
 * rejected as an invalid pointer anyway); `out` must be valid for a pointer write.
 */
FrustbiteErrorCode frustbite_open_memory(const uint8_t *data,
                                         size_t len,
                                         uint32_t format,
                                         struct FrustbiteAudio **out);

/**
 * Opens audio from a file. `utf8_path` is a NUL-terminated UTF-8 path. Not available on wasm.
 *
 * # Safety
 * `utf8_path` must be a valid NUL-terminated string; `out` must be valid for a pointer write.
 */
FrustbiteErrorCode frustbite_open_file(const char *utf8_path,
                                       uint32_t format,
                                       struct FrustbiteAudio **out);

/**
 * Releases a handle. Passing null is a no-op.
 *
 * # Safety
 * `audio` must be null or a handle from `frustbite_open_*` that has not been freed yet.
 */
void frustbite_free(struct FrustbiteAudio *audio);

/**
 * Describes the audio. The result is cached after the first call.
 *
 * # Safety
 * `audio` must be a live handle; `out` must be valid for a `FrustbiteAudioInfo` write.
 */
FrustbiteErrorCode frustbite_get_info(const struct FrustbiteAudio *audio,
                                      struct FrustbiteAudioInfo *out);

/**
 * Bytes the handle keeps in memory, for memory accounting: the copied data for
 * `frustbite_open_memory`, 0 for `frustbite_open_file` (a file handle holds no bytes) and for
 * null. Does no I/O.
 *
 * # Safety
 * `audio` must be null or a live handle.
 */
size_t frustbite_source_byte_length(const struct FrustbiteAudio *audio);

/**
 * Decodes the whole source to interleaved f32 at its native sample rate and channel count.
 *
 * On success `*out_samples` receives a buffer of `*out_len` samples (frames x channels) to
 * release with `frustbite_free_f32` using the same length. A source without any audio frames
 * yields a null `*out_samples` with `*out_len` 0. Decoding is heavy: call it off the UI
 * thread.
 *
 * # Safety
 * `audio` must be a live handle; every out-pointer must be valid for a write.
 */
FrustbiteErrorCode frustbite_decode(const struct FrustbiteAudio *audio,
                                    float **out_samples,
                                    size_t *out_len,
                                    uint32_t *out_sample_rate,
                                    uint32_t *out_channels);

/**
 * Summarises the whole source into `buckets` amplitudes in [0, 1] for drawing a waveform.
 * `buckets` must be 1..=100000 and `mode` a `FrustbiteWaveformMode` value, else
 * `InvalidParameter`. On success `*out` receives `*out_len` floats, channel-major (all buckets
 * of channel 0, then channel 1, ...; one merged series unless `per_channel`), to release with
 * `frustbite_free_f32` using the same length. Values are absolute full scale, not normalised.
 * Heavy (decodes the whole source): call it off the UI thread.
 *
 * # Safety
 * `audio` must be a live handle; `out` and `out_len` must be valid for a write.
 */
FrustbiteErrorCode frustbite_waveform(const struct FrustbiteAudio *audio,
                                      uint32_t buckets,
                                      uint32_t mode,
                                      bool per_channel,
                                      float **out,
                                      size_t *out_len);

/**
 * Releases a buffer from `frustbite_decode` or `frustbite_waveform`. `len` must be the
 * `*out_len` it returned. Passing null is a no-op.
 *
 * # Safety
 * `ptr` must be null or a buffer returned by `frustbite_decode` or `frustbite_waveform` with
 * the same `len`, not yet freed.
 */
void frustbite_free_f32(float *ptr, size_t len);

/**
 * Reads the tags as UTF-8 JSON with the keys `title`, `artist`, `album`, `albumArtist`,
 * `genre`, `comment` (string or null) and `year`, `track`, `trackTotal`, `disc`, `discTotal`
 * (integer or null). A file without readable tags gives all nulls, not an error. On success
 * `*out` receives `*out_len` bytes (no NUL) to release with `frustbite_free_bytes`. Does I/O
 * on the first call (then cached): call it off the UI thread.
 *
 * # Safety
 * `audio` must be a live handle; `out` and `out_len` must be valid for a write.
 */
FrustbiteErrorCode frustbite_get_tags_json(const struct FrustbiteAudio *audio,
                                           uint8_t **out,
                                           size_t *out_len);

/**
 * Reads the embedded cover art (the front cover, else the first picture). On success `*out`
 * receives `*out_len` image bytes and `*out_mime` receives `*out_mime_len` bytes of the MIME
 * type as UTF-8 (no NUL), both to release with `frustbite_free_bytes`. With no cover, both
 * lengths are 0 and both pointers null, still `Success`. Does I/O on the first call (then
 * cached): call it off the UI thread.
 *
 * # Safety
 * `audio` must be a live handle; every out-pointer must be valid for a write.
 */
FrustbiteErrorCode frustbite_get_cover(const struct FrustbiteAudio *audio,
                                       uint8_t **out,
                                       size_t *out_len,
                                       uint8_t **out_mime,
                                       size_t *out_mime_len);

/**
 * Releases a buffer from `frustbite_get_tags_json` or `frustbite_get_cover`. `len` must be
 * the length it returned. Passing null is a no-op.
 *
 * # Safety
 * `ptr` must be null or a buffer returned by one of those functions with the same `len`, not
 * yet freed.
 */
void frustbite_free_bytes(uint8_t *ptr, size_t len);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  /* FRUSTBITE_H */
