#!/bin/bash
set -euo pipefail

# ============================================
# 7-Zip Benchmark - Works for all instance sizes
# Ubuntu 24.04 | AMD EPYC + Intel Xeon
# ============================================

# ---- METADATA ----
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-type)
INSTANCE=$(echo "$INSTANCE_TYPE" | tr '.' '-')

echo "============================================"
echo " Instance: $INSTANCE_TYPE"
echo " Date:     $(date)"
echo "============================================"

# ---- PREREQS ----
# p7zip-rar does not exist on Ubuntu 24 - only install p7zip-full
echo ""
echo ">>> Installing prerequisites..."
sudo apt-get update -qq
sudo apt-get install -y p7zip-full

# ---- SYSTEM INFO ----
echo ""
echo ">>> System Info:"
VCPUS=$(nproc)
MEM=$(free -g | awk '/^Mem:/ {print $2}')
CPU_MODEL=$(lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
ARCH=$(uname -m)
KERNEL=$(uname -r)
OS=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)

echo "  CPU Model : $CPU_MODEL"
echo "  vCPUs     : $VCPUS"
echo "  Memory    : ${MEM}GB"
echo "  Arch      : $ARCH"
echo "  OS        : $OS"
echo "  Kernel    : $KERNEL"

# ---- SCALE DICTIONARY SIZE BASED ON AVAILABLE RAM ----
# More RAM = larger dictionary = more realistic for asset compression workloads
# This ensures fair comparison across all instance sizes
if   (( MEM >= 256 )); then DICT="512m"
elif (( MEM >= 128 )); then DICT="256m"
elif (( MEM >= 64  )); then DICT="128m"
elif (( MEM >= 32  )); then DICT="64m"
elif (( MEM >= 16  )); then DICT="32m"
else                        DICT="16m"
fi
echo "  Dict Size : $DICT (auto-scaled to RAM)"

# ---- RESULTS DIR ----
RESULTS_DIR="$HOME/benchmark_results"
mkdir -p "$RESULTS_DIR"
OUTFILE="$RESULTS_DIR/7zip_${INSTANCE}_$(date +%Y%m%d_%H%M%S).txt"

cat > "$OUTFILE" << EOF
============================================
 7-Zip Benchmark Results
============================================
 Instance Type : $INSTANCE_TYPE
 CPU Model     : $CPU_MODEL
 vCPUs         : $VCPUS
 Memory        : ${MEM}GB
 Dict Size     : $DICT
 OS            : $OS
 Kernel        : $KERNEL
 Date          : $(date)
============================================

EOF

# ---- RUN BENCHMARK ----
echo ""
echo ">>> Running 7-Zip benchmark: $VCPUS threads, dict=$DICT, 3 runs..."
echo ""

BENCH_START=$(date +%s)

for i in 1 2 3; do
  echo "--- Run $i of 3 ---" | tee -a "$OUTFILE"
  7z b -mmt="$VCPUS" -md="$DICT" 2>&1 | tee -a "$OUTFILE"
  echo "" | tee -a "$OUTFILE"
  sleep 5
done

BENCH_END=$(date +%s)
ELAPSED=$(( BENCH_END - BENCH_START ))

# ---- SUMMARY (only parse benchmark output lines, not header) ----
echo "" | tee -a "$OUTFILE"
echo "============================================" | tee -a "$OUTFILE"
echo " SUMMARY - $INSTANCE_TYPE" | tee -a "$OUTFILE"
echo "============================================" | tee -a "$OUTFILE"
echo "" | tee -a "$OUTFILE"

# Extract Tot lines - per-run totals from 7z b output
TOT_LINES=$(grep "^Tot:" "$OUTFILE" || true)

BEST_COMP=0
BEST_DECOMP=0

if [[ -n "$TOT_LINES" ]]; then
  RUN=1
  while IFS= read -r line; do
    COMP=$(echo "$line"   | awk '{print $4}')
    DECOMP=$(echo "$line" | awk '{print $8}')
    echo "  Run $RUN => Compress: ${COMP} MIPS | Decompress: ${DECOMP} MIPS" | tee -a "$OUTFILE"
    (( RUN++ ))
  done <<< "$TOT_LINES"

  echo "" | tee -a "$OUTFILE"

  BEST_COMP=$(echo "$TOT_LINES"   | awk '{print $4}' | sort -n | tail -1)
  BEST_DECOMP=$(echo "$TOT_LINES" | awk '{print $8}' | sort -n | tail -1)
  AVG_COMP=$(echo "$TOT_LINES"    | awk '{sum+=$4; n++} END {printf "%d", sum/n}')
  AVG_DECOMP=$(echo "$TOT_LINES"  | awk '{sum+=$8; n++} END {printf "%d", sum/n}')

  echo "  Best  => Compress: ${BEST_COMP} MIPS | Decompress: ${BEST_DECOMP} MIPS" | tee -a "$OUTFILE"
  echo "  Avg   => Compress: ${AVG_COMP} MIPS  | Decompress: ${AVG_DECOMP} MIPS"  | tee -a "$OUTFILE"
fi

echo "" | tee -a "$OUTFILE"
echo "  Total benchmark time: ${ELAPSED}s" | tee -a "$OUTFILE"
echo "============================================" | tee -a "$OUTFILE"

echo ""
echo ">>> FINAL SCORES for $INSTANCE_TYPE"
echo "    Best Compression:   ${BEST_COMP} MIPS"
echo "    Best Decompression: ${BEST_DECOMP} MIPS"
echo "    Avg  Compression:   ${AVG_COMP} MIPS"
echo "    Avg  Decompression: ${AVG_DECOMP} MIPS"
echo ""
echo "Results saved to: $OUTFILE"
echo "============================================"
