#!/bin/bash
#
#   Benchmark Environment Variables
#   --------------------------------
#
MODEL_NAME=$(lscpu | grep "Model name" | awk -F': ' '{print $2}')
CORES_PER_SOCKET=$(lscpu | grep "Core(s) per socket" | awk '{print $4}')
SOCKETS=$(lscpu | grep "Socket(s)" | awk '{print $2}')
TOTAL_CORES=$((CORES_PER_SOCKET * SOCKETS))
export VCPUS=$((TOTAL_CORES * 2))  # Assuming hyperthreading is enabled

if [[ -z "$INSTANCE_SIZE" ]]; then
    #INSTANCE_SIZE=$((TOTAL_CORES / 2))  # Match AWS convention (half of physical cores)
    INSTANCE_SIZE="metal-$((TOTAL_CORES / 2))xl"  # Match AWS convention (half of physical cores)
fi

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

case "${INSTANCE_SIZE}" in
    xlarge) INSTANCE_TYPE="xlarge" ;;
    2xlarge) INSTANCE_TYPE="2xlarge" ;;
    4xlarge) INSTANCE_TYPE="4xlarge" ;;
    8xlarge) INSTANCE_TYPE="8xlarge" ;;
    12xlarge) INSTANCE_TYPE="12xlarge" ;;
    16xlarge) INSTANCE_TYPE="16xlarge" ;;
    24xlarge) INSTANCE_TYPE="24xlarge" ;;
    32xlarge) INSTANCE_TYPE="32xlarge" ;;
    metal-48xl) INSTANCE_TYPE="metal48xl" ;;
    *) INSTANCE_TYPE="unknown" ;;
esac

# Export the final instance type
export EC2_INSTANCE_TYPE="${FAMILY}-${INSTANCE_TYPE}"
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
GPUS=$(nvidia-smi -L | wc -l 2>/dev/null || echo "none")
MEM=$(free -g | awk '/^Mem:/ {print $2}')
GPUMODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader | uniq || echo "None")
#-------
export DATE=$(date '+%m-%d-%Y_%H-%M')
export TS=`echo $(date '+%m-%d-%Y_%s')`

# We need m7i.metal-48xl to be m7i-metal48xl
UNAME=`uname -r`
KERNEL=`echo $UNAME|sed -e 's/\.//g'`
BASEOS=$(grep "VERSION_CODENAME" /etc/os-release | cut -d '=' -f2)
#JVM=`java -version 2>&1|grep Server|sed 's/(//g'| sed 's/)//g'|awk '{print $5$6}'|cut -d . -f 1`
export JVM="OpenJDK$(java --version | awk 'NR==1 {print $2}' | cut -d. -f1)"
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))
#-------
# Garbage collectors: SerialGC,ParallelGC,G1GC,ZGC,ShenandoahGC,
# Change GC environment variable here to run specjbb2015 with different Garbage Collector: ex: export GC='ShenandoahGC"
#-------
export GC='G1GC'
# C6 and C7 instances have less memory to allocate in Heap
if [[ $EC2_INSTANCE_TYPE =~ "c6i.xlarge" ]] || [[ $EC2_INSTANCE_TYPE =~ "c6a.xlarge" ]]; then
  export Heap='2g'
elif [[ $EC2_INSTANCE_TYPE =~ "c6i.2xlarge" ]] || [[ $EC2_INSTANCE_TYPE =~ "c6a.2xlarge" ]]; then
  export Heap='4g'
elif [[ $EC2_INSTANCE_TYPE =~ "c6i.4xlarge" ]] || [[ $EC2_INSTANCE_TYPE =~ "c6a.4xlarge" ]]; then
  export Heap='4g'
elif [[ $EC2_INSTANCE_TYPE =~ "c6i.8xlarge" ]] || [[ $EC2_INSTANCE_TYPE =~ "c6a.8xlarge" ]]; then
  export Heap='16g'
elif [[ $EC2_INSTANCE_TYPE =~ "c6i.12xlarge" ]] || [[ $EC2_INSTANCE_TYPE =~ "c6a.12xlarge" ]]; then
  export Heap='32g'
elif [[ $EC2_INSTANCE_TYPE =~ "c6i.16xlarge" ]] || [[ $EC2_INSTANCE_TYPE =~ "c6a.16xlarge" ]]; then
  export Heap='32g'
elif [[ $EC2_INSTANCE_TYPE =~ "c6i.24xlarge" ]] || [[ $EC2_INSTANCE_TYPE =~ "c6a.24xlarge" ]]; then
  export Heap='32g'
elif [[ $EC2_INSTANCE_TYPE =~ "c6i.32xlarge" ]] || [[ $EC2_INSTANCE_TYPE =~ "c6a.32xlarge" ]]; then
  export Heap='64g'
elif [[ $EC2_INSTANCE_TYPE =~ "c6i.metal" ]] || [[ $EC2_INSTANCE_TYPE =~ "c6a.metal" ]]; then
  export Heap='64g'
# C7 instances
elif [[ $EC2_INSTANCE_TYPE =~ "c7i.xlarge" ]] || [[ $EC2_INSTANCE_TYPE =~ "c7a.xlarge" ]]; then
  export Heap='2g'
elif [[ $EC2_INSTANCE_TYPE =~ "c7i.2xlarge" ]] || [[ $EC2_INSTANCE_TYPE =~ "c7a.2xlarge" ]]; then
  export Heap='4g'
elif [[ $EC2_INSTANCE_TYPE =~ "c7i.4xlarge" ]] || [[ $EC2_INSTANCE_TYPE =~ "c7a.4xlarge" ]]; then
  export Heap='4g'
elif [[ $EC2_INSTANCE_TYPE =~ "c7i.8xlarge" ]] || [[ $EC2_INSTANCE_TYPE =~ "c7a.8xlarge" ]]; then
  export Heap='16g'
elif [[ $EC2_INSTANCE_TYPE =~ "c7i.12xlarge" ]] || [[ $EC2_INSTANCE_TYPE =~ "c7a.12xlarge" ]]; then
  export Heap='32g'
elif [[ $EC2_INSTANCE_TYPE =~ "c7i.16xlarge" ]] || [[ $EC2_INSTANCE_TYPE =~ "c7a.16xlarge" ]]; then
  export Heap='32g'
elif [[ $EC2_INSTANCE_TYPE =~ "c7i.24xlarge" ]] || [[ $EC2_INSTANCE_TYPE =~ "c7a.24xlarge" ]]; then
  export Heap='64g'
elif [[ $EC2_INSTANCE_TYPE =~ "c7i.metal-24xl" ]] || [[ $EC2_INSTANCE_TYPE =~ "c7a.24xlarge" ]]; then
  export Heap='64g'
elif [[ $EC2_INSTANCE_TYPE =~ "c7i.48xlarge" ]] || [[ $EC2_INSTANCE_TYPE =~ "c7a.48xlarge" ]]; then
  export Heap='96g'
elif [[ $EC2_INSTANCE_TYPE =~ "c7i.metal" ]] || [[ $EC2_INSTANCE_TYPE =~ "c7a.metal" ]]; then
  export Heap='96g'
elif [[ $EC2_INSTANCE_TYPE =~ "c7i.metal-48xl" ]] || [[ $EC2_INSTANCE_TYPE =~ "c7a.metal-48xl" ]]; then
  export Heap='96g'
# Other type of instances
elif [[ $EC2_INSTANCE_TYPE =~ "medium" ]]; then
  export Heap='250m'
elif [[ $EC2_INSTANCE_TYPE =~ "large" ]]; then
  export Heap='2g'
elif [[ $EC2_INSTANCE_TYPE =~ "xlarge" ]]; then
  export Heap='4g'
elif [[ $EC2_INSTANCE_TYPE =~ "2xlarge" ]]; then
  export Heap='8g'
elif [[ $EC2_INSTANCE_TYPE =~ "4xlarge" ]]; then
  export Heap='16g'
elif [[ $EC2_INSTANCE_TYPE =~ "8xlarge" ]]; then
  export Heap='32g'
elif [[ $EC2_INSTANCE_TYPE =~ "12xlarge" ]]; then
  export Heap='64g'
elif [[ $EC2_INSTANCE_TYPE =~ "16xlarge" ]]; then
  export Heap='64g'
elif [[ $EC2_INSTANCE_TYPE =~ "24xlarge" ]]; then
  export Heap='96g'
elif [[ $EC2_INSTANCE_TYPE =~ "32xlarge" ]]; then
  export Heap='96g'
elif [[ $EC2_INSTANCE_TYPE =~ "metal" ]]; then
  export Heap='128g'
fi

# If GROUP is set, use it for results directory
if [[ -n "$GROUP" ]]; then
    RESULTS="/efs/html/AUTOBENCH/LAB_RESULTS/$GROUP"
else
    RESULTS="/efs/html/AUTOBENCH/LAB_RESULTS"
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
# Genoa-metal48xl
#EC2_INSTANCE_TYPE="${FAMILY}-metal${INSTANCE_SIZE}xl"
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
# Detect if running inside a container (CPU and MEMORY should be set)
if [[ -n "$CPUS" && -n "$MEMORY" ]]; then
    # Running inside a container
    export CPUS="$CPUS"
    export MEM="$MEMORY"
else
    export CPUS=$(lscpu | grep "^CPU(s):" | awk '{print $2}')
    export MEM=$(free -g | awk '/^Mem:/ {print $2}')
fi
if [[ -z "$GROUP" ]]; then
	GPUS=$(nvidia-smi -L | wc -l 2>/dev/null || echo "none")
	GPUMODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader | uniq || echo "None")
fi
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
