#!/usr/bin/env bash
# Checks a built frustbite native library before it is shipped.
# Adapted from PlugFox/ws (MIT), tool/verify_native.sh.
#
# Usage: tool/verify_native.sh <file> <target>
#   <file>    the built libfrustbite.so / libfrustbite.dylib / frustbite.dll
#   <target>  a name from packages/frustbite/lib/src/hook/targets.dart, e.g.
#             macos_arm64, ios_sim_arm64, linux_x86_64, android_arm64, windows_x86_64
#
# Fails on:
#   - an exported symbol that is not `frustbite_*` (a short allow-list of
#     linker-defined ELF symbols aside), or an export count other than 16;
#   - Android: a LOAD segment not aligned to 16 KB (Google Play);
#   - Linux: a glibc symbol newer than 2.17, or a NEEDED library outside
#     libc/libm/libdl/libpthread/librt/ld-linux (no libgcc_s: build.rs links it
#     statically);
#   - Apple: an install name other than @rpath/libfrustbite.dylib, or a minimum
#     OS version different from the one the build pins (target_versions.dart);
#   - Windows: an import of the VC++ runtime (VCRUNTIME*, MSVCP*): the CRT must
#     be linked statically (+crt-static in native/.cargo/config.toml).
#
# Tools: ELF targets use `readelf` (or `llvm-readelf`), which reads every
# architecture (`nm`/`objdump` on an x86 runner cannot read aarch64 files).
# Apple targets use `nm` and `otool`. Windows uses `llvm-objdump` (preinstalled
# on windows-latest under C:\Program Files\LLVM\bin) or `dumpbin`.
set -euo pipefail

file="${1:?usage: tool/verify_native.sh <file> <target>}"
target="${2:?usage: tool/verify_native.sh <file> <target>}"
[[ -f "$file" ]] || { echo "verify $target: missing $file" >&2; exit 1; }

# The exported C functions: every `frustbite_*` function in native/src/ffi.rs
# (wasm_alloc.rs adds two more, but only on wasm32). Change it together with the
# FFI surface.
EXPECTED_EXPORTS=16
# Mirror macOSTargetVersion and iOSTargetVersion in
# packages/frustbite/lib/src/hook/target_versions.dart.
MACOS_MINOS=13.0
IOS_MINOS=16.0
GLIBC_FLOOR=2.17
# Symbols the GNU linker may define in a shared object; they are not our API.
ELF_LINKER_SYMBOLS=" _init _fini _edata _end __bss_start "

fail() {
  echo "verify $target: $*" >&2
  exit 1
}

# check_exports <prefix>: reads exported symbol names on stdin.
check_exports() {
  local prefix="$1" name count=0 others=()
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ "$name" == "$prefix"* ]]; then
      count=$((count + 1))
    elif [[ "$ELF_LINKER_SYMBOLS" == *" $name "* ]]; then
      :
    else
      others+=("$name")
    fi
  done
  echo "exports: $count ${prefix}* functions"
  [[ ${#others[@]} -eq 0 ]] || fail "unexpected exported symbols: ${others[*]}"
  [[ "$count" -eq "$EXPECTED_EXPORTS" ]] \
    || fail "$count ${prefix}* exports, expected $EXPECTED_EXPORTS"
}

elf_tool() {
  if command -v llvm-readelf >/dev/null 2>&1; then
    llvm-readelf "$@"
  else
    readelf "$@"
  fi
}

# Defined, global or weak, default-visibility dynamic symbols, without @VERSION.
elf_exports() {
  elf_tool --dyn-syms -W "$file" \
    | awk '$1 ~ /:$/ && NF >= 8 && $7 != "UND" && ($5 == "GLOBAL" || $5 == "WEAK") && $6 == "DEFAULT" {sub(/@.*/, "", $8); print $8}'
}

check_apple() {
  local expected_minos="$1" install_name minos
  nm -gU "$file" | awk '{print $NF}' | check_exports _frustbite_
  install_name="$(otool -D "$file" | sed -n '2p')"
  [[ "$install_name" == "@rpath/libfrustbite.dylib" ]] \
    || fail "install name is '$install_name', expected @rpath/libfrustbite.dylib"
  # minos sits in LC_BUILD_VERSION (arm64, simulators) or in
  # LC_VERSION_MIN_* as `version` (older x86_64 builds).
  minos="$(otool -l "$file" | awk '
    /LC_BUILD_VERSION/ {b = 1}
    /LC_VERSION_MIN_/ {v = 1}
    b && $1 == "minos" {print $2; exit}
    v && $1 == "version" {print $2; exit}')"
  echo "install name: $install_name, minos: $minos"
  [[ "$minos" == "$expected_minos" ]] \
    || fail "minos is '$minos', expected $expected_minos (deployment target not honoured)"
}

check_elf_common() {
  elf_exports | check_exports frustbite_
}

check_windows() {
  local dump="" tool
  for tool in llvm-objdump "/c/Program Files/LLVM/bin/llvm-objdump" "/c/Program Files/LLVM/bin/llvm-objdump.exe"; do
    if command -v "$tool" >/dev/null 2>&1 || [[ -x "$tool" ]]; then
      dump="$tool"
      break
    fi
  done
  if [[ -n "$dump" ]]; then
    local info
    info="$("$dump" -p "$file")"
    # Export table rows: "<ordinal> <rva> <name>".
    awk '/^Export Table:/ {e = 1; next} e && /^[A-Za-z]/ {e = 0}
         e && $1 ~ /^[0-9]+$/ && $2 ~ /^0x/ && NF == 3 {print $3}' <<<"$info" \
      | check_exports frustbite_
    if grep -Eiq 'DLL Name: *(vcruntime|msvcp|ucrtbase|api-ms-win-crt)' <<<"$info"; then
      fail "imports the VC++ runtime or the UCRT DLLs (link with +crt-static)"
    fi
  elif command -v dumpbin >/dev/null 2>&1; then
    dumpbin -exports "$file" | awk '$1 ~ /^[0-9]+$/ && NF >= 4 {print $NF}' | check_exports frustbite_
    if dumpbin -dependents "$file" | grep -Eiq 'vcruntime|msvcp'; then
      fail "imports the VC++ runtime (link with +crt-static)"
    fi
  else
    fail "neither llvm-objdump nor dumpbin found; cannot inspect the DLL"
  fi
}

case "$target" in
  macos_*) check_apple "$MACOS_MINOS" ;;
  ios_*) check_apple "$IOS_MINOS" ;;
  android_*)
    check_elf_common
    # Every LOAD segment's alignment is the last column of `readelf -lW`.
    aligns="$(elf_tool -lW "$file" | awk '$1 == "LOAD" {print $NF}' || true)"
    # An empty parse (a readelf format change, a stripped header) must not pass.
    [[ -n "$aligns" ]] || fail "no LOAD segments parsed from the program headers"
    bad="$(awk '$1 != "0x4000"' <<<"$aligns")"
    [[ -z "$bad" ]] || fail "LOAD segments not aligned to 16 KB: ${bad//$'\n'/ }"
    echo "LOAD segments: $(wc -l <<<"$aligns" | tr -d ' ') parsed, all 16 KB aligned"
    ;;
  linux_*)
    check_elf_common
    max="$(elf_tool --dyn-syms -W "$file" | grep -o 'GLIBC_[0-9][0-9.]*' | sort -uV | tail -1 || true)"
    echo "highest glibc symbol: ${max:-none}"
    if [[ -n "$max" ]]; then
      [[ "$(printf '%s\nGLIBC_%s\n' "$max" "$GLIBC_FLOOR" | sort -V | tail -1)" == "GLIBC_$GLIBC_FLOOR" ]] \
        || fail "needs $max, the floor is GLIBC_$GLIBC_FLOOR"
    fi
    needed="$(elf_tool -d -W "$file" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')"
    for lib in $needed; do
      case "$lib" in
        libc.so.6 | libm.so.6 | libdl.so.2 | libpthread.so.0 | librt.so.1 | ld-linux*) ;;
        *) fail "unexpected NEEDED library $lib" ;;
      esac
    done
    echo "NEEDED: ${needed//$'\n'/ }"
    ;;
  windows_*) check_windows ;;
  *) fail "unknown target" ;;
esac
echo "verified $target: $file"
