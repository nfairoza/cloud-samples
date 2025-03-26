#!/bin/bash

# Define available AWS-like instance shapes with CPU & memory requirements
declare -A aws_shapes=(
    ["xlarge"]="4 16g" ["2xlarge"]="8 32g" ["4xlarge"]="16 64g" ["8xlarge"]="32 128g"
    ["12xlarge"]="48 192g" ["16xlarge"]="64 256g" ["24xlarge"]="96 384g"
    ["32xlarge"]="128 512g" ["metal-48xl"]="192 768g"
)

# Get total system resources
TOTAL_CPUS=$(nproc)  # Total available CPU cores
TOTAL_MEMORY=$(free -g | awk '/^Mem:/ {print $2}')  # Total memory in GB

# User-defined launch request (space-separated shapes, possibly with prefix counts)
ARGS=("$@")

if [ ${#ARGS[@]} -eq 0 ]; then
    echo "❌ ERROR: No instance shapes provided. Usage:"
    echo "   ./launch-containers-concurrent.sh xlarge 2xlarge 5.xlarge 2.8xlarge"
    exit 1
fi

# We'll keep track of all requests in an array of "count shape" pairs
declare -a requested_pairs=()
TOTAL_CONTAINERS=0

# Function to parse each argument into "count" and "shape"
parse_arg() {
    local arg="$1"
    # If argument matches "<number>.<shape>", capture both
    if [[ "$arg" =~ ^([0-9]+)\.(.+)$ ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    else
        # No numeric prefix, so default count = 1, shape = entire arg
        echo "1 $arg"
    fi
}

# Parse all CLI arguments into pairs of (count, shape)
for arg in "${ARGS[@]}"; do
    read -r count shape <<< "$(parse_arg "$arg")"
    requested_pairs+=("$count $shape")
    TOTAL_CONTAINERS=$((TOTAL_CONTAINERS + count))
done

# Only build a GROUP name if total containers > 1
if [[ $TOTAL_CONTAINERS -gt 1 ]]; then
    # Build something like "10.xlarge_8.2xlarge_8xlarge"
    shapes_label=()
    for pair in "${requested_pairs[@]}"; do
        read -r cnt shp <<< "$pair"
        if [[ "$cnt" -eq 1 ]]; then
            # If the count is 1, just use the shape name itself
            shapes_label+=( "$shp" )
        else
            # Otherwise, combine them: e.g. "10.xlarge"
            shapes_label+=( "${cnt}.${shp}" )
        fi
    done

    # Join them with underscores, e.g. "10.xlarge_8.2xlarge_8xlarge"
    joined_label="$(IFS=_; echo "${shapes_label[*]}")"

    # Final GROUP name includes shapes info + date/time
    GROUP="GROUP-${joined_label}-$(date '+%Y-%m-%d_%H-%M-%S')"
    export GROUP
fi

# Calculate total resources required
REQUIRED_CPUS=0
REQUIRED_MEMORY=0

# Function to convert memory values (e.g., "16g" → "16")
convert_memory() {
    echo "$1" | sed 's/g//g'
}

# Validate shapes and sum up resource requirements
for pair in "${requested_pairs[@]}"; do
    read -r cnt shp <<< "$pair"

    # Check if the shape is valid
    if [[ -z "${aws_shapes[$shp]}" ]]; then
        echo "❌ ERROR: Invalid instance shape \"$shp\". Available shapes: ${!aws_shapes[@]}"
        exit 1
    fi

    read -r cpus memory <<< "${aws_shapes[$shp]}"
    REQUIRED_CPUS=$((REQUIRED_CPUS + cnt * cpus))
    REQUIRED_MEMORY=$((REQUIRED_MEMORY + cnt * $(convert_memory "$memory")))
done

# Check if requested resources exceed system limits
if (( REQUIRED_CPUS > TOTAL_CPUS )) || (( REQUIRED_MEMORY > TOTAL_MEMORY )); then
    echo "❌ ERROR: Requested resources exceed system limits!"
    echo "   - Requested: ${REQUIRED_CPUS} CPUs, ${REQUIRED_MEMORY}GB RAM"
    echo "   - Available: ${TOTAL_CPUS} CPUs, ${TOTAL_MEMORY}GB RAM"
    exit 1
fi

echo "✅ Sufficient resources available. Launching containers..."

# Launch all requested containers concurrently
for pair in "${requested_pairs[@]}"; do
    read -r cnt shp <<< "$pair"
    read -r cpus memory <<< "${aws_shapes[$shp]}"

    for ((i=1; i<=cnt; i++)); do
        echo "🚀 Launching $shp (#$i of $cnt) with $cpus CPUs and $memory RAM..."
        docker run -d --rm --cpus=$cpus --memory=$memory --name "benchmark-${shp}-$i" \
            --privileged \
            --cap-add=SYS_ADMIN \
            --cap-add=IPC_LOCK \
            --cap-add=PERFMON \
            -v /efs:/efs \
            -e INSTANCE_SIZE="$shp" \
            -e GROUP="$GROUP" \
            -e CPUS="$cpus" \
            -e MEMORY="${memory%g}" \
            benchmark-container &
        # A short sleep to reduce simultaneous load at container startup
        sleep 1
    done
done

wait  # Ensure all background jobs complete
echo "✅ All containers launched successfully."
