# DGEMM AVX512 Benchmark

A high-performance matrix multiplication benchmark using OpenBLAS to stress-test AVX512 instructions and monitor CPU performance.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Installation](#installation)
- [Usage](#usage)
- [Monitoring with ProcessWatch](#monitoring-with-processwatch)
- [Performance Tuning](#performance-tuning)
- [Troubleshooting](#troubleshooting)

## Overview

This benchmark performs repeated double-precision general matrix multiplication (DGEMM) operations using OpenBLAS. It's designed to:

- Maximize AVX512 instruction usage on compatible CPUs
- Provide a consistent workload for performance monitoring
- Support multi-threaded execution with thread pinning

**What it does:** Computes `C = A × B` repeatedly for square matrices of configurable size, where A and B are initialized with known values for result validation.

## Prerequisites

### System Requirements

- **OS:** Linux (Ubuntu/Debian recommended)
- **CPU:** x86_64 with AVX512 support
- **RAM:** Varies by matrix size (4096×4096 requires ~384 MB per matrix, 3 matrices total)
- **Compiler:** GCC 7.0+ or Clang 5.0+
- **Privileges:** sudo/root access for monitoring tools

### Check AVX512 Support

```bash
# Check if your CPU supports AVX512
grep avx512 /proc/cpuinfo
```

If this returns results, your CPU supports AVX512.

## Quick Start

```bash
# 1. Install dependencies
sudo apt-get update
sudo apt-get install -y build-essential libopenblas-dev

# 2. Clone this repository
git clone https://github.com/nfairoza/cloud-samples.git
cd avx512-check

# 3. Compile
gcc -O3 -march=native dgemm_avx512.c -lopenblas -o dgemm_avx512

# 4. Run with defaults (4096×4096 matrix, 60 seconds)
./dgemm_avx512

# 5. Run with custom parameters
./dgemm_avx512 8192 120
```

## Installation

### Step 1: Install Build Tools and OpenBLAS

```bash
# Update package repositories
sudo apt-get update

# Install compiler and OpenBLAS library
sudo apt-get install -y build-essential libopenblas-dev numactl

# Verify CBLAS headers are available
ls /usr/include/x86_64-linux-gnu/cblas.h
```

### Step 2: Install Intel ProcessWatch (Optional)

ProcessWatch is Intel's tool for monitoring instruction set usage in real-time.

```bash
# Clone the repository
git clone https://github.com/intel/processwatch.git
cd processwatch

# Build
make

# Test (you should see usage information)
./processwatch --help

# Return to benchmark directory
cd ..
```

### Step 3: Install Additional Monitoring Tools

#### stress-ng (for validation)
```bash
sudo apt-get install -y stress-ng
```

#### perf (for detailed profiling)
```bash
# Try system package first
sudo apt-get install -y linux-tools-generic linux-tools-common linux-tools-$(uname -r)

# If unavailable, build from source (see Advanced Installation section)
```

### Step 4: Compile the Benchmark

```bash
# Compile with optimizations
gcc -O3 -march=native dgemm_avx512.c -lopenblas -o dgemm_avx512

# Verify compilation
./dgemm_avx512 --help 2>&1 || echo "Binary created successfully"
```

## Usage

### Basic Usage

```bash
./dgemm_avx512 [matrix_size] [duration_seconds]
```

**Parameters:**
- `matrix_size` (optional, default: 4096): Dimension of square matrices (N×N)
- `duration_seconds` (optional, default: 60): How long to run the benchmark

**Examples:**

```bash
# Run with defaults (4096×4096, 60 seconds)
./dgemm_avx512

# Small quick test (1024×1024, 10 seconds)
./dgemm_avx512 1024 10

# Large intensive test (8192×8192, 300 seconds)
./dgemm_avx512 8192 300

# Maximum stress test (16384×16384, 600 seconds)
# Warning: Requires ~24 GB RAM
./dgemm_avx512 16384 600
```

### Multi-threaded Execution

For systems with many cores, use thread pinning for optimal performance:

```bash
# Set number of threads (adjust to your CPU core count)
export OPENBLAS_NUM_THREADS=64
export OMP_NUM_THREADS=64

# Pin to specific CPU cores (0-63 in this example)
taskset -c 0-63 ./dgemm_avx512 4096 60
```

**Finding your core count:**
```bash
# Total logical CPUs (including hyperthreading)
nproc

# Physical cores only
lscpu | grep "Core(s) per socket"
```



## Monitoring with ProcessWatch

ProcessWatch allows real-time monitoring of instruction set usage.

### Two-Terminal Monitoring Setup

**Terminal 1:** Run the benchmark depending on your target system
```bash
export OPENBLAS_NUM_THREADS=64
export OMP_NUM_THREADS=64
taskset -c 0-63 ./dgemm_avx512 4096 60
```

**Terminal 2:** Monitor with ProcessWatch
```bash
cd processwatch
# Basic instruction monitoring
sudo ./processwatch -p $(pgrep -f dgemm_avx512) -f SSE -f AVX -f AVX2 -f AVX512 -f AMX_TILE 2>/dev/null
```


### Matrix Size Selection

Choose matrix sizes based on your goals:

| Matrix Size | Memory per Matrix | Total Memory | Use Case |
|-------------|-------------------|--------------|----------|
| 1024        | 8 MB              | 24 MB        | Quick testing |
| 2048        | 32 MB             | 96 MB        | Development |
| 4096        | 128 MB            | 384 MB       | Standard benchmark |
| 8192        | 512 MB            | 1.5 GB       | Stress test |
| 16384       | 2 GB              | 6 GB         | Maximum stress |

**Tips:**
- Use multiples of 64 or 128 for cache alignment
- Larger matrices = better AVX512 utilization
- Ensure total memory < 80% of available RAM

### Thread Count Optimization

```bash
# Optimal thread count = physical core count
CORES=$(lscpu | grep "Core(s) per socket:" | awk '{print $4}')
SOCKETS=$(lscpu | grep "Socket(s):" | awk '{print $2}')
OPTIMAL=$((CORES * SOCKETS))

export OPENBLAS_NUM_THREADS=$OPTIMAL
export OMP_NUM_THREADS=$OPTIMAL

echo "Using $OPTIMAL threads"
./dgemm_avx512 4096 60
```

## System Information

Check your system configuration before running benchmarks:

```bash
echo "=== OS ===" && cat /etc/os-release && \
echo -e "\n=== CPU ===" && lscpu | grep -E "Model name|CPU\(s\)|Thread\(s\)|Core\(s\)" && \
echo -e "\n=== AVX Support ===" && grep -o 'avx[^ ]*' /proc/cpuinfo | sort -u && \
echo -e "\n=== Memory ===" && free -h && \
echo -e "\n=== GCC Version ===" && gcc --version 2>&1 | head -n 1
```

## Understanding the Output

### Benchmark Output

```
========================================
DGEMM AVX512 Benchmark
========================================
Matrix size: 4096 x 4096
Memory per matrix: 0.13 GB
Total memory: 0.38 GB
Duration: 60 seconds
========================================
Running benchmark...

Iteration 10 (elapsed: 15s)
Iteration 20 (elapsed: 30s)
Iteration 30 (elapsed: 45s)

========================================
Benchmark Complete
========================================
Total iterations: 42
Actual duration: 60 seconds
Iterations/sec: 0.70
Validation: C[0] = 8192.00 (expected: 8192.00)
Status: PASS ✓
========================================
```

**Key Metrics:**
- **Total iterations**: Number of complete matrix multiplications
- **Iterations/sec**: Throughput metric (higher = better)
- **Validation**: Sanity check (C[0] should equal N × 2.0)
- **Status**: PASS if computation is correct

### ProcessWatch Output

Example output:
```
PID      NAME             SSE      AVX      AVX2     AVX512   AMX_TILE %TOTAL   TOTAL
ALL      ALL              0.00     0.00     0.00     0.12     0.00     100.00   93383
732074   dgemm_avx512     0.00     0.00     0.00     0.12     0.00     100.00   93383

PID      NAME             SSE      AVX      AVX2     AVX512   AMX_TILE %TOTAL   TOTAL
ALL      ALL              0.00     0.00     0.00     0.16     0.00     100.00   98356
732074   dgemm_avx512     0.00     0.00     0.00     0.16     0.00     100.00   98356


```

AVX512: The decimal (e.g., 0.12) represents the percentage of instructions using AVX-512 (12%).
TOTAL: The raw number of instructions processed in that specific sample.
