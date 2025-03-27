#!/bin/bash
#
#   Benchmark Environment Variables
#   --------------------------------
#

# Get instance type directly from EC2 metadata service
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
EC2_INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
echo "Detected EC2 instance type: $EC2_INSTANCE_TYPE"

# Extract CPU topology more accurately
CORES_PER_SOCKET=$(lscpu | grep "Core(s) per socket" | awk '{print $4}')
SOCKETS=$(lscpu | grep "Socket(s)" | awk '{print $2}')
THREADS_PER_CORE=$(lscpu | grep "Thread(s) per core" | awk '{print $4}')
TOTAL_CORES=$((CORES_PER_SOCKET * SOCKETS))
export VCPUS=$((TOTAL_CORES * THREADS_PER_CORE))
echo "vCPUs: $VCPUS (${CORES_PER_SOCKET} cores/socket × ${SOCKETS} sockets × ${THREADS_PER_CORE} threads/core)"

# xtract instance size for heap determination
INSTANCE_SIZE=$(echo "$EC2_INSTANCE_TYPE" | cut -d. -f2)
# Mapping model name to CPU family
if echo "$MODEL_NAME" | grep -qi "EPYC 9[0-9][0-9][0-9]"; then
    FAMILY="Genoa"
elif echo "$MODEL_NAME" | grep -qi "EPYC 9[0-9][0-9][0-9]X"; then
    FAMILY="Turin"
elif echo "$MODEL_NAME" | grep -qi "Xeon"; then
    FAMILY="SapphireRapids"
else
    FAMILY="Unknown"
fi

# Export the instance identifier (used -)
export INSTANCE=$(echo "$EC2_INSTANCE_TYPE" | sed -e 's/\./-/')

echo "Exported INSTANCE: $INSTANCE"

EC2_LOCAL_IPV4=$(hostname -I | awk '{print $1}')
EC2_INSTANCE_ID="$(hostname)-$(hostid)"
EC2_ACCOUNT_ID="521597827845"
EC2_ROLE="perfeng_lab_role"
DISTRIB_RELEASE=$(grep "VERSION_ID" /etc/os-release | cut -d '"' -f2)
DISTRIB_DESCRIPTION=$(grep "PRETTY_NAME" /etc/os-release | cut -d '"' -f2)
DISTRIB_CODENAME=$(grep "VERSION_CODENAME" /etc/os-release | cut -d '=' -f2)
LAB_LOCATION="San Jose"
ENV="sjclab"
REGION="sjc002"
APPNAME="benchmarkHarness"
CLUSTER="benchmarkHarness"
ASG="benchmarkHarness-v000"
CPUs=$(lscpu | grep "^CPU(s):" | awk '{print $2}')
# GPUS=$(nvidia-smi -L | wc -l 2>/dev/null || echo "none")
MEM=$(free -g | awk '/^Mem:/ {print $2}')
# GPUMODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader | uniq || echo "None")
#-------
export DATE=$(date '+%m-%d-%Y_%H-%M')
export TS=`echo $(date '+%m-%d-%Y_%s')`

# We need m7i.metal-48xl to be m7i-metal48xl
UNAME=`uname -r`
KERNEL=`echo $UNAME|sed -e 's/\.//g'`
BASEOS=$(grep "VERSION_CODENAME" /etc/os-release | cut -d '=' -f2)
export JVM="OpenJDK$(java --version | awk 'NR==1 {print $2}' | cut -d. -f1)"
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))
#-------
# Garbage collectors: SerialGC,ParallelGC,G1GC,ZGC,ShenandoahGC,
# Change GC environment variable here to run specjbb2015 with different Garbage Collector: ex: export GC='ShenandoahGC"
#-------
export GC='G1GC'

# Set heap size based on instance type
if [[ $INSTANCE_TYPE =~ "metal48xl" || $INSTANCE_SIZE =~ "metal" || $INSTANCE_SIZE =~ "metal-48xl" ]]; then
  export Heap='96g'
elif [[ $INSTANCE_SIZE =~ "48xlarge" ]]; then
  export Heap='96g'
elif [[ $INSTANCE_SIZE =~ "32xlarge" ]]; then
  export Heap='96g'
elif [[ $INSTANCE_SIZE =~ "24xlarge" ]]; then
  export Heap='64g'
elif [[ $INSTANCE_SIZE =~ "16xlarge" ]]; then
  export Heap='64g'
elif [[ $INSTANCE_SIZE =~ "12xlarge" ]]; then
  export Heap='32g'
elif [[ $INSTANCE_SIZE =~ "8xlarge" ]]; then
  export Heap='32g'
elif [[ $INSTANCE_SIZE =~ "4xlarge" ]]; then
  export Heap='16g'
elif [[ $INSTANCE_SIZE =~ "2xlarge" ]]; then
  export Heap='8g'
elif [[ $INSTANCE_SIZE =~ "xlarge" ]]; then
  export Heap='4g'
elif [[ $INSTANCE_SIZE =~ "large" ]]; then
  export Heap='2g'
elif [[ $INSTANCE_SIZE =~ "medium" ]]; then
  export Heap='250m'
else
  # Default: calculate based on available memory
  TOTAL_MEM=$(free -g | awk '/^Mem:/ {print $2}')
  export Heap="$((TOTAL_MEM / 2))g"  # Use half of system memory
fi

# If GROUP is set, use it for results directory
# if [[ -n "$GROUP" ]]; then
#     RESULTS="/efs/html/AUTOBENCH/LAB_RESULTS/$GROUP"
# else
#     RESULTS="/efs/html/AUTOBENCH/LAB_RESULTS"
# fi

LOCAL_RESULTS_DIR="/home/ubuntu/benchmark_results"
export LOCAL_RESULTS_DIR=$(echo "$LOCAL_RESULTS_DIR")

if [[ -n "$GROUP" ]]; then
    RESULTS="$LOCAL_RESULTS_DIR/$GROUP"
else
    RESULTS="$LOCAL_RESULTS_DIR"
fi

export RESULTS
export DIR="$RESULTS/$INSTANCE-$BASEOS-$KERNEL-$JVM-$GC-$Heap-$TS"
export LDIR="$RESULTS/$INSTANCE-LATEST"

mkdir -p $DIR

if [ -d "$LDIR" ];
then
 rm -rf $LDIR
fi

if [[ -n "$GROUP" ]]; then
    # GROUP is set: remove $LDIR if it exists, but don't recreate it
    if [ -d "$LDIR" ]; then
        rm -rf "$LDIR"
    fi
else
    # GROUP is empty: create $LDIR
    mkdir -p "$LDIR"
fi

echo "✅ Results directory set to: $DIR"
echo "✅ Latest results directory set to: $LDIR"
# ------logging---
# log stdout/stderr as well as the bash execution trace for this script to LOG_DIR
readonly LOG_DIR=$DIR
printf -v LOG_NAME 'autobench.%(%Y%m%d%H%M%S)T' -1
readonly LOG_NAME
readonly LOG_FILE="${LOG_DIR}/${LOG_NAME}.log"
readonly TRACE_FILE="${LOG_DIR}/${LOG_NAME}.trc"
# set up execution trace
export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
exec {BASH_XTRACEFD}>>"${TRACE_FILE}"
set -x
# steer stdout/stderr to the log file
exec &>> >(tee -a "${LOG_FILE}")

echo "DATE: " $DATE &>> $DIR/INFO
# Detect if running inside a container (CPU and MEMORY should be set)
if [[ -n "$CPUS" && -n "$MEMORY" ]]; then
    # Running inside a container
    export CPUS="$CPUS"
    export MEM="$MEMORY"
else
    export CPUS=$(lscpu | grep "^CPU(s):" | awk '{print $2}')
    export MEM=$(free -g | awk '/^Mem:/ {print $2}')
fi
# if [[ -z "$GROUP" ]]; then
# 	GPUS=$(nvidia-smi -L | wc -l 2>/dev/null || echo "none")
# 	GPUMODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader | uniq || echo "None")
# fi
## log it into INFO File
echo "ENV:" $ENV  &>> $DIR/INFO
echo "REGION:" $REGION &>> $DIR/INFO
echo "CLUSTER:" $CLUSTER &>> $DIR/INFO
echo "APPNAME:" $APPNAME &>> $DIR/INFO
echo "ASG:" $ASG &>> $DIR/INFO
echo "INSTANCE:" $INSTANCE&>> $DIR/INFO
echo "BASEOS:" $BASEOS &>> $DIR/INFO
echo "KERNEL:" $KERNEL &>> $DIR/INFO
echo "JVM:" $JVM &>> $DIR/INFO
echo "JAVA_HOME:" $JAVA_HOME &>> $DIR/INFO
echo "RESULTS:" $DIR >> $DIR/INFO
echo "GC:" $GC &>> $DIR/INFO
echo "Heap:" $Heap &>> $DIR/INFO
echo "EC2_LOCAL_IPV4:" $EC2_LOCAL_IPV4 &>> $DIR/INFO
echo "EC2_INSTANCE_ID:" $EC2_INSTANCE_ID &>> $DIR/INFO
echo "EC2_INSTANCE_TYPE:" $EC2_INSTANCE_TYPE &>> $DIR/INFO
echo "DETECTED_INSTANCE_TYPE:" $INSTANCE_TYPE &>> $DIR/INFO
echo "EC2_ACCOUNT_ID:" $EC2_ACCOUNT_ID &>> $DIR/INFO
echo "EC2_ROLE:" $EC2_ROLE &>> $DIR/INFO
echo "DISTRIB_RELEASE:" $DISTRIB_RELEASE &>> $DIR/INFO
echo "DISTRIB_DESCRIPTION:" $DISTRIB_DESCRIPTION &>> $DIR/INFO
echo "DISTRIB_CODENAME:" $DISTRIB_CODENAME &>> $DIR/INFO
echo "LAB_LOCATION:" $LAB_LOCATION &>> $DIR/INFO
echo "CPUS:" $CPUS &>> $DIR/INFO
echo "GPUS:" $GPUS &>> $DIR/INFO
echo "MEM:" $MEM &>> $DIR/INFO
echo "GPUMODEL:" $GPUMODEL &>> $DIR/INFO

echo "................................benchmark environment setup complete.............................."
