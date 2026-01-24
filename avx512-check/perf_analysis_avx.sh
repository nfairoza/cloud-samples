#!/bin/bash

#############################################################################
# monitor_dgemm.sh
#
# Comprehensive monitoring and analysis script for DGEMM AVX512 benchmark
#
# Usage:
#   ./monitor_dgemm.sh [duration_seconds]
#
# Example:
#   ./monitor_dgemm.sh 30
#############################################################################

# Default duration
DURATION=${1:-30}
OUTPUT_FILE="perf_analysis_$(date +%Y%m%d_%H%M%S).txt"

echo "========================================"
echo "DGEMM AVX512 Performance Monitor"
echo "========================================"
echo "Duration: ${DURATION} seconds"
echo "Output: ${OUTPUT_FILE}"
echo ""

# Find the DGEMM process
PID=$(pgrep -f dgemm_avx512_new)

if [ -z "$PID" ]; then
    echo "ERROR: dgemm_avx512_new process not found!"
    echo ""
    echo "Please start the benchmark first:"
    echo "  ./dgemm_avx512_new 4096 120 &"
    echo ""
    exit 1
fi

echo "Found PID: $PID"
echo ""

# Get process info
echo "Process Information:"
ps -p $PID -o pid,ppid,cmd,etime,%cpu,%mem
echo ""

echo "Starting performance monitoring for ${DURATION} seconds..."
echo ""

# Run perf stat with comprehensive events
perf stat \
  -e cycles,instructions \
  -e cache-references,cache-misses \
  -e L1-dcache-loads,L1-dcache-load-misses \
  -e LLC-loads,LLC-load-misses \
  -e branch-instructions,branch-misses \
  -e fp_ops_retired_by_width.pack_128_uops_retired \
  -e fp_ops_retired_by_width.pack_256_uops_retired \
  -e fp_ops_retired_by_width.pack_512_uops_retired \
  -e fp_ops_retired_by_width.scalar_uops_retired \
  -e fp_ops_retired_by_width.all \
  -e fp_ret_sse_avx_ops.all \
  -e fp_ops_retired_by_type.vector_mac \
  -e fp_ops_retired_by_type.vector_mul \
  -e fp_ops_retired_by_type.vector_add \
  -e ex_ret_mmx_fp_instr.sse \
  -p $PID -- sleep $DURATION 2>&1 | tee "$OUTPUT_FILE"

echo ""
echo "========================================"
echo "Performance Analysis"
echo "========================================"
echo ""

# Extract values from output file
CYCLES=$(grep "cycles" "$OUTPUT_FILE" | head -1 | awk '{print $1}' | tr -d ',')
INSTRUCTIONS=$(grep "instructions" "$OUTPUT_FILE" | head -1 | awk '{print $1}' | tr -d ',')
CACHE_REF=$(grep "cache-references" "$OUTPUT_FILE" | awk '{print $1}' | tr -d ',')
CACHE_MISS=$(grep "cache-misses" "$OUTPUT_FILE" | awk '{print $1}' | tr -d ',')
BRANCH_INSTR=$(grep "branch-instructions" "$OUTPUT_FILE" | awk '{print $1}' | tr -d ',')
BRANCH_MISS=$(grep "branch-misses" "$OUTPUT_FILE" | head -1 | awk '{print $1}' | tr -d ',')
L1_LOADS=$(grep "L1-dcache-loads" "$OUTPUT_FILE" | head -1 | awk '{print $1}' | tr -d ',')
L1_MISS=$(grep "L1-dcache-load-misses" "$OUTPUT_FILE" | awk '{print $1}' | tr -d ',')
LLC_LOADS=$(grep "LLC-loads" "$OUTPUT_FILE" | head -1 | awk '{print $1}' | tr -d ',')
LLC_MISS=$(grep "LLC-load-misses" "$OUTPUT_FILE" | awk '{print $1}' | tr -d ',')

PACK_512=$(grep "pack_512_uops_retired" "$OUTPUT_FILE" | awk '{print $1}' | tr -d ',')
PACK_256=$(grep "pack_256_uops_retired" "$OUTPUT_FILE" | awk '{print $1}' | tr -d ',')
PACK_128=$(grep "pack_128_uops_retired" "$OUTPUT_FILE" | awk '{print $1}' | tr -d ',')
SCALAR=$(grep "scalar_uops_retired" "$OUTPUT_FILE" | awk '{print $1}' | tr -d ',')
FP_ALL=$(grep "fp_ops_retired_by_width.all" "$OUTPUT_FILE" | awk '{print $1}' | tr -d ',')
SSE_AVX_ALL=$(grep "fp_ret_sse_avx_ops.all" "$OUTPUT_FILE" | awk '{print $1}' | tr -d ',')
VECTOR_MAC=$(grep "vector_mac" "$OUTPUT_FILE" | awk '{print $1}' | tr -d ',')
VECTOR_MUL=$(grep "vector_mul" "$OUTPUT_FILE" | awk '{print $1}' | tr -d ',')
VECTOR_ADD=$(grep "vector_add" "$OUTPUT_FILE" | awk '{print $1}' | tr -d ',')

# Calculate metrics
if [ -n "$CYCLES" ] && [ -n "$INSTRUCTIONS" ] && [ "$CYCLES" -gt 0 ]; then
    IPC=$(echo "scale=3; $INSTRUCTIONS / $CYCLES" | bc)
else
    IPC="N/A"
fi

if [ -n "$CACHE_REF" ] && [ -n "$CACHE_MISS" ] && [ "$CACHE_REF" -gt 0 ]; then
    CACHE_MISS_RATE=$(echo "scale=2; $CACHE_MISS * 100 / $CACHE_REF" | bc)
else
    CACHE_MISS_RATE="N/A"
fi

if [ -n "$BRANCH_INSTR" ] && [ -n "$BRANCH_MISS" ] && [ "$BRANCH_INSTR" -gt 0 ]; then
    BRANCH_MISS_RATE=$(echo "scale=3; $BRANCH_MISS * 100 / $BRANCH_INSTR" | bc)
else
    BRANCH_MISS_RATE="N/A"
fi

if [ -n "$L1_LOADS" ] && [ -n "$L1_MISS" ] && [ "$L1_LOADS" -gt 0 ]; then
    L1_MISS_RATE=$(echo "scale=2; $L1_MISS * 100 / $L1_LOADS" | bc)
else
    L1_MISS_RATE="N/A"
fi

if [ -n "$LLC_LOADS" ] && [ -n "$LLC_MISS" ] && [ "$LLC_LOADS" -gt 0 ]; then
    LLC_MISS_RATE=$(echo "scale=2; $LLC_MISS * 100 / $LLC_LOADS" | bc)
else
    LLC_MISS_RATE="N/A"
fi

# Calculate AVX512 usage percentage
if [ -n "$PACK_512" ] && [ -n "$PACK_256" ] && [ -n "$PACK_128" ] && [ -n "$SCALAR" ]; then
    TOTAL_FP=$((PACK_512 + PACK_256 + PACK_128 + SCALAR))
    if [ "$TOTAL_FP" -gt 0 ]; then
        PCT_512=$(echo "scale=2; $PACK_512 * 100 / $TOTAL_FP" | bc)
        PCT_256=$(echo "scale=4; $PACK_256 * 100 / $TOTAL_FP" | bc)
        PCT_128=$(echo "scale=4; $PACK_128 * 100 / $TOTAL_FP" | bc)
        PCT_SCALAR=$(echo "scale=6; $SCALAR * 100 / $TOTAL_FP" | bc)
    else
        PCT_512="N/A"
        PCT_256="N/A"
        PCT_128="N/A"
        PCT_SCALAR="N/A"
    fi
else
    TOTAL_FP="N/A"
    PCT_512="N/A"
    PCT_256="N/A"
    PCT_128="N/A"
    PCT_SCALAR="N/A"
fi

# Print analysis
echo "=== CPU Performance ==="
printf "  %-30s %20s\n" "Instructions Per Cycle (IPC):" "$IPC"
printf "  %-30s %20s\n" "Total Cycles:" "$(printf "%'d" $CYCLES 2>/dev/null || echo $CYCLES)"
printf "  %-30s %20s\n" "Total Instructions:" "$(printf "%'d" $INSTRUCTIONS 2>/dev/null || echo $INSTRUCTIONS)"
echo ""

echo "=== Cache Performance ==="
printf "  %-30s %20s\n" "Cache Miss Rate:" "${CACHE_MISS_RATE}%"
printf "  %-30s %20s\n" "L1 D-Cache Miss Rate:" "${L1_MISS_RATE}%"
printf "  %-30s %20s\n" "LLC Miss Rate:" "${LLC_MISS_RATE}%"
printf "  %-30s %20s\n" "Branch Miss Rate:" "${BRANCH_MISS_RATE}%"
echo ""

echo "=== AVX/AVX512 Vector Width Distribution ==="
printf "  %-30s %20s (%s)\n" "512-bit (AVX512):" "$(printf "%'d" $PACK_512 2>/dev/null || echo $PACK_512)" "${PCT_512}%"
printf "  %-30s %20s (%s)\n" "256-bit (AVX):" "$(printf "%'d" $PACK_256 2>/dev/null || echo $PACK_256)" "${PCT_256}%"
printf "  %-30s %20s (%s)\n" "128-bit (SSE/AVX):" "$(printf "%'d" $PACK_128 2>/dev/null || echo $PACK_128)" "${PCT_128}%"
printf "  %-30s %20s (%s)\n" "Scalar:" "$(printf "%'d" $SCALAR 2>/dev/null || echo $SCALAR)" "${PCT_SCALAR}%"
printf "  %-30s %20s\n" "Total FP Ops:" "$(printf "%'d" $TOTAL_FP 2>/dev/null || echo $TOTAL_FP)"
echo ""

echo "=== Floating-Point Operation Types ==="
printf "  %-30s %20s\n" "Vector MAC (FMA):" "$(printf "%'d" $VECTOR_MAC 2>/dev/null || echo $VECTOR_MAC)"
printf "  %-30s %20s\n" "Vector Multiply:" "$(printf "%'d" $VECTOR_MUL 2>/dev/null || echo $VECTOR_MUL)"
printf "  %-30s %20s\n" "Vector Add:" "$(printf "%'d" $VECTOR_ADD 2>/dev/null || echo $VECTOR_ADD)"
echo ""

echo "=== Assessment ==="

# IPC assessment
if [ "$IPC" != "N/A" ]; then
    IPC_NUM=$(echo "$IPC" | bc)
    if (( $(echo "$IPC_NUM >= 2.5" | bc -l) )); then
        echo "  IPC: Excellent (>= 2.5)"
    elif (( $(echo "$IPC_NUM >= 2.0" | bc -l) )); then
        echo "  IPC: Good (>= 2.0)"
    elif (( $(echo "$IPC_NUM >= 1.5" | bc -l) )); then
        echo "  IPC: Fair (>= 1.5)"
    else
        echo "  IPC: Poor (< 1.5)"
    fi
fi

# Cache miss rate assessment
if [ "$CACHE_MISS_RATE" != "N/A" ]; then
    CACHE_NUM=$(echo "$CACHE_MISS_RATE" | bc)
    if (( $(echo "$CACHE_NUM <= 3.0" | bc -l) )); then
        echo "  Cache Performance: Excellent (<= 3% miss rate)"
    elif (( $(echo "$CACHE_NUM <= 5.0" | bc -l) )); then
        echo "  Cache Performance: Good (<= 5% miss rate)"
    elif (( $(echo "$CACHE_NUM <= 10.0" | bc -l) )); then
        echo "  Cache Performance: Fair (<= 10% miss rate)"
    else
        echo "  Cache Performance: Poor (> 10% miss rate)"
    fi
fi

# AVX512 usage assessment
if [ "$PCT_512" != "N/A" ]; then
    AVX512_NUM=$(echo "$PCT_512" | bc)
    if (( $(echo "$AVX512_NUM >= 95.0" | bc -l) )); then
        echo "  AVX512 Usage: Excellent (>= 95%)"
    elif (( $(echo "$AVX512_NUM >= 80.0" | bc -l) )); then
        echo "  AVX512 Usage: Good (>= 80%)"
    elif (( $(echo "$AVX512_NUM >= 50.0" | bc -l) )); then
        echo "  AVX512 Usage: Fair (>= 50%)"
    else
        echo "  AVX512 Usage: Poor (< 50%)"
    fi
fi

echo ""
echo "========================================"
echo "Analysis complete!"
echo "Full results saved to: $OUTPUT_FILE"
echo "========================================"
