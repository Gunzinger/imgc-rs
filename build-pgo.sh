#!/bin/bash

# PGO Build Script for imgc-rs
# This script builds the application with Profile-Guided Optimization (PGO)
# for maximum performance, especially for AVIF encoding workloads.

set -e

PROFILE_DATA_DIR="pgo-data"
WORKLOAD_DIR="examples"
CLEAN=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --profile-data-dir)
            PROFILE_DATA_DIR="$2"
            shift 2
            ;;
        --workload-dir)
            WORKLOAD_DIR="$2"
            shift 2
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --help)
            echo "PGO Build Script for imgc-rs"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --profile-data-dir <dir>  Directory to store PGO profile data (default: pgo-data)"
            echo "  --workload-dir <dir>      Directory containing test images for profiling (default: examples)"
            echo "  --clean                   Clean previous PGO data before building"
            echo "  --help                    Show this help message"
            echo ""
            echo "This script performs a 3-stage PGO build:"
            echo "1. Build instrumented binary"
            echo "2. Run workload to generate profile data"
            echo "3. Build optimized binary using profile data"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check if Rust is installed
if ! command -v cargo &> /dev/null; then
    echo "Error: Cargo not found. Please install Rust toolchain first."
    exit 1
fi

# Check if llvm-profdata is available (required for PGO)
if ! command -v llvm-profdata &> /dev/null; then
    echo "Error: llvm-profdata not found. Please install LLVM tools or use 'rustup component add llvm-tools-preview'"
    exit 1
fi

echo "Starting PGO build process for imgc-rs..."

# Clean previous PGO data if requested
if [ "$CLEAN" = true ] && [ -d "$PROFILE_DATA_DIR" ]; then
    echo "Cleaning previous PGO data..."
    rm -rf "$PROFILE_DATA_DIR"
fi

# Create profile data directory
mkdir -p "$PROFILE_DATA_DIR"

# Stage 1: Build instrumented binary
echo "Stage 1: Building instrumented binary..."
export RUSTFLAGS="-C profile-generate=$PROFILE_DATA_DIR"
cargo build --profile pgo

if [ $? -ne 0 ]; then
    echo "Error: Failed to build instrumented binary"
    exit 1
fi

# Stage 2: Run workload to generate profile data
echo "Stage 2: Running workload to generate profile data..."
echo "Using workload directory: $WORKLOAD_DIR"

# Find the built binary
BINARY_PATH="target/release/imgc"
if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: Built binary not found at $BINARY_PATH"
    exit 1
fi

# Create a temporary output directory for the workload
TEMP_OUTPUT_DIR="pgo-temp-output"
if [ -d "$TEMP_OUTPUT_DIR" ]; then
    rm -rf "$TEMP_OUTPUT_DIR"
fi
mkdir -p "$TEMP_OUTPUT_DIR"

# Run the workload - convert images to AVIF (your main bottleneck)
echo "Running AVIF conversion workload..."
"$BINARY_PATH" --input "$WORKLOAD_DIR/**/*.{jpg,jpeg,png}" --output "$TEMP_OUTPUT_DIR" --format avif --quality 90 --speed 3 || true

echo "Profile data generation completed."

# Clean up temporary output
rm -rf "$TEMP_OUTPUT_DIR"

# Stage 3: Build optimized binary using profile data
echo "Stage 3: Building optimized binary using profile data..."

# Merge profile data
PROFRAW_FILES=$(find "$PROFILE_DATA_DIR" -name "*.profraw" -type f)
if [ -z "$PROFRAW_FILES" ]; then
    echo "Error: No profile data found. Make sure the workload ran successfully."
    exit 1
fi

PROFRAW_COUNT=$(echo "$PROFRAW_FILES" | wc -l)
echo "Found $PROFRAW_COUNT profile data files"

llvm-profdata merge -o "$PROFILE_DATA_DIR/merged.profdata" $PROFRAW_FILES

if [ $? -ne 0 ]; then
    echo "Error: Failed to merge profile data"
    exit 1
fi

# Build final optimized binary
export RUSTFLAGS="-C profile-use=$PROFILE_DATA_DIR/merged.profdata"
cargo build --profile pgo --release

if [ $? -ne 0 ]; then
    echo "Error: Failed to build optimized binary"
    exit 1
fi

# Clean up environment
unset RUSTFLAGS

echo "PGO build completed successfully!"
echo "Optimized binary available at: $BINARY_PATH"
echo ""
echo "Performance improvements should be most noticeable for:"
echo "- AVIF encoding operations"
echo "- Batch processing of large image sets"
echo "- CPU-intensive image conversion tasks"
