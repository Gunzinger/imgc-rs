# PGO Build Script for imgc-rs
# This script builds the application with Profile-Guided Optimization (PGO)
# for maximum performance, especially for AVIF encoding workloads.

param(
    [string]$ProfileDataDir = "pgo-data",
    [string]$WorkloadDir = "examples",
    [switch]$Clean = $false,
    [switch]$Help = $false
)

if ($Help) {
    Write-Host "PGO Build Script for imgc-rs"
    Write-Host ""
    Write-Host "Usage: .\build-pgo.ps1 [options]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -ProfileDataDir <dir>  Directory to store PGO profile data (default: pgo-data)"
    Write-Host "  -WorkloadDir <dir>     Directory containing test images for profiling (default: examples)"
    Write-Host "  -Clean                 Clean previous PGO data before building"
    Write-Host "  -Help                  Show this help message"
    Write-Host ""
    Write-Host "This script performs a 3-stage PGO build:"
    Write-Host "1. Build instrumented binary"
    Write-Host "2. Run workload to generate profile data"
    Write-Host "3. Build optimized binary using profile data"
    exit 0
}

# Check if Rust is installed
if (!(Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Error "Cargo not found. Please install Rust toolchain first."
    exit 1
}

# Check if llvm-profdata is available (required for PGO)
if (!(Get-Command llvm-profdata -ErrorAction SilentlyContinue)) {
    Write-Host "llvm-profdata not found. Attempting to install llvm-tools-preview..." -ForegroundColor Yellow
    rustup component add llvm-tools-preview
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to install llvm-tools-preview. Please install it manually with: rustup component add llvm-tools-preview"
        exit 1
    }
    Write-Host "llvm-tools-preview installed successfully!" -ForegroundColor Green
}

# Verify Rust version supports PGO (Rust 1.70+)
Write-Host "Checking Rust version for PGO support..." -ForegroundColor Cyan
$rustVersion = (rustc --version).Split(" ")[1]
$majorVersion = [int]($rustVersion.Split(".")[0])
$minorVersion = [int]($rustVersion.Split(".")[1])

if ($majorVersion -lt 1 -or ($majorVersion -eq 1 -and $minorVersion -lt 70)) {
    Write-Warning "Rust version $rustVersion may not fully support PGO. Consider upgrading to Rust 1.70 or later."
}

Write-Host "Starting PGO build process for imgc-rs..." -ForegroundColor Green

# Clean previous PGO data if requested
if ($Clean -and (Test-Path $ProfileDataDir)) {
    Write-Host "Cleaning previous PGO data..." -ForegroundColor Yellow
    Remove-Item -Recurse -Force $ProfileDataDir
}

# Create profile data directory
if (!(Test-Path $ProfileDataDir)) {
    New-Item -ItemType Directory -Path $ProfileDataDir | Out-Null
}

# Stage 1: Build instrumented binary
Write-Host "Stage 1: Building instrumented binary..." -ForegroundColor Cyan
Write-Host "Note: If you see 'profiler_builtins' error, your Rust toolchain may not support PGO." -ForegroundColor Yellow
Write-Host "Try: rustup update stable && rustup component add llvm-tools-preview" -ForegroundColor Yellow

# Use absolute path for profile data directory to avoid path issues
$ProfileDataDirAbs = (Resolve-Path -Path $ProfileDataDir -ErrorAction SilentlyContinue).Path
if (-not $ProfileDataDirAbs) {
    $ProfileDataDirAbs = (Join-Path (Get-Location).Path $ProfileDataDir)
}

$env:RUSTFLAGS = "-C profile-generate=$ProfileDataDirAbs"
Write-Host "RUSTFLAGS: $env:RUSTFLAGS" -ForegroundColor Gray
cargo build --profile pgo

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to build instrumented binary"
    exit 1
}

# Stage 2: Run workload to generate profile data
Write-Host "Stage 2: Running workload to generate profile data..." -ForegroundColor Cyan
Write-Host "Using workload directory: $WorkloadDir"

# Find the built binary
$binaryPath = "target\release\imgc.exe"
if (!(Test-Path $binaryPath)) {
    Write-Error "Built binary not found at $binaryPath"
    exit 1
}

# Create a temporary output directory for the workload
$tempOutputDir = "pgo-temp-output"
if (Test-Path $tempOutputDir) {
    Remove-Item -Recurse -Force $tempOutputDir
}
New-Item -ItemType Directory -Path $tempOutputDir | Out-Null

try {
    # Run the workload - convert images to AVIF (your main bottleneck)
    Write-Host "Running AVIF conversion workload..."
    & $binaryPath --input "$WorkloadDir\**\*.{jpg,jpeg,png}" --output $tempOutputDir --format avif --quality 90 --speed 3
    
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Workload completed with warnings/errors, but continuing with PGO..."
    }
    
    Write-Host "Profile data generation completed." -ForegroundColor Green
} finally {
    # Clean up temporary output
    if (Test-Path $tempOutputDir) {
        Remove-Item -Recurse -Force $tempOutputDir
    }
}

# Stage 3: Build optimized binary using profile data
Write-Host "Stage 3: Building optimized binary using profile data..." -ForegroundColor Cyan

# Merge profile data
$profrawFiles = Get-ChildItem -Path $ProfileDataDir -Filter "*.profraw" -Recurse
if ($profrawFiles.Count -eq 0) {
    Write-Error "No profile data found. Make sure the workload ran successfully."
    exit 1
}

Write-Host "Found $($profrawFiles.Count) profile data files"
llvm-profdata merge -o "$ProfileDataDir\merged.profdata" $profrawFiles.FullName

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to merge profile data"
    exit 1
}

# Build final optimized binary
$env:RUSTFLAGS = "-C profile-use=$ProfileDataDir\merged.profdata"
cargo build --profile pgo --release

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to build optimized binary"
    exit 1
}

# Clean up environment
Remove-Item Env:RUSTFLAGS

Write-Host "PGO build completed successfully!" -ForegroundColor Green
Write-Host "Optimized binary available at: $binaryPath"
Write-Host ""
Write-Host "Performance improvements should be most noticeable for:"
Write-Host "- AVIF encoding operations"
Write-Host "- Batch processing of large image sets"
Write-Host "- CPU-intensive image conversion tasks"
