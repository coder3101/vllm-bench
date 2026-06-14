#!/usr/bin/env bash
# Install vllm-bench — build from source and install to ~/.local/bin.
#
# Usage:
#   ./install.sh              # build release, install to ~/.local/bin
#   ./install.sh --to ~/bin   # custom install directory

set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"

while [ $# -gt 0 ]; do
    case "$1" in
        --to)   INSTALL_DIR="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: install.sh [--to DIR]"
            echo "  --to DIR   Install directory (default: ~/.local/bin)"
            exit 0 ;;
        *)  echo "Unknown option: $1"; exit 1 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "Building vllm-bench (release)..."
cargo build --release --manifest-path "${ROOT}/Cargo.toml"

mkdir -p "$INSTALL_DIR"
cp "${ROOT}/target/release/vllm-bench" "${INSTALL_DIR}/vllm-bench"
chmod +x "${INSTALL_DIR}/vllm-bench"

echo "Installed vllm-bench to ${INSTALL_DIR}/vllm-bench"

# Check if install dir is in PATH
case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) ;;
    *)
        echo ""
        echo "NOTE: ${INSTALL_DIR} is not in your PATH. Add it with:"
        echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
        ;;
esac
