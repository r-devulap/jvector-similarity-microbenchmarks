#!/usr/bin/env bash
# run_benchmarks.sh
#
# Builds the fat-jar once per jvector version, then runs the JMH suite
# separately for each vectorization backend.
#
# Because VectorizationProvider is a JVM-lifetime singleton, each backend
# requires its own JVM process.  The script launches a separate invocation
# of the fat-jar per backend, passing the exact flags jvector requires.
#
# ┌──────────┬──────────────────────────────────────────────────────────────┐
# │ backend  │ JVM flags                                                    │
# ├──────────┼──────────────────────────────────────────────────────────────┤
# │ panama   │ --add-modules=jdk.incubator.vector                           │
# │          │   → PanamaVectorizationProvider (Panama Vector API / JIT)    │
# │ native   │ --add-modules=jdk.incubator.vector                           │
# │          │ --enable-native-access=ALL-UNNAMED                           │
# │          │ -Djvector.experimental.enable_native_vectorization=true      │
# │          │ -Djvector.enable_native_vectorization=true  (≥4.0.2)         │
# │          │   → NativeVectorizationProvider (Google Highway / JNI)       │
# └──────────┴──────────────────────────────────────────────────────────────┘
#
# Results land in:
#   results/<jvector-version>/<backend>/jmh-result.json   (machine-readable)
#   results/<jvector-version>/<backend>/jmh-result.txt    (human-readable)
#
# Usage:
#   ./run_benchmarks.sh                        # all versions × all backends
#   ./run_benchmarks.sh 4.0.1 4.0.2           # subset of versions
#
# Environment overrides:
#   BACKENDS   space-separated subset, e.g.  BACKENDS="scalar panama"
#   JMH_OPTS   extra JMH CLI options appended to every run, e.g. "-wi 5 -i 10"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
    cat <<'HELP'
Usage: run_benchmarks.sh [OPTIONS] [VERSION...]

Builds and runs JMH microbenchmarks for jvector VectorUtil similarity
functions (cosine, dotProduct, squareL2Distance) across multiple jvector
versions and SIMD backends.

Arguments:
  VERSION...          One or more jvector versions to benchmark.
                      Defaults to: 4.0.0-rc.9  4.0.1  4.0.2

Backends (run in order per version):
  panama              Panama Vector API — --add-modules=jdk.incubator.vector
                        → PanamaVectorizationProvider (SIMD via JIT)
  native              Google Highway via JNI — adds --enable-native-access,
                        -Djvector.experimental.enable_native_vectorization=true
                        (4.0.0-rc.9 / 4.0.1) and
                        -Djvector.enable_native_vectorization=true (≥4.0.2)
                        → NativeVectorizationProvider

Options:
  -h, --help          Show this help message and exit.

Environment variables:
  BACKENDS            Space-separated list of backends to run.
                      Default: "panama native"
                      Example: BACKENDS="panama" ./run_benchmarks.sh

  JMH_OPTS            Extra JMH CLI options appended to every run.
                      Example: JMH_OPTS="-wi 5 -i 10" ./run_benchmarks.sh

Output:
  results/<version>/<backend>/jmh-result.json   machine-readable
  results/<version>/<backend>/jmh-result.txt    human-readable

Examples:
  ./run_benchmarks.sh                        # all versions × all backends
  ./run_benchmarks.sh 4.0.2                 # single version, all backends
  ./run_benchmarks.sh 4.0.1 4.0.2           # two versions, all backends
  BACKENDS="panama" ./run_benchmarks.sh     # panama only, all versions
  JMH_OPTS="-wi 5 -i 10" ./run_benchmarks.sh 4.0.2
HELP
}

for arg in "$@"; do
    case "${arg}" in
        -h|--help) usage; exit 0 ;;
    esac
done

set -euo pipefail

# ── Versions ──────────────────────────────────────────────────────────────────
VERSIONS=("4.0.0-rc.9" "4.0.1" "4.0.2")
if [[ $# -gt 0 ]]; then
    VERSIONS=("$@")
fi

# ── Backend definitions ────────────────────────────────────────────────────────
# Parallel arrays: name → JVM args for that backend.
BACKEND_NAMES=("panama" "native")

declare -A BACKEND_JVM=(
    [panama]="--add-modules=jdk.incubator.vector -Djvector.vectorization_provider=panama"
    # Pass both property names: 4.0.0-rc.9 and 4.0.1 use the experimental name;
    # 4.0.2 uses the stable name (but also checks the experimental one as a fallback).
    [native]="--add-modules=jdk.incubator.vector --enable-native-access=ALL-UNNAMED -Djvector.experimental.enable_native_vectorization=true -Djvector.enable_native_vectorization=true"
)

# Allow caller to override the list of backends to run
if [[ -n "${BACKENDS:-}" ]]; then
    read -r -a BACKEND_NAMES <<< "${BACKENDS}"
fi

JMH_OPTS="${JMH_OPTS:-}"
RESULTS_DIR="results"

# ── Main loop ─────────────────────────────────────────────────────────────────
for VERSION in "${VERSIONS[@]}"; do
    echo ""
    echo "========================================================"
    echo "  jvector version: ${VERSION}"
    echo "========================================================"

    echo "[build] mvn package -Djvector.version=${VERSION} ..."
    mvn -q package -DskipTests -Djvector.version="${VERSION}"
    echo "[build] target/benchmarks.jar ready"

    for BACKEND in "${BACKEND_NAMES[@]}"; do
        echo ""
        echo "  ── backend: ${BACKEND} ──────────────────────────────"

        OUT_DIR="${RESULTS_DIR}/${VERSION}/${BACKEND}"
        mkdir -p "${OUT_DIR}"

        JVM_ARGS="${BACKEND_JVM[${BACKEND}]:-}"

        # Forward each flag individually into JMH's forked benchmark JVM via
        # -jvmArgsPrepend (one -jvmArgsPrepend per token, as JMH requires).
        JMH_JVM_PREPEND=""
        if [[ -n "${JVM_ARGS}" ]]; then
            for flag in ${JVM_ARGS}; do
                JMH_JVM_PREPEND="${JMH_JVM_PREPEND} -jvmArgsPrepend ${flag}"
            done
        fi

        # shellcheck disable=SC2086
        java \
            ${JVM_ARGS} \
            -jar target/benchmarks.jar \
            -p backend="${BACKEND}" \
            -foe true \
            -rf json -rff "${OUT_DIR}/jmh-result.json" \
            ${JMH_JVM_PREPEND} \
            ${JMH_OPTS} \
            2>&1 | tee "${OUT_DIR}/jmh-result.txt"

        echo "  Results → ${OUT_DIR}/"
    done
done

echo ""
echo "All done. Results tree:"
find "${RESULTS_DIR}" -name "jmh-result.txt" | sort | sed 's/^/  /'
