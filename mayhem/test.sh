#!/usr/bin/env bash
#
# glog/mayhem/test.sh — build glog's OWN unit-test suite with NORMAL flags (clean, separate tree)
# and RUN the self-contained subset via ctest, emitting a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: these are glog's real gtest-based unit tests. The headline one is `demangle`
# (src/demangle_unittest.cc) — it asserts that google::Demangle() produces the EXPECTED
# human-readable string for a large table of mangled symbols, i.e. exactly the function the
# fuzz harness drives. We force WITH_FUZZING=libfuzzer in the test build because glog DISABLES the
# demangle test whenever the platform's abi::__cxa_demangle is available (CMakeLists.txt:165-169);
# with fuzzing enabled glog uses its own demangler and the test is active. `logging`,
# `stl_logging`, `utilities`, `log_severity*`, `striplog*` and the `cleanup_*` tests assert real
# logging behaviour. A no-op / exit(0) patch to the demangler cannot satisfy the expected-output
# assertions. This script COMPILES the test binaries (independently of build.sh) then RUNS them.
#
# We EXCLUDE the platform/environment-fragile tests (stacktrace, symbolize, the includes_* C/C++
# header-compile checks, and the cmake_package_config_* meta-tests) — same set OSS-Fuzz excludes
# in run_tests.sh, plus the cmake_package tests which need a network/toolchain fixture.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

BUILDDIR="$SRC/mayhem-tests"
: "${MAYHEM_JOBS:=$(nproc)}"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v cmake >/dev/null 2>&1 || ! command -v ctest >/dev/null 2>&1; then
  echo "cmake/ctest not available — cannot build/run the test suite" >&2
  emit_ctrf "glog-ctest" 0 1 0; exit 2
fi

# Build the test suite with NORMAL flags (no sanitizers) so test.sh is an honest PATCH oracle.
# WITH_FUZZING=libfuzzer keeps glog's own demangler active so the `demangle` test runs.
echo "=== configuring glog test suite in $BUILDDIR ==="
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake -S "$SRC" -B "$BUILDDIR" \
    -DBUILD_TESTING=ON -DWITH_GTEST=OFF -DWITH_GFLAGS=OFF -DWITH_FUZZING=libfuzzer \
    -DCMAKE_BUILD_TYPE=None >/dev/null 2>&1 \
  || env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
       cmake -S "$SRC" -B "$BUILDDIR" \
         -DBUILD_TESTING=ON -DWITH_GTEST=OFF -DWITH_GFLAGS=OFF -DWITH_FUZZING=libfuzzer \
         -DCMAKE_BUILD_TYPE=None

# Build only the test binaries backing the tests we will run (avoid the fuzz_demangle target,
# which needs the libFuzzer runtime to link as a normal exe).
TARGETS="demangle_unittest logging_unittest stl_logging_unittest \
         striplog0_unittest striplog2_unittest striplog10_unittest \
         cleanup_immediately_unittest cleanup_with_absolute_prefix_unittest \
         cleanup_with_relative_prefix_unittest"
echo "=== building test targets ==="
if ! env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
      cmake --build "$BUILDDIR" --target $TARGETS -j"$MAYHEM_JOBS"; then
  echo "test suite failed to build" >&2
  emit_ctrf "glog-ctest" 0 1 0; exit 1
fi

# Run an explicit allowlist of self-contained tests (all backed by the binaries built above):
#   demangle              — google::Demangle expected-output table (the harness surface)
#   logging / stl_logging — core logging behaviour
#   log_severity_*        — severity enum/string round-trips
#   striplog*             — VLOG/stripping behaviour via logging_unittest
#   cleanup_*             — log-file cleanup (init/run/logdir teardown chain)
# Excluded (same spirit as OSS-Fuzz run_tests.sh): stacktrace, symbolize, the includes_* header
# compile-checks, the cmake_package_config_* network/toolchain meta-tests, and signalhandler.
echo "=== running ctest subset ==="
INCLUDE="^(demangle|logging|stl_logging|log_severity_constants|log_severity_conversion|striplog0|striplog2|striplog10|cleanup_init|cleanup_logdir|cleanup_immediately|cleanup_with_absolute_prefix|cleanup_with_relative_prefix)$"
out="$(ctest --test-dir "$BUILDDIR" -R "$INCLUDE" --output-on-failure 2>&1)"; rc=$?
echo "$out"

# ctest prints:  "NN% tests passed, F tests failed out of T"
read -r PASS_TOTAL FAIL_TOTAL TOTAL < <(printf '%s\n' "$out" | sed -n \
  's/^[0-9]*% tests passed, \([0-9][0-9]*\) tests failed out of \([0-9][0-9]*\).*/X \1 \2/p' | tail -1 \
  | awk '{print $3-$2, $2, $3}')
: "${PASS_TOTAL:=0}" "${FAIL_TOTAL:=0}" "${TOTAL:=0}"

if [ "$TOTAL" -eq 0 ]; then
  echo "could not parse ctest summary; using ctest exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "glog-ctest" 1 0 0; exit 0; }
  emit_ctrf "glog-ctest" 0 1 0; exit 1
fi

emit_ctrf "glog-ctest" "$PASS_TOTAL" "$FAIL_TOTAL" 0
