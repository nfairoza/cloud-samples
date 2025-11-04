# Kubernetes on AMD EPYC: CCD-Aware Pod Placement - Hands-On Guide

This guide walks you through a hands-on experiment demonstrating how CPU Manager policies affect pod placement on AMD EPYC processors in Amazon EKS.

## What You'll Learn

You'll see how different Kubernetes CPU Manager configurations impact how pods are placed across Core Complex Dies (CCDs) on AMD EPYC processors. We'll progress through three configurations:

1. **Default Policy (none)** - Uncontrolled placement with pod threads potentially spread across multiple CCDs
2. **Static Policy** - CPU pinning with sequential allocation (may still cross CCD boundaries)
3. **Static Policy with Uncore Cache Alignment** - CCD-aware placement keeping pods within L3 cache domains

## Prerequisites

- AWS CLI configured with appropriate credentials
- An AWS account with permissions to create EKS clusters and EC2 instances

## Architecture

- **Cluster**: Amazon EKS v1.34
- **Worker Nodes**: 2x M7a.12xlarge instances (AMD EPYC "Genoa")
- **CPU Configuration**: 48 vCPUs per node, 6 CCDs, 8 cores per CCD
- **Workload**: Sysbench CPU benchmark with Guaranteed QoS pods

---

## Phase 1: Default CPU Manager Policy (none)

### Step 1: Deploy the EKS Cluster

Create the cluster with the default CPU Manager policy:

```bash
aws cloudformation create-stack \
  --stack-name my-eks-stack \
  --template-body file://test-setup-cfn-selfmanaged.yaml \
  --capabilities CAPABILITY_IAM \
  --region us-east-2
```

Wait for the stack to complete (takes ~15 minutes):

```bash
aws cloudformation wait stack-create-complete \
  --stack-name my-eks-stack \
  --region us-east-2
```

### Step 2: Configure kubectl

```bash
aws eks update-kubeconfig --name my-eks-cluster --region us-east-2
```

Verify nodes are ready:

```bash
kubectl get nodes
```

Expected output:
```
NAME                                       STATUS   ROLE    AGE   VERSION
ip-10-0-1-xxx.us-east-2.compute.internal   Ready    <none>  5m    v1.34.x
ip-10-0-2-xxx.us-east-2.compute.internal   Ready    <none>  5m    v1.34.x
```

### Step 3: Deploy Default Workload (4 CPUs per pod)

Deploy 10 Sysbench pods with 4 CPU cores each:

```bash
kubectl apply -f sysbench-default-48.yaml
```

Watch pod placement:

```bash
kubectl get pods -o wide
```

### Step 4: Inspect CPU Assignments

Run the placement verification script:

```bash
./eks-check-pod-placement.sh
```

**What to observe**: With the default policy, pods share CPUs dynamically. Threads can migrate between cores, and there's no guaranteed locality to any specific CCD. Performance will be variable.

### Step 5: Clean Up Phase 1

```bash
kubectl delete deployment sysbench-default
kubectl get pods  # Verify all pods are deleted
```

---

## Phase 2: Static CPU Manager Policy

### Step 1: Update the Cluster Configuration

First, delete the existing stack:

```bash
aws cloudformation delete-stack \
  --stack-name my-eks-stack \
  --region us-east-2
```

Wait for deletion to complete (~10 minutes):

```bash
aws cloudformation wait stack-delete-complete \
  --stack-name my-eks-stack \
  --region us-east-2
```

Edit `test-setup-cfn-selfmanaged.yaml` and ensure the kubelet configuration has:

```yaml
kubelet:
  config:
    cpuManagerPolicy: static
    cpuManagerReconcilePeriod: 10s
    systemReserved:
      cpu: "4"
    kubeReserved:
      cpu: "0"
```

Create the new stack:

```bash
aws cloudformation create-stack \
  --stack-name my-eks-stack \
  --template-body file://test-setup-cfn-selfmanaged.yaml \
  --capabilities CAPABILITY_IAM \
  --region us-east-2
```

Wait for completion:

```bash
aws cloudformation wait stack-create-complete \
  --stack-name my-eks-stack \
  --region us-east-2
```

### Step 2: Configure kubectl

```bash
aws eks update-kubeconfig --name my-eks-cluster --region us-east-2
kubectl get nodes
```

### Step 3: Verify Static CPU Manager

Verify the CPU Manager is configured correctly:

```bash
kubectl debug node/$(kubectl get nodes --no-headers | awk 'NR==1{print $1}') --image=ubuntu -- chroot /host cat /var/lib/kubelet/config.yaml | grep -A2 cpuManager
```

Expected output:
```
cpuManagerPolicy: static
cpuManagerReconcilePeriod: 10s
```

### Step 4: Deploy Workload with 4 CPUs per Pod

```bash
kubectl apply -f sysbench-default-48.yaml
kubectl get pods -o wide
```

### Step 5: Inspect CPU Pinning

```bash
./eks-check-pod-placement.sh
```

**What to observe**: Each pod now gets exclusive, pinned cores (e.g., 4-7, 8-11, 12-15). The allocation is sequential but may cross CCD boundaries. For example, a pod assigned cores 4-7 might span part of CCD0 and part of CCD1.

### Step 6: Experiment with 6 CPUs per Pod

Clean up the 4-CPU deployment:

```bash
kubectl delete deployment sysbench-default
```

Edit `sysbench-default-48.yaml` and change CPU requests/limits to `"6"`:

```yaml
resources:
  limits:
    cpu: "6"
    memory: "1Gi"
  requests:
    cpu: "6"
    memory: "1Gi"
```

Deploy and inspect:

```bash
kubectl apply -f sysbench-default-48.yaml
kubectl get pods -o wide
./eks-check-pod-placement.sh
```

**What to observe**: With 6-CPU pods, the boundary-crossing becomes more evident. Pods with cores like 4-9 or 10-15 definitely span multiple CCDs since each CCD only has 8 cores.

Clean up:

```bash
kubectl delete deployment sysbench-default
```

---

## Phase 3: Static Policy with Uncore Cache Alignment

### Step 1: Update to Include Uncore Cache Option

Delete the existing stack:

```bash
aws cloudformation delete-stack \
  --stack-name my-eks-stack \
  --region us-east-2

aws cloudformation wait stack-delete-complete \
  --stack-name my-eks-stack \
  --region us-east-2
```

Edit `test-setup-cfn-selfmanaged.yaml` and update the kubelet configuration:

```yaml
kubelet:
  config:
    cpuManagerPolicy: static
    cpuManagerReconcilePeriod: 10s
    cpuManagerPolicyOptions:
      prefer-align-cpus-by-uncorecache: "true"
    systemReserved:
      cpu: "4"
    kubeReserved:
      cpu: "0"
```

Create the stack with the new configuration:

```bash
aws cloudformation create-stack \
  --stack-name my-eks-stack \
  --template-body file://test-setup-cfn-selfmanaged.yaml \
  --capabilities CAPABILITY_IAM \
  --region us-east-2

aws cloudformation wait stack-create-complete \
  --stack-name my-eks-stack \
  --region us-east-2
```

### Step 2: Configure kubectl and Verify

```bash
aws eks update-kubeconfig --name my-eks-cluster --region us-east-2
kubectl get nodes
```

Verify the uncore cache option is enabled:

```bash
kubectl debug node/$(kubectl get nodes --no-headers | awk 'NR==1{print $1}') --image=ubuntu -- chroot /host cat /var/lib/kubelet/config.yaml | grep -A3 cpuManagerPolicyOptions
```


### Step 3: Deploy 6-CPU Workload

Edit `sysbench-default-48.yaml` to use 6 CPUs per pod, then deploy:

```bash
kubectl apply -f sysbench-default-48.yaml
kubectl get pods -o wide
```

### Step 4: Inspect CCD-Aware Placement

```bash
./eks-check-pod-placement.sh
```

**What to observe**: The allocation pattern changes! Instead of sequential (4-7, 8-11...), the kubelet now jumps to clean CCD boundaries (e.g., 8-13, 16-21, 24-29). Each 6-CPU pod stays primarily within one L3 cache domain.

### Step 5: Test with 4-CPU Pods (Perfect Fit)

Clean up and switch to 4 CPUs per pod:

```bash
kubectl delete deployment sysbench-default
```

Edit `sysbench-default-48.yaml` back to 4 CPUs:

```yaml
resources:
  limits:
    cpu: "4"
    memory: "1Gi"
  requests:
    cpu: "4"
    memory: "1Gi"
```

Deploy and inspect:

```bash
kubectl apply -f sysbench-default-48.yaml
kubectl get pods -o wide
./eks-check-pod-placement.sh
```

**What to observe**: With 4-CPU pods (exactly half a CCD), each pod fits perfectly within a single CCD. You should see clean allocations that respect L3 cache boundaries, maximizing locality and cache efficiency.

---

## Verification: Check L3 Cache Topology

To understand the CCD structure of your nodes, run:

```bash
kubectl debug node/$(kubectl get nodes --no-headers | awk 'NR==1{print $1}') -it --image=ubuntu -- bash -c "
  echo 'CPU -> L3 Cache ID mapping:'
  for cpu in /host/sys/devices/system/cpu/cpu[0-9]*; do
    cpunum=\$(basename \$cpu | sed 's/cpu//')
    if [ -f \$cpu/cache/index3/id ]; then
      l3id=\$(cat \$cpu/cache/index3/id)
      echo \"CPU \$cpunum -> L3 Cache \$l3id\"
    fi
  done | sort -t' ' -k2 -n
"
```

This shows which CPUs share the same L3 cache (CCD).

---

## Key Takeaways

1. **Default Policy**: Offers no CPU affinity or cache awareness. Suitable only for non-performance-critical workloads.

2. **Static Policy**: Provides CPU pinning and eliminates thread migration, but allocates cores sequentially without regard for CCD boundaries.

3. **Static + Uncore Cache Alignment**: The optimal configuration for AMD EPYC. Keeps pod threads within the same L3 cache domain, minimizing cross-chiplet latency and maximizing cache efficiency.

## Clean Up

When you're done experimenting:

```bash
kubectl delete deployment sysbench-default

aws cloudformation delete-stack \
  --stack-name my-eks-stack \
  --region us-east-2
```

---

## Next Steps

This guide demonstrated CPU Manager configuration and its impact on pod placement. For production workloads on AMD EPYC instances, we recommend:

- Always enable **static CPU Manager policy**
- Use **prefer-align-cpus-by-uncorecache=true** for CCD-aware placement
- Request CPU sizes that fit cleanly within CCD boundaries (4 or 8 cores for m7a.12xlarge)
- Use **Guaranteed QoS** for performance-critical workloads

For more advanced CCD-aware scheduling with even distribution across all CCDs before packing, consider implementing an NRI plugin to expose CCD topology to the scheduler.
