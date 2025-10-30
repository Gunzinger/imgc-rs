# PGO Build Script for imgc-rs
# This script builds the application with Profile-Guided Optimization (PGO)
# for maximum performance, especially for AVIF encoding workloads.

param(
    [string]$ProfileDataDir = "pgo-data",
    [string]$WorkloadDir = "examples",
    [string]$TargetCpu = "",
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
    Write-Host "  -TargetCpu <cpu>       Target CPU microarchitecture (e.g., x86-64-v3, x86-64-v4, znver3)"
    Write-Host "                         Can also be set via TARGET_CPU environment variable"
    Write-Host "                         Falls back to .cargo/config.toml if not specified"
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

# Detect default host target
$defaultTarget = (rustc -vV | Select-String "host:").ToString().Split(":")[1].Trim()
Write-Host "Default Rust target: $defaultTarget" -ForegroundColor Cyan

# Check if llvm-profdata is available (required for PGO)
$llvmToolsInstalled = $false
if (Get-Command llvm-profdata -ErrorAction SilentlyContinue) {
    $llvmToolsInstalled = $true
    Write-Host "llvm-profdata found" -ForegroundColor Green
} else {
    Write-Host "llvm-profdata not found. Attempting to install llvm-tools-preview..." -ForegroundColor Yellow
    
    # Try to install for current default toolchain first
    rustup component add llvm-tools-preview
    if ($LASTEXITCODE -eq 0) {
        $llvmToolsInstalled = $true
        Write-Host "llvm-tools-preview installed successfully!" -ForegroundColor Green
    } else {
        Write-Warning "Failed to install llvm-tools-preview automatically."
        Write-Host "Please install manually:" -ForegroundColor Yellow
        Write-Host "  rustup component add llvm-tools-preview" -ForegroundColor White
        
        # Check what llvm-tools are available
        $availableTools = rustup component list | Select-String "llvm-tools"
        if ($availableTools) {
            Write-Host "Available llvm-tools components:" -ForegroundColor Yellow
            $availableTools | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        }
    }
}

# Verify Rust version supports PGO (Rust 1.70+)
Write-Host "Checking Rust version for PGO support..." -ForegroundColor Cyan
$rustVersion = (rustc --version).Split(" ")[1]
$majorVersion = [int]($rustVersion.Split(".")[0])
$minorVersion = [int]($rustVersion.Split(".")[1])

if ($majorVersion -lt 1 -or ($majorVersion -eq 1 -and $minorVersion -lt 70)) {
    Write-Warning "Rust version $rustVersion may not fully support PGO. Consider upgrading to Rust 1.70 or later."
}

# Determine which toolchain and target to use for PGO
# Use MSVC target on Windows (GNU doesn't have profiler runtime enabled)
$pgoToolchain = $null
$pgoTarget = $null

# Prefer MSVC target for Windows PGO (profiler is disabled for windows-gnu)
if ($defaultTarget -match "windows") {
    $msvcTarget = "x86_64-pc-windows-msvc"
    
    Write-Host "Using MSVC target ($msvcTarget) for PGO builds." -ForegroundColor Cyan
    Write-Host "Note: Profiler runtime is disabled for windows-gnu, using MSVC instead." -ForegroundColor Yellow
    
    # Check if MSVC target is installed
    $msvcInstalled = rustup target list --installed | Select-String $msvcTarget
    
    if (-not $msvcInstalled) {
        Write-Host "Installing MSVC target ($msvcTarget) for PGO..." -ForegroundColor Yellow
        rustup target add $msvcTarget
        if ($LASTEXITCODE -eq 0) {
            Write-Host "MSVC target installed successfully!" -ForegroundColor Green
        } else {
            Write-Warning "Failed to install MSVC target. PGO may fail."
        }
    }
    
    $pgoTarget = $msvcTarget
    
    # Check if we should try stable toolchain (MSVC on stable often has better profiler support)
    if ($rustVersion -match "nightly") {
        Write-Host "Nightly toolchain detected. Checking for stable MSVC toolchain..." -ForegroundColor Cyan
        
        $allToolchains = rustup toolchain list
        $stableMsvc = $allToolchains | Select-String "stable.*msvc"
        
        if ($stableMsvc) {
            Write-Host "Found stable MSVC toolchain: $($stableMsvc.Line.Trim())" -ForegroundColor Green
            $pgoToolchain = ($stableMsvc.Line -split '\s')[0]
            Write-Host "Will use $pgoToolchain for PGO builds." -ForegroundColor Green
            
            # Ensure llvm-tools is installed for this toolchain
            $toolsForToolchain = rustup component list --toolchain $pgoToolchain | Select-String "llvm-tools"
            if (-not $toolsForToolchain) {
                Write-Host "Installing llvm-tools-preview for $pgoToolchain..." -ForegroundColor Yellow
                rustup component add llvm-tools-preview --toolchain $pgoToolchain
            }
        } else {
            Write-Host "No stable MSVC toolchain found. Will use current toolchain." -ForegroundColor Yellow
        }
    }
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

# Build RUSTFLAGS with target-cpu and PGO support
# Priority: 1) TARGET_CPU env var, 2) -TargetCpu param, 3) .cargo/config.toml, 4) existing RUSTFLAGS
$targetCpuValue = $null

# Check environment variable first
if ($env:TARGET_CPU) {
    $targetCpuValue = $env:TARGET_CPU
    Write-Host "Using TARGET_CPU from environment: $targetCpuValue" -ForegroundColor Cyan
} elseif ($TargetCpu) {
    $targetCpuValue = $TargetCpu
    Write-Host "Using TargetCpu from parameter: $targetCpuValue" -ForegroundColor Cyan
} else {
    # Try to read from .cargo/config.toml
    $cargoConfigPath = ".cargo\config.toml"
    if (Test-Path $cargoConfigPath) {
        $configContent = Get-Content $cargoConfigPath -Raw
        # Handle both formats: "-C", "target-cpu=x86-64-v3" and target-cpu=x86-64-v3
        if ($configContent -match 'target-cpu=([^\s"\]\],]+)') {
            $targetCpuValue = $matches[1].Trim('"')
            Write-Host "Using target-cpu from .cargo/config.toml: $targetCpuValue" -ForegroundColor Cyan
        }
    }
    
    # If still not found, check existing RUSTFLAGS
    if (-not $targetCpuValue -and $env:RUSTFLAGS -match 'target-cpu=([^\s]+)') {
        $targetCpuValue = $matches[1]
        Write-Host "Using target-cpu from existing RUSTFLAGS: $targetCpuValue" -ForegroundColor Cyan
    }
}

# Build RUSTFLAGS string
$rustFlagsList = @()

# Add target-cpu if specified
if ($targetCpuValue) {
    $rustFlagsList += "-C target-cpu=$targetCpuValue"
}

# Add PGO flags
$rustFlagsList += "-C profile-generate=$ProfileDataDirAbs"

# Preserve any existing RUSTFLAGS that aren't target-cpu or PGO-related
if ($env:RUSTFLAGS) {
    $existingFlags = $env:RUSTFLAGS -split '\s+(?=-C)' | Where-Object {
        $_ -notmatch 'target-cpu=' -and 
        $_ -notmatch 'profile-generate=' -and 
        $_ -notmatch 'profile-use='
    }
    if ($existingFlags) {
        $rustFlagsList += $existingFlags
        Write-Host "Preserving existing RUSTFLAGS (excluding target-cpu and PGO flags)" -ForegroundColor Gray
    }
}

# Set the combined RUSTFLAGS
$env:RUSTFLAGS = $rustFlagsList -join ' '
Write-Host "RUSTFLAGS: $env:RUSTFLAGS" -ForegroundColor Gray

if ($pgoToolchain) {
    Write-Host "Using toolchain: $pgoToolchain" -ForegroundColor Cyan
}

if ($pgoTarget) {
    Write-Host "Building for target: $pgoTarget" -ForegroundColor Cyan
    
    if ($pgoToolchain) {
        cargo +$pgoToolchain build --profile pgo --target $pgoTarget
    } else {
        cargo build --profile pgo --target $pgoTarget
    }
} else {
    if ($pgoToolchain) {
        cargo +$pgoToolchain build --profile pgo
    } else {
        cargo build --profile pgo
    }
}

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to build instrumented binary"
    Write-Host ""
    $errorOutput = cargo build --profile pgo 2>&1 | Out-String
    if ($errorOutput -match "profiler_builtins") {
        Write-Host "ERROR: Profiler runtime not available in your Rust toolchain." -ForegroundColor Red
        Write-Host ""
        Write-Host "The 'profiler_builtins' error means your Rust installation doesn't have" -ForegroundColor Yellow
        Write-Host "the profiler runtime compiled in. This is common with some nightly builds." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Solutions:" -ForegroundColor Cyan
        Write-Host "1. The script attempted to use MSVC target. Ensure llvm-tools is installed:" -ForegroundColor White
        Write-Host "   rustup component add llvm-tools-preview" -ForegroundColor Gray
        if ($pgoToolchain) {
            Write-Host "   rustup component add llvm-tools-preview --toolchain $pgoToolchain" -ForegroundColor Gray
        }
        Write-Host ""
        Write-Host "2. If using stable toolchain, ensure it has MSVC target:" -ForegroundColor White
        Write-Host "   rustup toolchain install stable-x86_64-pc-windows-msvc" -ForegroundColor Gray
        Write-Host "   rustup target add x86_64-pc-windows-msvc" -ForegroundColor Gray
        Write-Host ""
        Write-Host "3. Build Rust from source with profiler enabled (advanced)" -ForegroundColor White
    }
    exit 1
}

# Stage 2: Run workload to generate profile data
Write-Host "Stage 2: Running workload to generate profile data..." -ForegroundColor Cyan
Write-Host "Using workload directory: $WorkloadDir"

# Find the built binary (PGO profile builds to pgo profile directory)
if ($pgoTarget) {
    # MSVC target builds to target/<triple>/<profile>/imgc.exe
    $binaryPath = "target\$pgoTarget\pgo\imgc.exe"
    if (!(Test-Path $binaryPath)) {
        $binaryPath = "target\$pgoTarget\release\imgc.exe"
    }
    if (!(Test-Path $binaryPath)) {
        # Fallback to default profile location
        $binaryPath = "target\pgo\imgc.exe"
    }
} else {
    $binaryPath = "target\pgo\imgc.exe"
    if (!(Test-Path $binaryPath)) {
        $binaryPath = "target\release\imgc.exe"
    }
}

if (!(Test-Path $binaryPath)) {
    Write-Error "Built binary not found. Expected at: $binaryPath"
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
    & $binaryPath "$WorkloadDir\**\*" --output $tempOutputDir avif --quality 90 --speed 5
    & $binaryPath "$WorkloadDir\**\*" --output $tempOutputDir avif --quality 90 --speed 3 --overwrite-if-smaller
    
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
$mergedProfdata = "$ProfileDataDirAbs\merged.profdata"
if (!(Test-Path $mergedProfdata)) {
    Write-Error "Merged profile data not found at $mergedProfdata"
    exit 1
}

# Rebuild RUSTFLAGS for optimization stage (replace profile-generate with profile-use)
$rustFlagsList = @()

# Add target-cpu if we had it before
if ($targetCpuValue) {
    $rustFlagsList += "-C target-cpu=$targetCpuValue"
}

# Add PGO optimization flags
$rustFlagsList += "-C profile-use=$mergedProfdata"

# Preserve any existing RUSTFLAGS that aren't target-cpu or PGO-related
if ($env:RUSTFLAGS) {
    $existingFlags = $env:RUSTFLAGS -split '\s+(?=-C)' | Where-Object {
        $_ -notmatch 'target-cpu=' -and 
        $_ -notmatch 'profile-generate=' -and 
        $_ -notmatch 'profile-use='
    }
    if ($existingFlags) {
        $rustFlagsList += $existingFlags
    }
}

# Set the combined RUSTFLAGS
$env:RUSTFLAGS = $rustFlagsList -join ' '
Write-Host "RUSTFLAGS: $env:RUSTFLAGS" -ForegroundColor Gray

if ($pgoTarget) {
    Write-Host "Building optimized binary for target: $pgoTarget" -ForegroundColor Cyan
    if ($pgoToolchain) {
        cargo +$pgoToolchain build --profile pgo --target $pgoTarget
    } else {
        cargo build --profile pgo --target $pgoTarget
    }
} else {
    if ($pgoToolchain) {
        cargo +$pgoToolchain build --profile pgo
    } else {
        cargo build --profile pgo
    }
}

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to build optimized binary"
    exit 1
}

# Clean up environment
Remove-Item Env:RUSTFLAGS

Write-Host "PGO build completed successfully!" -ForegroundColor Green

# Find the final binary location
if ($pgoTarget) {
    $finalBinary = "target\$pgoTarget\pgo\imgc.exe"
    if (!(Test-Path $finalBinary)) {
        $finalBinary = "target\$pgoTarget\release\imgc.exe"
    }
    if (!(Test-Path $finalBinary)) {
        $finalBinary = "target\pgo\imgc.exe"
    }
} else {
    $finalBinary = "target\pgo\imgc.exe"
    if (!(Test-Path $finalBinary)) {
        $finalBinary = "target\release\imgc.exe"
    }
}
Write-Host "Optimized binary available at: $finalBinary"
Write-Host ""
Write-Host "Performance improvements should be most noticeable for:"
Write-Host "- AVIF encoding operations"
Write-Host "- Batch processing of large image sets"
Write-Host "- CPU-intensive image conversion tasks"
