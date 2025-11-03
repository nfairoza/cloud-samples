Test EKSCluster
.....................

# 1. Delete the current workload
kubectl delete deployment sysbench-ccd-aware

# 2. Delete the CCD labeler (we'll redeploy it later)
kubectl delete daemonset -n node-feature-discovery nfd-ccd-labeller

# 3. Delete the current CloudFormation stack
aws cloudformation delete-stack \
  --stack-name my-eks-stack \
  --region us-east-2

# 4. Wait for deletion to complete (this takes ~10 minutes)
aws cloudformation wait stack-delete-complete \
  --stack-name my-eks-stack \
  --region us-east-2

# 5. Create the new stack with Topology Manager enabled
aws cloudformation create-stack \
  --stack-name my-eks-stack \
  --template-body file://test-setup-cfn-selfmanaged.yaml \
  --capabilities CAPABILITY_IAM \
  --region us-east-2

# 6. Wait for creation to complete (takes ~15 minutes)
aws cloudformation wait stack-create-complete \
  --stack-name my-eks-stack \
  --region us-east-2

# 7. Configure kubectl
aws eks update-kubeconfig --name my-eks-cluster --region us-east-2

# 8. Verify nodes are ready
kubectl get nodes

# 9. Verify Topology Manager is configured
NODE_NAME=$(kubectl get nodes --no-headers | awk 'NR==1{print $1}')
kubectl debug node/$NODE_NAME --image=ubuntu -- chroot /host cat /var/lib/kubelet/config.yaml | grep -A2 topologyManager

# 10. Redeploy the CCD labeler
kubectl apply -f ccd-labeller-kubectl.yaml

# 11. Wait for labeler to complete
kubectl logs -n node-feature-discovery -l app=nfd-ccd-labeller -f

# 12. Verify CCD labels
kubectl get nodes -o json | jq '.items[].metadata.labels | with_entries(select(.key|match("custom.io/ccd-group"))) | keys'

# 13. Deploy the workload
kubectl apply -f sysbench-ccd-aware.yaml

# 14. Watch pod placement
kubectl get pods -o wide -w

# 15. Check CPU pinning and CCD placement
./eks-check-pod-placement.sh

.....................
aws cloudformation create-stack \
  --stack-name my-eks-stack \
  --template-body file://test-setup-cfn.yaml \
  --capabilities CAPABILITY_IAM \
  --region us-east-2

  aws cloudformation update-stack \
      --stack-name my-eks-stack \
      --template-body file://test-setup-cfn.yaml \
      --capabilities CAPABILITY_IAM \
      --region us-east-2

      aws eks update-nodegroup-version \
        --cluster-name my-eks-cluster \
        --nodegroup-name my-eks-cluster-nodegroup \
        --launch-template-name my-eks-cluster-al2023-template \
        --launch-template-version <LATEST_VERSION_NUMBER> \
        --force \
        --region us-east-2




This command configures your local kubectl tool to communicate with your EKS cluster.
Updates your kubeconfig file (usually at ~/.kube/config)
Adds authentication settings that use your AWS credentials to authenticate with the cluster

`aws eks update-kubeconfig --name my-eks-cluster --region us-east-2`


aws eks delete-cluster \
     --name my-eks-cluster \
     --region us-east-2

ami-03290691a4d2c6df9

kubectl get nodes

kubectl get configmap aws-auth -n kube-system

aws ec2 get-console-output \
  --instance-id i-05a6ba81246f7d004 \
  --region us-east-2 \
  --output text | tail -200


Phase 1:
kubectl get nodes
kubectl apply -f sysbench-default-48.yaml
kubectl get pods -o wide

kubectl delete deployment sysbench-default
kubectl get pods

................

Phase 2

# 1. Create/Update the CloudFormation stack
aws cloudformation create-stack \
  --stack-name my-eks-stack \
  --template-body file://test-setup-cfn-selfmanaged.yaml \
  --capabilities CAPABILITY_IAM \
  --region us-east-2

# Wait for completion
aws cloudformation wait stack-create-complete \
  --stack-name my-eks-stack \
  --region us-east-2

# 2. Configure kubectl
aws eks update-kubeconfig --name my-eks-cluster --region us-east-2

# 3. Deploy the CPU Manager configurator DaemonSet
kubectl apply -f cpu-manager-configurator.yaml

# 4. Watch it configure all nodes
kubectl logs -n system-config -l app=cpu-manager-configurator -f

# Check DaemonSet status
kubectl get daemonset -n system-config

# Check that pods ran successfully on all nodes
kubectl get pods -n system-config -o wide

# Verify CPU Manager is active
NODE_NAME=$(kubectl get nodes --no-headers | awk 'NR==1{print $1}')
kubectl debug node/$NODE_NAME --image=ubuntu -- chroot /host cat /var/lib/kubelet/cpu_manager_state


# Delete the old DaemonSet
kubectl delete daemonset cpu-manager-configurator -n system-config

# Apply the fixed version
kubectl apply -f cpu-manager-configurator.yaml

# Watch it work
kubectl logs -n system-config -l app=cpu-manager-configurator -c configure-cpu-manager -f



# Check YOUR cluster's service CIDR
aws eks describe-cluster \
  --name my-eks-cluster \
  --region us-east-2 \
  --query 'cluster.kubernetesNetworkConfig.serviceIpv4Cidr' \
  --output text
..................
Phase 3

--cpu-manager-policy-options=prefer-align-cpus-by-uncorecache=true

...........

phase 4

kubectl delete daemonset -n node-feature-discovery nfd-ccd-labeller

# Apply the corrected version (same filename)
kubectl apply -f ccd-labeller-kubectl.yaml

# Watch logs to see proper detection
kubectl logs -n node-feature-discovery -l app=nfd-ccd-labeller -f

# Should show only 6 labels per node (0-5)
kubectl get nodes -o json | jq '.items[].metadata.labels | with_entries(select(.key|match("custom.io/ccd-group"))) | keys'

NODE_A=$(kubectl get nodes --no-headers | awk 'NR==1{print $1}')
echo "--- Checking Node Labels on $NODE_A ---"
kubectl get node $NODE_A --show-labels | grep ccd-id

...
clean bad Labels

NODE_A=$(kubectl get nodes --no-headers | awk 'NR==1{print $1}')
NODE_B=$(kubectl get nodes --no-headers | awk 'NR==2{print $1}')

# Delete ALL custom.io/ccd-group labels from both nodes
kubectl label node $NODE_A $NODE_B custom.io/ccd-group-0- custom.io/ccd-group-1- custom.io/ccd-group-2- custom.io/ccd-group-3- custom.io/ccd-group-4- custom.io/ccd-group-5- custom.io/ccd-group-6- custom.io/ccd-group-7- custom.io/ccd-group-8- custom.io/ccd-group-9- custom.io/ccd-group-10- custom.io/ccd-group-11- custom.io/ccd-group-12- custom.io/ccd-group-13- custom.io/ccd-group-14- custom.io/ccd-group-15- custom.io/ccd-group-16- custom.io/ccd-group-17- custom.io/ccd-group-18- custom.io/ccd-group-19- custom.io/ccd-group-20- custom.io/ccd-group-21- custom.io/ccd-group-22- custom.io/ccd-group-23- custom.io/ccd-group-24- custom.io/ccd-group-25- custom.io/ccd-group-26- custom.io/ccd-group-27- custom.io/ccd-group-28- custom.io/ccd-group-29- custom.io/ccd-group-30- custom.io/ccd-group-31- custom.io/ccd-group-32- custom.io/ccd-group-33- custom.io/ccd-group-34- custom.io/ccd-group-35- custom.io/ccd-group-36- custom.io/ccd-group-37- custom.io/ccd-group-38- custom.io/ccd-group-39- custom.io/ccd-group-40- custom.io/ccd-group-41- custom.io/ccd-group-42- custom.io/ccd-group-43- custom.io/ccd-group-44- custom.io/ccd-group-45- custom.io/ccd-group-46- custom.io/ccd-group-47- custom.io/ccd-group-48- --overwrite

kubectl get nodes
kubectl apply -f sysbench-ccd-aware.yaml
kubectl get pods -o wide

kubectl delete deployment sysbench-ccd-aware
kubectl get pods
---------------

check l3 cache
NODE_NAME=$(kubectl get nodes --no-headers | awk 'NR==1{print $1}')
kubectl debug node/$NODE_NAME -it --image=ubuntu -- bash -c "
  echo 'CPU -> L3 Cache ID mapping:'
  for cpu in /host/sys/devices/system/cpu/cpu[0-9]*; do
    cpunum=\$(basename \$cpu | sed 's/cpu//')
    if [ -f \$cpu/cache/index3/id ]; then
      l3id=\$(cat \$cpu/cache/index3/id)
      echo \"CPU \$cpunum -> L3 Cache \$l3id\"
    fi
  done | sort -t' ' -k2 -n
"
.................
proof

NODE_NAME=$(kubectl get nodes --no-headers | awk 'NR==1{print $1}')

echo "Inspecting Pinned Cores on Node: $NODE_NAME"
# This command launches a privileged shell on the target node and runs the inspection script
kubectl debug node/$NODE_NAME -it --image=ubuntu --target=host \
-- bash -c "
  # Get ALL container IDs on the host running the sysbench-runner container
  # This crictl command must be run with sudo/host privileges
  IDS_TO_CHECK=\$(sudo crictl ps -q --label io.kubernetes.container.name=sysbench-runner)

  echo -e \"\n--- CPUSet Status (Phase 2: Static/Pinned Cores) ---\"

  for ID in \$IDS_TO_CHECK; do
    # Find the Cgroup path for the container
    CGROUP_PATH=\$(sudo crictl inspect --output go-template --template '{{.info.runtimeSpec.linux.cgroupsPath}}' \$ID)

    # Read the list of DEDICATED cores (cpuset.cpus)
    CORES=\$(sudo cat /sys/fs/cgroup/cpuset/\$CGROUP_PATH/cpuset.cpus)

    echo \"Container ID: \${ID:0:8}... -> Dedicated Cores: \$CORES\"
  done
  echo \"---------------------------------------------------\"
"
