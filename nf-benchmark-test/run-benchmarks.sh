#!/bin/bash
. ./benchmarks_environment.sh
PATH=/bin:/usr/bin:/usr/sbin:$PATH

# Telemetry wrapper around the benchmarks
function startprofiling {
	nohup bash ./binaries/perfspect/start_perfspect.sh $DIR $1 >> $DIR/LOG 2>&1 &
}

function stopprofiling {
	nohup bash ./binaries/perfspect/stop_perfspect.sh >> $DIR/LOG 2>&1 &
	sleep 10
}
#ALL Benchmark TESTS
echo "Benchmarks started at: $DATE " >>$DIR/INFO

# Check if multiple containers are running
if [[ -z "$GROUP" ]]; then
    startprofiling mlc
    ./benchmarks/mlc.py
    stopprofiling
else
    echo "⚠️ Skipping MLC benchmark because multiple containers are running (GROUP=$GROUP)." | tee -a $DIR/INFO
fi

startprofiling compress-7zip
./benchmarks/compress-7zip.py
stopprofiling
#
#startprofiling ffmpeg
#/usr/share/autobench/java17-benchmarks/ffmpeg.py
#stopprofiling
#
startprofiling specjvm2008
./benchmarks/specjvm2008.py
stopprofiling
#
startprofiling renaissance
./benchmarks/renaissance.py
stopprofiling
#
startprofiling lmbench-bw
./benchmarks/lmbench-bw.py
stopprofiling
#
#startprofiling lmbench-mhz
#/usr/share/autobench/java17-benchmarks/lmbench-mhz.py
#stopprofiling
#
startprofiling lmbench-mem
./benchmarks/lmbench-mem.py
stopprofiling
#
startprofiling lmbench-ops
./benchmarks/lmbench-ops.py
stopprofiling
#
startprofiling openssl
./benchmarks/openssl.py
stopprofiling
#
startprofiling stream
./benchmarks/stream.py
stopprofiling
#
startprofiling sysbench-cpu
./benchmarks/sysbench-cpu.py
stopprofiling
#
startprofiling sysbench-mem
./benchmarks/sysbench-mem.py
stopprofiling
#
#startprofiling ffmpeg-downsampler-encode.sh
#./benchmarks/ffmpeg-downsampler-encode.sh
#stopprofiling
#
#startprofiling ffmpeg-h264-prores_encode.sh
#./benchmarks/ffmpeg-h264-prores_encode.sh
#stopprofiling
#
#startprofiling ffmpeg-h264-j2k_encode.sh
#./benchmarks/ffmpeg-h264-j2k_encode.sh
#stopprofiling
#
#startprofiling ffmpeg-vmaf.sh
#./benchmarks/ffmpeg-vmaf.sh
#stopprofiling
#
startprofiling specjbb2015
./benchmarks/specjbb2015.sh
stopprofiling
#
# Copy to LATEST Directory
if [[ -z "$GROUP" ]]; then
cp -r $DIR/* $LDIR
fi
DATE=$(date '+%m-%d-%Y_%H-%M')
echo "Benchmarks ended at: $DATE" >> $DIR/INFO
