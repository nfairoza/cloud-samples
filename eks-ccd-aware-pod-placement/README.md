Test EKSCluster

aws cloudformation create-stack \
  --stack-name my-eks-stack \
  --template-body file://test-setup-cfn.yaml \
  --capabilities CAPABILITY_IAM \
  --region us-east-2


This command configures your local kubectl tool to communicate with your EKS cluster.
Updates your kubeconfig file (usually at ~/.kube/config)
Adds authentication settings that use your AWS credentials to authenticate with the cluster

`aws eks update-kubeconfig --name my-eks-cluster --region us-east-2`


aws eks delete-cluster \
     --name my-eks-cluster \
     --region us-east-2
