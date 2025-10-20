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


kubectl get nodes


Phase 1:
kubectl get nodes
kubectl apply -f sysbench.yaml
kubectl get pods -o wide


The kubectl top node and kubectl top pod commands rely entirely on the Metrics Server, which aggregates resource usage data from the Kubelets on your nodes and exposes it through the Kubernetes API.

kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl get pods -n kube-system -l k8s-app=metrics-server


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
