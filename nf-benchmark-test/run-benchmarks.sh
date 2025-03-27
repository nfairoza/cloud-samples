#!/bin/bash
. ./benchmarks_environment.sh
PATH=/bin:/usr/bin:/usr/sbin:$PATH

echo ".......................||||Starting Benchmarks||||.........................."

# Telemetry wrapper around the benchmarks
function startprofiling {
	echo "📊 Starting benchmark: $1..."
	nohup bash ./binaries/perfspect/start_perfspect.sh $DIR $1 >> $DIR/LOG 2>&1 &
}

function stopprofiling {
	echo "✅ Benchmark completed! Moving to next test..."
	nohup bash ./binaries/perfspect/stop_perfspect.sh >> $DIR/LOG 2>&1 &
	sleep 10
}

# Progress tracker
TOTAL_BENCHMARKS=11
CURRENT_BENCHMARK=0

function update_progress {
	CURRENT_BENCHMARK=$((CURRENT_BENCHMARK + 1))
	echo "🔄 Progress: $CURRENT_BENCHMARK/$TOTAL_BENCHMARKS benchmarks completed ($(($CURRENT_BENCHMARK * 100 / $TOTAL_BENCHMARKS))%)"
}

#ALL Benchmark TESTS
echo "Benchmarks started at: $DATE " | tee -a $DIR/INFO
echo "📂 Results will be saved to: $DIR" | tee -a $DIR/INFO

# Check if multiple containers are running
if [[ -z "$GROUP" ]]; then
    startprofiling mlc
    echo "⏳ Running MLC (Memory Latency Checker)..."
    ./benchmarks/mlc.py
    stopprofiling
    update_progress
else
    echo "⚠️ Skipping MLC benchmark because multiple containers are running (GROUP=$GROUP)." | tee -a $DIR/INFO
fi

startprofiling compress-7zip
echo "⏳ Running compress-7zip benchmark..."
./benchmarks/compress-7zip.py
stopprofiling
update_progress

#startprofiling ffmpeg
#echo "⏳ Running ffmpeg benchmark..."
#/usr/share/autobench/java17-benchmarks/ffmpeg.py
#stopprofiling
#update_progress

startprofiling specjvm2008
echo "⏳ Running specjvm2008 benchmark (this may take a while)..."
./benchmarks/specjvm2008.py
stopprofiling
update_progress

startprofiling renaissance
echo "⏳ Running renaissance benchmark..."
./benchmarks/renaissance.py
stopprofiling
update_progress

startprofiling lmbench-bw
echo "⏳ Running lmbench-bw benchmark..."
./benchmarks/lmbench-bw.py
stopprofiling
update_progress

#startprofiling lmbench-mhz
#echo "⏳ Running lmbench-mhz benchmark..."
#/usr/share/autobench/java17-benchmarks/lmbench-mhz.py
#stopprofiling
#update_progress

startprofiling lmbench-mem
echo "⏳ Running lmbench-mem benchmark..."
./benchmarks/lmbench-mem.py
stopprofiling
update_progress

startprofiling lmbench-ops
echo "⏳ Running lmbench-ops benchmark..."
./benchmarks/lmbench-ops.py
stopprofiling
update_progress

startprofiling openssl
echo "⏳ Running openssl benchmark..."
./benchmarks/openssl.py
stopprofiling
update_progress

startprofiling stream
echo "⏳ Running stream benchmark..."
./benchmarks/stream.py
stopprofiling
update_progress

startprofiling sysbench-cpu
echo "⏳ Running sysbench-cpu benchmark..."
./benchmarks/sysbench-cpu.py
stopprofiling
update_progress

startprofiling sysbench-mem
echo "⏳ Running sysbench-mem benchmark..."
./benchmarks/sysbench-mem.py
stopprofiling
update_progress

#startprofiling ffmpeg-downsampler-encode.sh
#echo "⏳ Running ffmpeg-downsampler-encode benchmark..."
#./benchmarks/ffmpeg-downsampler-encode.sh
#stopprofiling
#update_progress

#startprofiling ffmpeg-h264-prores_encode.sh
#echo "⏳ Running ffmpeg-h264-prores_encode benchmark..."
#./benchmarks/ffmpeg-h264-prores_encode.sh
#stopprofiling
#update_progress

#startprofiling ffmpeg-h264-j2k_encode.sh
#echo "⏳ Running ffmpeg-h264-j2k_encode benchmark..."
#./benchmarks/ffmpeg-h264-j2k_encode.sh
#stopprofiling
#update_progress

#startprofiling ffmpeg-vmaf.sh
#echo "⏳ Running ffmpeg-vmaf benchmark..."
#./benchmarks/ffmpeg-vmaf.sh
#stopprofiling
#update_progress

startprofiling specjbb2015
echo "⏳ Running specjbb2015 benchmark (this is usually the longest test)..."
./benchmarks/specjbb2015.sh
stopprofiling
update_progress

echo "🎉 All benchmarks completed successfully!"

# Copy to LATEST Directory
if [[ -z "$GROUP" ]]; then
    echo "📋 Copying results to LATEST directory..."
    cp -r $DIR/* $LDIR
fi

DATE=$(date '+%m-%d-%Y_%H-%M')
echo "Benchmarks ended at: $DATE" | tee -a $DIR/INFO
echo ".......................||||Benchmarks Complete||||.........................."
