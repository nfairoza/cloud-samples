# AWS PerfSpect

This repository contains scripts for running Intel's PerfSpect tool on AWS EC2 instances and zipping and  uploading results to S3.


## Intel- Perfspect
I ran intel perfspect https://github.com/intel/PerfSpect/tree/main on M7i instance
Instead of building from source (git clone), we use pre-built binaries from Intel's releases since that's the recommended path for users.

## Usage Instructions

1. Create an EC2 instance with appropriate IAM role for S3 access

2. Download the script:
Intel PerfSpect
```bash
sudo rm aws-intel-perfspect.sh
wget https://raw.githubusercontent.com/nfairoza/cloud-samples/refs/heads/main/aws-perfspect/aws-intel-perfspect.sh
sudo chmod +x aws-intel-perfspect.sh
./aws-intel-perfspect.sh
```

AMD PerfSpect
```bash
sudo rm ./aws-amd-perfspect.sh
wget https://raw.githubusercontent.com/nfairoza/cloud-samples/refs/heads/main/aws-perfspect/aws-amd-perfspect.sh
sudo chmod +x aws-amd-perfspect.sh
sudo ./aws-amd-perfspect.sh
```

## Notes
#### Symbolic link
You can create a symbolic link from within perfspect folder so you dont need to use ./
 ```bash
 sudo ln -s $(pwd)/perfspect /usr/local/bin/perfspect
 ```
#### Create presigined URL  (7 days)

 ```bash
 aws s3 presign --expires-in 604800 s3://noortestdata/perfspect/m7itests/i-02ec9004ed347dd3d/perfspect_results.tar.gz 
```
#### Run Stress ng
I have used M7i 24 xl, thus stressing 96 vCpu

```bash
sudo apt-get update
sudo apt-get install stress-ng
stress-ng --cpu 96 --timeout 120s
stress-ng --cpu $(nproc) --cpu-load 100 --timeout 300s
```
#### Pull amd fork
``` bash
aws s3 cp s3://noortestdata/perfspect/perfspect-amd.tgz .
tar xvzf perfspect-amd.tgz
cd perfspect
```

#### New Instance setup / user data
```bash
sudo apt update && sudo apt upgrade -y
sudo apt-get install unzip
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
sudo apt-get install zip stress-ng -y
aws --version
sudo apt install python3-pip -y
sudo apt install build-essential python3-dev -y
sudo apt install python3-full python3-venv -y
```

#### Build and run perfspect on Ec2
```bash
aws s3 cp s3://noortestdata/perfspect/perfspect-amd.tgz .
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
pip install black flake8
export PATH=$PATH:$HOME/.local/bin
black perf-postprocess.py
make
cd build
```
#### AMDPerfspect pre-built

```bash
aws s3 cp s3://noortestdata/perfspect/AMDPerfSpect.zip .
unzip AMDPerfSpect.zip
cd AMDPerfSpect/python_amd_updated/perfspect/build
sudo chmod +x perf-collect perf-postprocess
```
