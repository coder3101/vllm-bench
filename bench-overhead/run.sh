#!/bin/bash
# End-to-end benchmark: compare Rust vllm-bench vs Python (vllm bench serve)
# overhead against a deterministic mock LLM server.
#
# Usage: ./run.sh [--quick]
#   --quick: run only concurrency levels 1,10,100 with fewer requests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${SCRIPT_DIR}/results"
MOCK_SERVER="${SCRIPT_DIR}/mock-server/target/release/mock-llm-server"
VLLM_BENCH="${WORKSPACE}/target/release/vllm-bench"

# Ground truth timing
TOKEN_INTERVAL_MS=10
FIRST_TOKEN_DELAY_MS=50
OUTPUT_LEN=100
PROMPT_LEN=32
PORT=8089
BASE_URL="http://127.0.0.1:${PORT}"

# Concurrency levels and request counts
if [[ "${1:-}" == "--quick" ]]; then
    CONCURRENCIES=(1 10 100)
    REQUEST_COUNTS=(10 20 200)
    echo "=== QUICK MODE ==="
else
    CONCURRENCIES=(1 10 100 500 1000)
    REQUEST_COUNTS=(50 100 200 500 1000)
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

echo "=== Building mock server ==="
if ! (cd "${SCRIPT_DIR}/mock-server" && cargo build --release 2>&1); then
    echo "ERROR: Mock server build failed."
    exit 1
fi

if [[ ! -f "$VLLM_BENCH" ]]; then
    echo "=== Building vllm-bench ==="
    if ! (cd "$WORKSPACE" && cargo build --release 2>&1); then
        echo "ERROR: vllm-bench build failed."
        exit 1
    fi
fi

echo "=== Build complete ==="

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

start_server() {
    "$MOCK_SERVER" \
        --port "$PORT" \
        --token-interval-ms "$TOKEN_INTERVAL_MS" \
        --first-token-delay-ms "$FIRST_TOKEN_DELAY_MS" \
        --num-tokens "$OUTPUT_LEN" &
    SERVER_PID=$!
    for _ in $(seq 1 30); do
        if curl -s "${BASE_URL}/v1/models" > /dev/null 2>&1; then
            echo "  Mock server ready (PID=$SERVER_PID)"
            return 0
        fi
        sleep 0.2
    done
    echo "ERROR: Mock server failed to start"
    exit 1
}

stop_server() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
        unset SERVER_PID
    fi
    # Extra safety
    local pids
    pids=$(lsof -t -i ":${PORT}" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        kill $pids 2>/dev/null || true
        sleep 0.3
    fi
}

# ---------------------------------------------------------------------------
# Run benchmarks
# ---------------------------------------------------------------------------

mkdir -p "$RESULTS_DIR"

echo ""
echo "=== Overhead Comparison Benchmark ==="
echo "  Token interval: ${TOKEN_INTERVAL_MS}ms (${OUTPUT_LEN} tokens/request)"
echo "  First token delay: ${FIRST_TOKEN_DELAY_MS}ms"
echo "  Concurrency levels: ${CONCURRENCIES[*]}"
echo "  Python client: vllm bench serve (the real CLI)"
echo ""

for idx in "${!CONCURRENCIES[@]}"; do
    CONC="${CONCURRENCIES[$idx]}"
    NUM_REQ="${REQUEST_COUNTS[$idx]}"

    echo "--- Concurrency: $CONC ($NUM_REQ requests) ---"
    stop_server
    start_server

    # ---- Python client (vllm bench serve) ----
    echo "  Running Python client (vllm bench serve)..."
    PYTHON_RESULT_DIR="${RESULTS_DIR}/python-raw"
    mkdir -p "$PYTHON_RESULT_DIR"

    python3 -c "
import sys
sys.argv = [
    'vllm', 'bench', 'serve',
    '--backend', 'openai',
    '--base-url', '${BASE_URL}',
    '--model', 'mock-model',
    '--tokenizer', 'gpt2',
    '--dataset-name', 'random',
    '--random-input-len', '${PROMPT_LEN}',
    '--random-output-len', '${OUTPUT_LEN}',
    '--num-prompts', '${NUM_REQ}',
    '--max-concurrency', '${CONC}',
    '--disable-tqdm',
    '--save-result',
    '--save-detailed',
    '--result-dir', '${PYTHON_RESULT_DIR}',
    '--num-warmups', '0',
    '--percentile-metrics', 'ttft,tpot,itl,e2el',
    '--ready-check-timeout-sec', '10',
]
from vllm.entrypoints.cli.main import main
main()
" 2>&1 | sed 's/^/    /'

    # Rename latest result to standard format
    LATEST=$(ls -t "${PYTHON_RESULT_DIR}"/*.json 2>/dev/null | head -1)
    if [[ -n "$LATEST" ]]; then
        cp "$LATEST" "${RESULTS_DIR}/python-c${CONC}.json"
        echo "    Python results: python-c${CONC}.json"
    fi

    # ---- Rust client (vllm-bench) ----
    echo "  Running Rust client (vllm-bench)..."
    RUST_RESULT_DIR="${RESULTS_DIR}/rust-raw"
    mkdir -p "$RUST_RESULT_DIR"

    "$VLLM_BENCH" \
        --backend openai \
        --base-url "${BASE_URL}" \
        --model mock-model \
        --tokenizer gpt2 \
        --dataset-name random \
        --random-input-len "$PROMPT_LEN" \
        --random-output-len "$OUTPUT_LEN" \
        --num-prompts "$NUM_REQ" \
        --max-concurrency "$CONC" \
        --disable-tqdm \
        --save-result --save-detailed \
        --result-dir "$RUST_RESULT_DIR" \
        --ready-check-timeout-sec 10 \
        --num-warmups 0 \
        --percentile-metrics "ttft,tpot,itl,e2el" \
        2>&1 | sed 's/^/    /'

    LATEST=$(ls -t "${RUST_RESULT_DIR}"/*.json 2>/dev/null | head -1)
    if [[ -n "$LATEST" ]]; then
        cp "$LATEST" "${RESULTS_DIR}/rust-c${CONC}.json"
        echo "    Rust results: rust-c${CONC}.json"
    fi

    stop_server
    echo ""
done

# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

echo "=== Running comparison analysis ==="
python3 "${SCRIPT_DIR}/compare.py" \
    --results-dir "$RESULTS_DIR" \
    --token-interval-ms "$TOKEN_INTERVAL_MS" \
    --first-token-delay-ms "$FIRST_TOKEN_DELAY_MS"

echo ""
echo "=== Done ==="
echo "Results in: $RESULTS_DIR"
