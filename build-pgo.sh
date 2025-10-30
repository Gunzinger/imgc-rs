#!/bin/bash

# PGO Build Script for imgc-rs
# This script builds the application with Profile-Guided Optimization (PGO)
# for maximum performance, especially for AVIF encoding workloads.

set -e

PROFILE_DATA_DIR="pgo-data"
WORKLOAD_DIR="examples"
TARGET_CPU_ARG=""
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
        --target-cpu)
            TARGET_CPU_ARG="$2"
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
            echo "  --target-cpu <cpu>         Target CPU microarchitecture (e.g., x86-64-v3, x86-64-v4, znver3)"
            echo "                            Can also be set via TARGET_CPU environment variable"
            echo "                            Falls back to .cargo/config.toml if not specified"
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
    echo "llvm-profdata not found. Attempting to install llvm-tools-preview..."
    rustup component add llvm-tools-preview
    if [ $? -ne 0 ]; then
        echo "Error: Failed to install llvm-tools-preview. Please install it manually with: rustup component add llvm-tools-preview"
        exit 1
    fi
    echo "llvm-tools-preview installed successfully!"
fi

# Detect default host target
DEFAULT_TARGET=$(rustc -vV | grep "host:" | awk '{print $2}')
echo "Default Rust target: $DEFAULT_TARGET"

# Verify Rust version supports PGO (Rust 1.70+)
RUST_VERSION=$(rustc --version | awk '{print $2}')
MAJOR_VERSION=$(echo "$RUST_VERSION" | cut -d. -f1)
MINOR_VERSION=$(echo "$RUST_VERSION" | cut -d. -f2)

if [ "$MAJOR_VERSION" -lt 1 ] || ([ "$MAJOR_VERSION" -eq 1 ] && [ "$MINOR_VERSION" -lt 70 ]); then
    echo "Warning: Rust version $RUST_VERSION may not fully support PGO. Consider upgrading to Rust 1.70 or later."
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
echo "Note: If you see 'profiler_builtins' error, your Rust toolchain may not support PGO."
echo "Try: rustup update stable && rustup component add llvm-tools-preview"

# Use absolute path for profile data directory
PROFILE_DATA_DIR_ABS=$(cd "$PROFILE_DATA_DIR" && pwd)

# Determine target-cpu value
# Priority: 1) TARGET_CPU env var, 2) --target-cpu arg, 3) .cargo/config.toml, 4) existing RUSTFLAGS
TARGET_CPU_VALUE=""

if [ -n "$TARGET_CPU" ]; then
    TARGET_CPU_VALUE="$TARGET_CPU"
    echo "Using TARGET_CPU from environment: $TARGET_CPU_VALUE"
elif [ -n "$TARGET_CPU_ARG" ]; then
    TARGET_CPU_VALUE="$TARGET_CPU_ARG"
    echo "Using target-cpu from argument: $TARGET_CPU_VALUE"
else
    # Try to read from .cargo/config.toml
    if [ -f ".cargo/config.toml" ]; then
        # Extract target-cpu value - handles both formats:
        # "-C", "target-cpu=x86-64-v3" and target-cpu=x86-64-v3
        EXTRACTED=$(grep "target-cpu" .cargo/config.toml 2>/dev/null | \
            sed -n 's/.*target-cpu=\([^"\]\s,]*\).*/\1/p' | \
            tr -d '"' | head -1)
        if [ -n "$EXTRACTED" ]; then
            TARGET_CPU_VALUE="$EXTRACTED"
            echo "Using target-cpu from .cargo/config.toml: $TARGET_CPU_VALUE"
        fi
    fi
    
    # If still not found, check existing RUSTFLAGS
    if [ -z "$TARGET_CPU_VALUE" ] && [ -n "$RUSTFLAGS" ]; then
        EXTRACTED=$(echo "$RUSTFLAGS" | sed -n 's/.*target-cpu=\([^\s]*\).*/\1/p' | head -1)
        if [ -n "$EXTRACTED" ]; then
            TARGET_CPU_VALUE="$EXTRACTED"
            echo "Using target-cpu from existing RUSTFLAGS: $TARGET_CPU_VALUE"
        fi
    fi
fi

# Build RUSTFLAGS string
RUSTFLAGS_ARGS=""

# Add target-cpu if specified
if [ -n "$TARGET_CPU_VALUE" ]; then
    RUSTFLAGS_ARGS="-C target-cpu=$TARGET_CPU_VALUE"
fi

# Add PGO flags
RUSTFLAGS_ARGS="$RUSTFLAGS_ARGS -C profile-generate=$PROFILE_DATA_DIR_ABS"

# Preserve any existing RUSTFLAGS that aren't target-cpu or PGO-related
if [ -n "$RUSTFLAGS" ]; then
    # Split and filter existing flags
    OLD_IFS=$IFS
    IFS=' '
    for flag in $RUSTFLAGS; do
        if [[ ! "$flag" =~ target-cpu= ]] && \
           [[ ! "$flag" =~ profile-generate= ]] && \
           [[ ! "$flag" =~ profile-use= ]]; then
            RUSTFLAGS_ARGS="$RUSTFLAGS_ARGS $flag"
        fi
    done
    IFS=$OLD_IFS
    if [ "$RUSTFLAGS_ARGS" != "-C profile-generate=$PROFILE_DATA_DIR_ABS" ] && [ -z "$TARGET_CPU_VALUE" ]; then
        echo "Preserving existing RUSTFLAGS (excluding target-cpu and PGO flags)"
    fi
fi

export RUSTFLAGS="$RUSTFLAGS_ARGS"
echo "RUSTFLAGS: $RUSTFLAGS"
cargo build --profile pgo

if [ $? -ne 0 ]; then
    echo "Error: Failed to build instrumented binary"
    exit 1
fi

# Stage 2: Run workload to generate profile data
echo "Stage 2: Running workload to generate profile data..."
echo "Using workload directory: $WORKLOAD_DIR"

# Find the built binary (PGO profile builds to pgo profile directory)
BINARY_PATH="target/pgo/imgc"
if [ ! -f "$BINARY_PATH" ]; then
    BINARY_PATH="target/release/imgc"
    if [ ! -f "$BINARY_PATH" ]; then
        echo "Error: Built binary not found. Expected at target/pgo/imgc or target/release/imgc"
        exit 1
    fi
fi

# Create a temporary output directory for the workload
TEMP_OUTPUT_DIR="pgo-temp-output"
if [ -d "$TEMP_OUTPUT_DIR" ]; then
    rm -rf "$TEMP_OUTPUT_DIR"
fi
mkdir -p "$TEMP_OUTPUT_DIR"

# Run the workload - convert images to AVIF (your main bottleneck)
echo "Running AVIF conversion workload..."
"$BINARY_PATH" "$WORKLOAD_DIR/**/*" --output "$TEMP_OUTPUT_DIR" avif --quality 90 --speed 5 --overwrite-existing || true
"$BINARY_PATH" "$WORKLOAD_DIR/**/*" --output "$TEMP_OUTPUT_DIR" avif --quality 90 --speed 3 --overwrite-existing || true

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
MERGED_PROFDATA="$PROFILE_DATA_DIR_ABS/merged.profdata"
if [ ! -f "$MERGED_PROFDATA" ]; then
    echo "Error: Merged profile data not found at $MERGED_PROFDATA"
    exit 1
fi

# Rebuild RUSTFLAGS for optimization stage (replace profile-generate with profile-use)
RUSTFLAGS_ARGS=""

# Add target-cpu if we had it before
if [ -n "$TARGET_CPU_VALUE" ]; then
    RUSTFLAGS_ARGS="-C target-cpu=$TARGET_CPU_VALUE"
fi

# Add PGO optimization flags
RUSTFLAGS_ARGS="$RUSTFLAGS_ARGS -C profile-use=$MERGED_PROFDATA"

# Preserve any existing RUSTFLAGS that aren't target-cpu or PGO-related
if [ -n "$RUSTFLAGS" ]; then
    # Split and filter existing flags
    OLD_IFS=$IFS
    IFS=' '
    for flag in $RUSTFLAGS; do
        if [[ ! "$flag" =~ target-cpu= ]] && \
           [[ ! "$flag" =~ profile-generate= ]] && \
           [[ ! "$flag" =~ profile-use= ]]; then
            RUSTFLAGS_ARGS="$RUSTFLAGS_ARGS $flag"
        fi
    done
    IFS=$OLD_IFS
fi

export RUSTFLAGS="$RUSTFLAGS_ARGS"
echo "RUSTFLAGS: $RUSTFLAGS"
cargo build --profile pgo

if [ $? -ne 0 ]; then
    echo "Error: Failed to build optimized binary"
    exit 1
fi

# Clean up environment
unset RUSTFLAGS

echo "PGO build completed successfully!"

# Find the final binary location
FINAL_BINARY="target/pgo/imgc"
if [ ! -f "$FINAL_BINARY" ]; then
    FINAL_BINARY="target/release/imgc"
fi
echo "Optimized binary available at: $FINAL_BINARY"
echo ""
echo "Performance improvements should be most noticeable for:"
echo "- AVIF encoding operations"
echo "- Batch processing of large image sets"
echo "- CPU-intensive image conversion tasks"
