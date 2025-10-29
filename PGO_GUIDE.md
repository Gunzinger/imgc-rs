# Profile-Guided Optimization (PGO) Guide for imgc-rs

This guide explains how to build imgc-rs with Profile-Guided Optimization (PGO) to achieve maximum performance, especially for AVIF encoding workloads.

## What is PGO?

Profile-Guided Optimization is a compiler optimization technique that uses runtime profiling data to make better optimization decisions. It can provide significant performance improvements, especially for:

- CPU-intensive operations like AVIF encoding
- Hot code paths that are frequently executed
- Branch prediction and function inlining decisions

## Prerequisites

1. **Rust toolchain** with LLVM support
2. **LLVM tools** for profile data processing:
   ```bash
   rustup component add llvm-tools-preview
   ```

## Quick Start

### Windows (PowerShell)
```powershell
.\build-pgo.ps1
```

### Linux/macOS (Bash)
```bash
./build-pgo.sh
```

## Detailed Usage

### Basic PGO Build
```bash
# Windows
.\build-pgo.ps1

# Linux/macOS
./build-pgo.sh
```

### Custom Workload Directory
```bash
# Windows
.\build-pgo.ps1 -WorkloadDir "path/to/your/images"

# Linux/macOS
./build-pgo.sh --workload-dir "path/to/your/images"
```

### Clean Build
```bash
# Windows
.\build-pgo.ps1 -Clean

# Linux/macOS
./build-pgo.sh --clean
```

## How PGO Works

The PGO build process consists of three stages:

### Stage 1: Instrumented Build
- Builds the application with profiling instrumentation
- The binary collects runtime data about which code paths are executed

### Stage 2: Profile Collection
- Runs the instrumented binary with a representative workload
- For imgc-rs, this involves converting various image formats to AVIF
- The workload uses your `examples` directory by default

### Stage 3: Optimized Build
- Uses the collected profile data to build an optimized binary
- The compiler makes better decisions about:
  - Function inlining
  - Branch prediction
  - Code layout
  - Loop optimizations

## Manual PGO Build

If you prefer to run the PGO build manually:

```bash
# Stage 1: Build instrumented binary
export RUSTFLAGS="-C profile-generate=pgo-data"
cargo build --profile pgo --release

# Stage 2: Run workload (adjust paths as needed)
./target/release/imgc --input "examples/**/*.{jpg,jpeg,png}" --output temp-output --format avif --quality 90

# Stage 3: Merge profile data
llvm-profdata merge -o pgo-data/merged.profdata pgo-data/*.profraw

# Stage 4: Build optimized binary
export RUSTFLAGS="-C profile-use=pgo-data/merged.profdata"
cargo build --profile pgo --release
```

## Performance Expectations

PGO typically provides:

- **5-15% performance improvement** for general workloads
- **10-25% improvement** for CPU-intensive operations like AVIF encoding
- **Better cache utilization** due to improved code layout
- **More accurate branch prediction** reducing pipeline stalls

## Troubleshooting

### Common Issues

1. **llvm-profdata not found**
   ```bash
   rustup component add llvm-tools-preview
   ```

2. **No profile data generated**
   - Ensure the workload runs successfully
   - Check that input images exist in the workload directory
   - Verify the instrumented binary was built correctly

3. **Build failures**
   - Clean previous builds: `cargo clean`
   - Remove PGO data: `rm -rf pgo-data` (Linux/macOS) or `Remove-Item -Recurse pgo-data` (Windows)

### Profile Data Quality

For best results:
- Use a representative workload that matches your production usage
- Include various image formats and sizes
- Run the workload for sufficient time to collect meaningful data
- Use the same quality settings and parameters as your production workload

## Advanced Configuration

### Custom PGO Profile

You can modify the PGO profile in `Cargo.toml`:

```toml
[profile.pgo]
inherits = "release"
opt-level = 3
lto = "fat"  # Use fat LTO for better optimization
codegen-units = 1
```

### Environment Variables

- `RUSTFLAGS`: Override Rust compiler flags
- `CARGO_PROFILE_PGO_OPT_LEVEL`: Set optimization level for PGO profile
- `CARGO_PROFILE_PGO_LTO`: Set LTO mode for PGO profile

## Integration with CI/CD

For automated builds, you can integrate PGO:

```yaml
# Example GitHub Actions workflow
- name: Build with PGO
  run: |
    rustup component add llvm-tools-preview
    ./build-pgo.sh --workload-dir "test-images"
```

## Best Practices

1. **Use representative workloads** that match your production usage patterns
2. **Regular PGO rebuilds** when code changes significantly
3. **Profile data validation** to ensure quality data collection
4. **Performance benchmarking** to measure actual improvements
5. **Version control** for profile data in some cases (though usually not necessary)

## Monitoring Performance

After building with PGO, benchmark your application:

```bash
# Example benchmark
time ./target/release/imgc --input "large-dataset/**/*.jpg" --output output --format avif --quality 90
```

Compare the results with your non-PGO builds to measure the improvement.
