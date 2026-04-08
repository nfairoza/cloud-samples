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

# ---- SUMMARY ----
# NOTE: In this version of p7zip:
#   Tot: line = compression only  -> col $4 = compress Rating MIPS
#   Avr: line = both sides        -> col $4 = compress, col $8 = decompress Rating MIPS

echo "" | tee -a "$OUTFILE"
echo "============================================" | tee -a "$OUTFILE"
echo " SUMMARY - $INSTANCE_TYPE" | tee -a "$OUTFILE"
echo "============================================" | tee -a "$OUTFILE"
echo "" | tee -a "$OUTFILE"

TOT_LINES=$(grep "^Tot:" "$OUTFILE" || true)
AVR_LINES=$(grep "^Avr:" "$OUTFILE" || true)

BEST_COMP=0
BEST_DECOMP=0
AVG_COMP=0
AVG_DECOMP=0

if [[ -n "$TOT_LINES" ]]; then
  # Load into arrays so we can pair Tot (compress) with Avr (decompress) per run
  TOT_ARR=()
  AVR_ARR=()
  while IFS= read -r line; do TOT_ARR+=("$line"); done <<< "$TOT_LINES"
  while IFS= read -r line; do AVR_ARR+=("$line"); done <<< "$AVR_LINES"

  for idx in "${!TOT_ARR[@]}"; do
    COMP=$(echo "${TOT_ARR[$idx]}"   | awk '{print $4}')
    DECOMP=$(echo "${AVR_ARR[$idx]}" | awk '{print $8}')
    echo "  Run $((idx+1)) => Compress: ${COMP} MIPS | Decompress: ${DECOMP} MIPS" | tee -a "$OUTFILE"
  done

  echo "" | tee -a "$OUTFILE"

  BEST_COMP=$(echo "$TOT_LINES"   | awk '{print $4}' | sort -n | tail -1)
  BEST_DECOMP=$(echo "$AVR_LINES" | awk '{print $8}' | sort -n | tail -1)
  AVG_COMP=$(echo "$TOT_LINES"    | awk '{sum+=$4; n++} END {printf "%d", sum/n}')
  AVG_DECOMP=$(echo "$AVR_LINES"  | awk '{sum+=$8; n++} END {printf "%d", sum/n}')

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
