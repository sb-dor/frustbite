#ifndef FRUSTBITE_H
#define FRUSTBITE_H

#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

/**
 * Result of every fallible Frustbite function.
 */
enum FrustbiteErrorCode
#if defined(__cplusplus) || __STDC_VERSION__ >= 202311L
  : uint32_t
#endif // defined(__cplusplus) || __STDC_VERSION__ >= 202311L
 {
  /**
   * The operation succeeded.
   */
  Success = 0,
  /**
   * The provided path is empty, malformed, or refers to a non-existent file.
   */
  InvalidPath = 1,
  /**
   * The audio format is not recognised or not supported by this build.
   */
  UnsupportedFormat = 2,
  /**
   * The audio bytes are corrupt or do not match the expected format.
   */
  DecodingError = 3,
  /**
   * An underlying I/O operation (read/write) failed.
   */
  IoError = 4,
  /**
   * A handle or output pointer was null, or the handle has been freed.
   */
  InvalidPointer = 5,
  /**
   * A scalar parameter is out of range.
   */
  InvalidParameter = 6,
  /**
   * An unclassified error occurred.
   */
  Unknown = 99,
};
#ifndef __cplusplus
#if __STDC_VERSION__ >= 202311L
typedef enum FrustbiteErrorCode FrustbiteErrorCode;
#else
typedef uint32_t FrustbiteErrorCode;
#endif // __STDC_VERSION__ >= 202311L
#endif // __cplusplus

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

/**
 * ABI contract version. Increment for incompatible signatures, layouts, or IDs.
 */
uint32_t frustbite_abi_version(void);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  /* FRUSTBITE_H */
