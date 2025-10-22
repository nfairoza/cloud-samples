Test EKSCluster

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


The kubectl top node and kubectl top pod commands rely entirely on the Metrics Server, which aggregates resource usage data from the Kubelets on your nodes and exposes it through the Kubernetes API.

kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl get pods -n kube-system -l k8s-app=metrics-server
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
