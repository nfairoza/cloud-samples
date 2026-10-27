# cloud-samples

A collection of code samples, demos, and exercises created during cloud training sessions with focus on compute. This repository is designed to serve as a resource for learning and exploring cloud technologies, including hands-on examples for AWS, Azure, GCP, and more.

## Start here

**[`cloud-setup/`](cloud-setup/)** — install and configure the CLI for AWS, Azure, GCP, or OCI. Most other folders assume the relevant CLI is already installed and authenticated.

> Moved: the former `awscli-setup/` now lives at [`cloud-setup/aws/`](cloud-setup/aws/).

## Multi-cloud

| Folder | What it does |
|--------|--------------|
| [`cloud-setup/`](cloud-setup/) | CLI install + auth for AWS, Azure, GCP, OCI |
| [`cca-export/`](cca-export/) | Export running compute inventory into the Cloud Cost Assessment template |
| [`proof-of-performance/`](proof-of-performance/) | Pull billing/usage data for proof-of-performance reporting |
| [`amd-iam-policies/`](amd-iam-policies/) | Governance policies that block Intel launches where an AMD EPYC equivalent exists |

## AWS

| Folder | What it does |
|--------|--------------|
| [`ec2-cli-samples/`](ec2-cli-samples/) | EC2 commands to run once the CLI is up |
| [`aws-perfspect/`](aws-perfspect/) | PerfSpect runs on AMD and Intel instances |
| [`aws-turbostat/`](aws-turbostat/) | turbostat collection via CloudFormation |
| [`eks-ccd-aware-pod-placement/`](eks-ccd-aware-pod-placement/) | CCD-aware pod placement on EKS |
| [`EKS-ccd-extras/`](EKS-ccd-extras/) | CCD labeller and supporting manifests |
| [`marketplace-amd-checker/`](marketplace-amd-checker/) | Check Marketplace AMIs for AMD support |
| [`idle-autostop/`](idle-autostop/) | Stop idle instances |

## Benchmarking and analysis

| Folder | What it does |
|--------|--------------|
| [`avx512-check/`](avx512-check/) | AVX-512 detection and DGEMM perf analysis |
| [`buildfarm-benchmark/`](buildfarm-benchmark/) | Build farm benchmark harness |
| [`nf-benchmark-test/`](nf-benchmark-test/) | Containerised benchmark runs with an HTML report |
| [`eia-data/`](eia-data/) | EIA energy data pull |
| [`ice/`](ice/) | ICE notes |
