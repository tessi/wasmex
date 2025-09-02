#!/bin/bash
set -e

echo "Building WASI test component..."

# Build with native wasm32-wasip2 target
cargo build --target wasm32-wasip2 --release

# Check if the wasm file is already a component
if wasm-tools validate target/wasm32-wasip2/release/wasi_test_component.wasm --features component-model 2>/dev/null; then
    echo "Module is already a component, copying to final location"
    cp target/wasm32-wasip2/release/wasi_test_component.wasm target/wasm32-wasip2/release/wasi_test_component_final.wasm
else
    echo "Creating component with WASI adapter..."
    # Create component with reactor adapter (for library)
    wasm-tools component new \
        target/wasm32-wasip2/release/wasi_test_component.wasm \
        --adapt wasi_snapshot_preview1=../wasi_snapshot_preview1.reactor.wasm \
        -o target/wasm32-wasip2/release/wasi_test_component_final.wasm
fi

# Validate the component
wasm-tools validate target/wasm32-wasip2/release/wasi_test_component_final.wasm --features component-model

echo "Component built successfully at target/wasm32-wasip2/release/wasi_test_component_final.wasm"