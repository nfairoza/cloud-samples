#!/bin/bash

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -k, --key           AWS Access Key ID (optional, must be paired with -sk)"
    echo "  -sk, --secret-key   AWS Secret Access Key (optional, must be paired with -k)"
    echo "  -r, --region        AWS Region (optional)"
    echo "  -h, --help          Display this help message and exit"
    exit 1
}

install_aws_cli() {
    echo "Installing AWS CLI..."

    . /etc/os-release
    arch=$(uname -m)

    case "$ID" in
        ubuntu|debian)
            sudo apt update && sudo apt upgrade -y
            sudo apt install -y unzip
            ;;
        centos|rhel|almalinux|rocky|amazon)
            sudo yum update -y
            sudo yum install -y unzip
            ;;
        sles|opensuse-leap)
            sudo zypper refresh && sudo zypper update -y
            sudo zypper install -y unzip
            ;;
        *)
            echo "Unsupported Linux distribution: $ID."
            exit 1
            ;;
    esac

    if [[ "$arch" == "x86_64" ]]; then
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    elif [[ "$arch" == "aarch64" ]]; then
        curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
    else
        echo "Unsupported architecture: $arch"
        exit 1
    fi

    unzip awscliv2.zip
    sudo ./aws/install
    rm -rf awscliv2.zip aws
}


configure_aws_cli() {
    if [[ -n "$AWS_ACCESS_KEY_ID" || -n "$AWS_SECRET_ACCESS_KEY" ]]; then
        if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
            echo "Both Access Key (-k) and Secret Key (-sk) must be provided together."
            exit 1
        fi
        aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
        aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
    fi

    if [[ -n "$AWS_REGION" ]]; then
        aws configure set default.region "$AWS_REGION"
    fi
}


while [[ $# -gt 0 ]]; do
    case $1 in
        -k|--key) AWS_ACCESS_KEY_ID="$2"; shift 2 ;;
        -sk|--secret-key) AWS_SECRET_ACCESS_KEY="$2"; shift 2 ;;
        -r|--region) AWS_REGION="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

if ! aws --version &>/dev/null; then
    install_aws_cli
fi


if aws --version &>/dev/null; then
    echo "AWS CLI installed successfully. Version:"
    aws --version
else
    echo "AWS CLI installation failed."
    exit 1
fi

configure_aws_cli

if aws sts get-caller-identity &>/dev/null; then
    echo "AWS CLI configured successfully."
else
    echo "AWS CLI configuration skipped or credentials are invalid. If you are running this script in EC2 , you can alternatively check and configure IAM role"
fi
