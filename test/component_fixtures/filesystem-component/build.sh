#!/bin/bash
set -e

echo "Building filesystem-component with native wasm32-wasip2 target..."

# Add wasm32-wasip2 target if not already added
rustup target add wasm32-wasip2 2>/dev/null || true

# Build with native target
cargo build --profile wasi-release --target wasm32-wasip2 --lib

# Create component with reactor adapter (for libraries)
wasm-tools component new \
    target/wasm32-wasip2/wasi-release/filesystem_component.wasm \
    --adapt wasi_snapshot_preview1=../wasi_snapshot_preview1.reactor.wasm \
    -o target/wasm32-wasip2/wasi-release/filesystem_component_final.wasm

# Validate the component
wasm-tools validate target/wasm32-wasip2/wasi-release/filesystem_component_final.wasm

echo "Successfully built filesystem-component!"