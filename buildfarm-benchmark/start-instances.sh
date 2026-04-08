aws ec2 run-instances \
  --region us-east-2 \
  --image-id ami-0d6d5a1f326b57cb0 \
  --instance-type c7a.4xlarge \
  --key-name noor-ohio \
  --security-group-ids sg-089de5a03b3ec27f6 \
  --iam-instance-profile Name=testadmin \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=c7a.4xlarge-ea-benchmark}]' \
  --no-verify-ssl \
  --no-cli-pager \
  --count 1

  aws ec2 run-instances \
  --region us-east-2 \
  --image-id ami-0d6d5a1f326b57cb0 \
  --instance-type c8a.4xlarge \
  --key-name noor-ohio \
  --security-group-ids sg-089de5a03b3ec27f6 \
  --iam-instance-profile Name=testadmin \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=c8a.4xlarge-ea-benchmark}]' \
  --no-verify-ssl \
  --no-cli-pager \
  --count 1

  aws ec2 run-instances \
  --region us-east-2 \
  --image-id ami-0d6d5a1f326b57cb0 \
  --instance-type c7i.4xlarge \
  --key-name noor-ohio \
  --security-group-ids sg-089de5a03b3ec27f6 \
  --iam-instance-profile Name=testadmin \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=c7i.4xlarge-ea-benchmark}]' \
  --no-verify-ssl \
  --no-cli-pager \
  --count 1

  aws ec2 run-instances \
  --region us-east-2 \
  --image-id ami-0d6d5a1f326b57cb0 \
  --instance-type c8i.4xlarge \
  --key-name noor-ohio \
  --security-group-ids sg-089de5a03b3ec27f6 \
  --iam-instance-profile Name=testadmin \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=c8i.4xlarge-ea-benchmark}]' \
  --no-verify-ssl \
  --no-cli-pager \
  --count 1

  aws ec2 describe-instances \
  --region us-east-2 \
  --filters "Name=tag:Name,Values=*ea-benchmark*" "Name=instance-state-name,Values=pending,running" \
  --query "Reservations[].Instances[].[Tags[?Key=='Name'].Value|[0],InstanceType,InstanceId,State.Name]" \
  --output table \
  --no-cli-pager \
  --no-verify-ssl
