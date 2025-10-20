#!/bin/bash
#
# A script to definitively verify Kubernetes CPU pinning on all cluster nodes.
# It uses a temporary, privileged DaemonSet and provides a detailed, pod-by-pod report.

# 1. Define the privileged inspector DaemonSet
cat <<EOF > inspector-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cpu-inspector-ds
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: cpu-inspector
  template:
    metadata:
      labels:
        name: cpu-inspector
    spec:
      tolerations:
      - operator: Exists
      hostPID: true
      containers:
      - name: inspector
        image: ubuntu:22.04
        securityContext:
          privileged: true
        command: ["/bin/sh", "-c", "sleep infinity"]
EOF

# 2. Deploy the inspector pods
echo "Deploying temporary inspector pods to each node..."
kubectl delete -f inspector-daemonset.yaml --ignore-not-found=true > /dev/null 2>&1
kubectl apply -f inspector-daemonset.yaml > /dev/null 2>&1

echo "Waiting for inspectors to be ready..."
if ! kubectl rollout status daemonset/cpu-inspector-ds -n kube-system --timeout=90s > /dev/null 2>&1; then
    echo "FATAL ERROR: Inspector pods could not be deployed. Check cluster permissions."
    kubectl delete -f inspector-daemonset.yaml --ignore-not-found=true > /dev/null 2>&1
    exit 1
fi
echo "  - Inspectors are ready."

echo -e "\nStarting CPU Placement Verification..."
echo "====================================================="

# 3. Get all worker nodes
NODES=$(kubectl get nodes --selector='!node-role.kubernetes.io/master,!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}')

# 4. Loop through each node
for NODE in $NODES; do
    echo -e "\nChecking Node: $NODE"

    INSPECTOR_POD=$(kubectl get pods -n kube-system -l name=cpu-inspector --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')

    if [ -z "$INSPECTOR_POD" ]; then
        echo "  - Could not find inspector pod on this node."
        continue
    fi

    # Create a map of container IDs to pod names
    declare -A POD_MAP
    POD_INFO=$(kubectl get pods -o jsonpath="{range .items[?(@.spec.nodeName=='$NODE')]}{.metadata.name}{' '}{.status.containerStatuses[0].containerID}{'\n'}{end}" | grep 'sysbench')

    while read -r name id; do
        id_prefix=$(echo "$id" | sed 's/containerd:\/\///' | cut -c1-12)
        POD_MAP["$id_prefix"]="$name"
    done <<< "$POD_INFO"

    # Use a robust for-loop inside the inspector to gather data
    CGROUP_DATA=$(kubectl exec -n kube-system $INSPECTOR_POD -- bash -c '
        for f in $(find /sys/fs/cgroup -name "cpuset.cpus"); do
            echo "$f:$(cat $f 2>/dev/null)";
        done
    ')

    # Get the parent CPU set that all pods are likely inheriting
    PARENT_CPU_SET=$(echo "$CGROUP_DATA" | grep '/sys/fs/cgroup/kubepods.slice/cpuset.cpus:' | head -n 1 | awk -F: '{print $2}' | sed 's/ //g')
    echo "  Parent Shared Pool (kubepods.slice): $PARENT_CPU_SET"

    # 5. Process data and provide a clear, interpreted report
    HAS_PINNED_PODS_ON_NODE=false
    while IFS=: read -r path cores; do
        if [[ $path =~ cri-containerd-([a-f0-9]{12}) ]]; then
            id_prefix="${BASH_REMATCH[1]}"
            pod_name=${POD_MAP[$id_prefix]}
            if [ -n "$pod_name" ]; then
                if [ -z "$cores" ]; then
                    printf "  -> Pod: %-45s Cores: (Inherited from shared pool - %s)\n" "$pod_name" "$PARENT_CPU_SET"
                else
                    printf "  -> Pod: %-45s Cores: %s\n" "$pod_name" "$cores"
                    HAS_PINNED_PODS_ON_NODE=true
                fi
                unset POD_MAP[$id_prefix]
            fi
        fi
    done <<< "$CGROUP_DATA"

    if ! $HAS_PINNED_PODS_ON_NODE; then
        echo "  - No exclusively pinned pods found on this node."
    fi
done

# 6. Final cleanup
echo -e "\nCleaning up temporary inspector pods..."
kubectl delete -f inspector-daemonset.yaml --ignore-not-found=true > /dev/null 2>&1
rm inspector-daemonset.yaml
echo "  - Cleanup complete."

echo -e "\n====================================================="
echo "Verification Complete."
