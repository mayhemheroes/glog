#!/usr/bin/env bash
#
# glog/mayhem/build.sh — build google/glog's single OSS-Fuzz harness as a sanitized libFuzzer
# target (+ a standalone run-once reproducer).
#
# Fuzzed surface: google::Demangle (src/demangle.cc), glog's self-contained Itanium C++ ABI
# name demangler used when symbolizing stack traces. The harness (src/fuzz_demangle.cc) copies
# the input into a stack buffer and calls google::Demangle(input, out[4096], size). Input bytes
# are a (possibly malformed) mangled C++ symbol — NOT a file format.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). glog builds with CMake; we compile the glog library ITSELF with
# $SANITIZER_FLAGS so the demangler code (not just the harness) is instrumented. The OSS-Fuzz
# build uses `-DWITH_FUZZING=ossfuzz`, which links fuzz_demangle against ${LIB_FUZZING_ENGINE}.
# We reuse that exact path:
#   * libFuzzer target  : LIB_FUZZING_ENGINE=-fsanitize=fuzzer            -> /mayhem/fuzz_demangle
#   * standalone repro  : LIB_FUZZING_ENGINE=<StandaloneFuzzTargetMain.o> -> /mayhem/fuzz_demangle-standalone
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# ── 1) libFuzzer target ───────────────────────────────────────────────────────────────────────
# -DWITH_FUZZING=ossfuzz adds fuzz_demangle and links it against ${LIB_FUZZING_ENGINE}.
# Sanitizers go on every TU via CMAKE_*_FLAGS so the glog static lib is instrumented too.
# CRITICAL: the ossfuzz CMake path only puts the libFuzzer engine on the link line, so the glog
# LIBRARY itself gets no SanitizerCoverage and the fuzzer is blind to the demangler. We add
# -fsanitize=fuzzer-no-link to the compile flags so every glog TU (incl. demangle.cc) is
# coverage-instrumented; the engine runtime is still pulled in at link via LIB_FUZZING_ENGINE.
LF_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
LF_BUILD="$SRC/mayhem-build/libfuzzer"
rm -rf "$LF_BUILD"; mkdir -p "$LF_BUILD"
cmake -S "$SRC" -B "$LF_BUILD" \
  -DWITH_FUZZING=ossfuzz -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DWITH_GTEST=OFF \
  -DCMAKE_BUILD_TYPE=None \
  -DCMAKE_C_FLAGS="$LF_FLAGS" -DCMAKE_CXX_FLAGS="$LF_FLAGS"
LIB_FUZZING_ENGINE="-fsanitize=fuzzer" \
  cmake --build "$LF_BUILD" --target fuzz_demangle -j"$MAYHEM_JOBS"
cp "$LF_BUILD/fuzz_demangle" /mayhem/fuzz_demangle
echo "built fuzz_demangle (libFuzzer)"

# ── 2) standalone run-once reproducer ───────────────────────────────────────────────────────────
# Compile the org StandaloneFuzzTargetMain to an object, then drive the SAME ossfuzz CMake path
# with LIB_FUZZING_ENGINE pointing at it — fuzz_demangle then links the run-once main instead of
# the libFuzzer runtime.
SA_MAIN_OBJ="$SRC/mayhem-build/standalone_main.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$SA_MAIN_OBJ"

SA_BUILD="$SRC/mayhem-build/standalone"
rm -rf "$SA_BUILD"; mkdir -p "$SA_BUILD"
cmake -S "$SRC" -B "$SA_BUILD" \
  -DWITH_FUZZING=ossfuzz -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DWITH_GTEST=OFF \
  -DCMAKE_BUILD_TYPE=None \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DLIB_FUZZING_ENGINE="$SA_MAIN_OBJ"
LIB_FUZZING_ENGINE="$SA_MAIN_OBJ" \
  cmake --build "$SA_BUILD" --target fuzz_demangle -j"$MAYHEM_JOBS"
cp "$SA_BUILD/fuzz_demangle" /mayhem/fuzz_demangle-standalone
echo "built fuzz_demangle-standalone (run-once)"

echo "build.sh complete:"
ls -la /mayhem/fuzz_demangle /mayhem/fuzz_demangle-standalone
