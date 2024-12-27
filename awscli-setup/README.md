# AWS CLI Setup and Configuration Script

This repository contains a Bash script designed to install and configure the AWS Command Line Interface (CLI) on a Linux workstation or EC2 instance. It also optionally configures aws credentials with secret key and secret access key.
## Usage

- `-k, --key`: AWS Access Key ID (optional, must be paired with `-sk`).
- `-sk, --secret-key`: AWS Secret Access Key (optional, must be paired with `-k`).
- `-r, --region`: AWS Region (optional).
- `-h, --help`: Display help message and exit.

### Example
```
./script.sh -k YOUR_ACCESS_KEY -sk YOUR_SECRET_KEY -r us-east-1
```
