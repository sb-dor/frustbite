#!/usr/bin/env bash
# Builds every frustbite native library that can be built on this host, named
# like the GitHub release assets, by calling packages/frustbite/tool/build.dart.
#
# Usage: scripts/build.sh [output-dir] [target...]
#   output-dir  defaults to <repo>/build/assets
#   target...   overrides the host's default target list (see tool/build.dart)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$root/build/assets}"
[ "$#" -gt 0 ] && shift
# The build runs from packages/frustbite, so a relative dir must be resolved first.
mkdir -p "$out"
out="$(cd "$out" && pwd)"

if [ "$#" -gt 0 ]; then
  targets=("$@")
else
  targets=()
  case "$(uname -s)" in
    Darwin)
      targets+=(macos_arm64 macos_x86_64 ios_arm64 ios_sim_arm64 ios_sim_x86_64)
      ;;
    Linux)
      targets+=(linux_x86_64)
      if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
        targets+=(linux_aarch64)
      else
        echo "skipping linux_aarch64: aarch64-linux-gnu-gcc not found"
      fi
      ;;
    MINGW* | MSYS* | CYGWIN*)
      targets+=(windows_x86_64 windows_arm64)
      ;;
    *)
      echo "unsupported host: $(uname -s)" >&2
      exit 1
      ;;
  esac

  # Android cross-compiles from macOS and Linux hosts when an NDK is available.
  case "$(uname -s)" in
    Darwin | Linux)
      ndk="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-}}"
      if [ -n "$ndk" ] && [ -d "$ndk" ]; then
        targets+=(android_armv7 android_arm64 android_x86_64)
      else
        echo "skipping android targets: ANDROID_NDK_ROOT/ANDROID_NDK_HOME not set"
      fi
      ;;
  esac
fi

echo "Building: ${targets[*]}"
echo "Output:   $out"

cd "$root/packages/frustbite"
dart pub get
dart tool/build.dart "$out" "${targets[@]}"

echo "Built ${#targets[@]} target(s):"
ls -l "$out"
