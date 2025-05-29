#!/bin/bash

# AMD AMI Checker with actual dry-run testing
AMI_IDS=(
ami-08cb0d7bf45353c15
ami-095fb4798f212b43d
ami-032992defa47c7e3e
ami-00388e28f5449a5e8
ami-0c99a4f3fe0932780
ami-0f1b076df8a755560
ami-016a8bb026548df98
ami-07de004fed5e2ead5
ami-04b45b75cb3f33018
ami-0625e659c05832ea2
ami-07c25ebf78fe1be6d
ami-0dc90a31cd379790e
ami-0acaf92b2c6747e7c
ami-0afc16c7d6167aafd
ami-07bc7bb5a82635729
ami-02c17db5485462a5a
ami-0b01e5c53280743d7
ami-0a8f53ce33277c838
ami-053e1472db4543469
ami-02abade30d88b0604
ami-0f18fd8c62f761abb
ami-0d1c0a6eab45046f6
ami-09621fee4c29042cf
ami-0a41499ba28eab331
ami-017c6f2f7c566f029
ami-0d3acf683fd4ecca6
ami-0e9e3b561802b6a14
ami-0eac8fbd9d2ac8821
ami-0cbcd66e9174cd1dc
ami-06365f2065e261364
ami-03df4e2972619ba5e
ami-01ef9b450c9ff809d
ami-059c24ca6eacf04ab
ami-0f7e57dbb288064a0
ami-0009978d1bd17a476
ami-371bcd4a
ami-0a3deb1b96bba1838
ami-02216cff1ba0ca1b5
ami-098c5f62314bbaf55
ami-0e5796e37e288711f
ami-0a5a1c42210299be0
ami-0af49f660916c944f
ami-0cb96283933fde30d
ami-093103a0eb5f5a1bc
ami-04c4ecb2dc17dd704
ami-0fa1d7053155e4da4
ami-0fa0a33c195b8d5e9
ami-004ba284e8b033a4d
ami-05a7e1d12ac34eca1
ami-02b23d02efda0902c
ami-0ddce43696867fdaf
ami-0be1b3f2d0278bece
ami-0126156dd4f309211
ami-06124464cc14ea953
ami-0d0af8c68a01af002
ami-036013f25677a9838
ami-03d626dc2d940684b
ami-0bfbb31a7244cf759
ami-050ef6f9f459e550e
ami-0c5b72e22e89b7e13
ami-0da483bd775112ccb
ami-049a2a028bf744f8f
ami-0758c101aa6c00bc9
ami-07a56fc77cf8fa082
ami-064995bcca3c5ed1f
ami-06f42191c84ea3b34
ami-0d270e243edd75027
ami-0576f65ede1ad9132
ami-06c198bd4df424a55
ami-01de95a9f03cb240c
ami-07da8a49a7e3c7039
ami-09a2300c61f4693a3
ami-00b6d6b7c268c0d0c
ami-0a41e99f0114f6a26
ami-0d125aec0be6a5d9a
ami-05dc5706a9a577689
ami-0ed12f814324f12c2
ami-03ea322030fb1bc89
ami-0e75c12341bfb93e8
ami-00bd79bb1f170b1cc
ami-037bc01fb4513b88e
ami-04064cccbefe2d845
ami-085386e29e44dacd7
ami-0edf4a7e3058418ad
ami-0b86aaed8ef90e45f
ami-05f08ad7b78afd8cd
ami-0fb5d26f4afaa83d4
ami-06e8615e0b6d8e40a
ami-0468ac5f57c53fbad
ami-03371cac683b5dd6d
ami-01ebfcc6612a5261e
)

REGIONS=("us-east-1" "us-east-2" "us-west-1" "us-west-2" "ca-central-1" "ca-west-1"
"eu-central-1" "eu-central-2" "eu-west-1" "eu-west-2" "eu-west-3" "eu-north-1" "eu-south-1" "eu-south-2"
"ap-east-1" "ap-south-1" "ap-south-2" "ap-southeast-1" "ap-southeast-2" "ap-southeast-3" "ap-southeast-4"
"ap-northeast-1" "ap-northeast-2" "ap-northeast-3" "af-south-1" "me-central-1" "me-south-1" "sa-east-1" "il-central-1")


AMD_INSTANCES=(
    # M5a instances
    "m5a.large" "m5a.xlarge" "m5a.2xlarge" "m5a.4xlarge" "m5a.8xlarge" "m5a.12xlarge" "m5a.16xlarge" "m5a.24xlarge"
    # M5ad instances
    "m5ad.large" "m5ad.xlarge" "m5ad.2xlarge" "m5ad.4xlarge" "m5ad.8xlarge" "m5ad.12xlarge" "m5ad.16xlarge" "m5ad.24xlarge"
    # M6a instances
    "m6a.large" "m6a.xlarge" "m6a.2xlarge" "m6a.4xlarge" "m6a.8xlarge" "m6a.12xlarge" "m6a.16xlarge" "m6a.24xlarge" "m6a.32xlarge" "m6a.48xlarge"
    # M7a instances
    "m7a.medium" "m7a.large" "m7a.xlarge" "m7a.2xlarge" "m7a.4xlarge" "m7a.8xlarge" "m7a.12xlarge" "m7a.16xlarge" "m7a.24xlarge" "m7a.32xlarge" "m7a.48xlarge"
    # C5a instances
    "c5a.large" "c5a.xlarge" "c5a.2xlarge" "c5a.4xlarge" "c5a.8xlarge" "c5a.12xlarge" "c5a.16xlarge" "c5a.24xlarge"
    # C5ad instances
    "c5ad.large" "c5ad.xlarge" "c5ad.2xlarge" "c5ad.4xlarge" "c5ad.8xlarge" "c5ad.12xlarge" "c5ad.16xlarge" "c5ad.24xlarge"
    # C6a instances
    "c6a.large" "c6a.xlarge" "c6a.2xlarge" "c6a.4xlarge" "c6a.8xlarge" "c6a.12xlarge" "c6a.16xlarge" "c6a.24xlarge" "c6a.32xlarge" "c6a.48xlarge"
    # C7a instances
    "c7a.medium" "c7a.large" "c7a.xlarge" "c7a.2xlarge" "c7a.4xlarge" "c7a.8xlarge" "c7a.12xlarge" "c7a.16xlarge" "c7a.24xlarge" "c7a.32xlarge" "c7a.48xlarge"
    # R5a instances
    "r5a.large" "r5a.xlarge" "r5a.2xlarge" "r5a.4xlarge" "r5a.8xlarge" "r5a.12xlarge" "r5a.16xlarge" "r5a.24xlarge"
    # R5ad instances
    "r5ad.large" "r5ad.xlarge" "r5ad.2xlarge" "r5ad.4xlarge" "r5ad.8xlarge" "r5ad.12xlarge" "r5ad.16xlarge" "r5ad.24xlarge"
    # R6a instances
    "r6a.large" "r6a.xlarge" "r6a.2xlarge" "r6a.4xlarge" "r6a.8xlarge" "r6a.12xlarge" "r6a.16xlarge" "r6a.24xlarge" "r6a.32xlarge" "r6a.48xlarge"
    # R7a instances
    "r7a.medium" "r7a.large" "r7a.xlarge" "r7a.2xlarge" "r7a.4xlarge" "r7a.8xlarge" "r7a.12xlarge" "r7a.16xlarge" "r7a.24xlarge" "r7a.32xlarge" "r7a.48xlarge"
    # T3a instances
    "t3a.nano" "t3a.micro" "t3a.small" "t3a.medium" "t3a.large" "t3a.xlarge" "t3a.2xlarge"
    # T4a instances
    "t4a.nano" "t4a.micro" "t4a.small" "t4a.medium" "t4a.large" "t4a.xlarge" "t4a.2xlarge"
    # HPC instances
    "hpc6a.large" "hpc6a.xlarge" "hpc6a.2xlarge" "hpc6a.4xlarge" "hpc6a.8xlarge" "hpc6a.12xlarge" "hpc6a.16xlarge" "hpc6a.24xlarge" "hpc6a.32xlarge" "hpc6a.48xlarge"
    "hpc7a.large" "hpc7a.xlarge" "hpc7a.2xlarge" "hpc7a.4xlarge" "hpc7a.8xlarge" "hpc7a.12xlarge" "hpc7a.16xlarge" "hpc7a.24xlarge" "hpc7a.32xlarge" "hpc7a.48xlarge"
    # G4ad instances
    "g4ad.xlarge" "g4ad.2xlarge" "g4ad.4xlarge" "g4ad.8xlarge" "g4ad.16xlarge"
)

COMPATIBLE_FILE="amd_compatible_amis.csv"
INCOMPATIBLE_FILE="incompatible_amis.csv"

echo "AMI_ID,Region,Architecture,Platform,Owner,Name,Compatible_Instance_Types" > "$COMPATIBLE_FILE"
echo "AMI_ID,Region,Platform,Owner,Name,Error_Message" > "$INCOMPATIBLE_FILE"

echo "Checking AMIs with dry-run tests..."

for ami_id in "${AMI_IDS[@]}"; do
    echo "Checking $ami_id..."
    found=false

    for region in "${REGIONS[@]}"; do
        # Check if AMI exists and get details
        result=$(aws ec2 describe-images --region "$region" --image-ids "$ami_id" \
            --query 'Images[0].[Architecture,State,PlatformDetails,ImageOwnerAlias,Name]' --output text 2>/dev/null)

        if [ $? -eq 0 ] && [ -n "$result" ] && [ "$result" != "None" ]; then
            IFS=$'\t' read -r arch state platform owner_alias name <<< "$result"

            if [ "$state" = "available" ]; then
                found=true
                echo "  Found in $region, architecture: $arch, platform: $platform, owner: $owner_alias"

                if [ "$arch" = "x86_64" ]; then
                    # Test each AMD instance type with dry-run
                    compatible_instances=()

                    for instance_type in "${AMD_INSTANCES[@]}"; do
                        echo -n "    Testing $instance_type... "

                        # Dry-run test - success returns exit code 0
                        error_output=$(aws ec2 run-instances \
                            --region "$region" \
                            --image-id "$ami_id" \
                            --instance-type "$instance_type" \
                            --dry-run 2>&1)

                        exit_code=$?

                        # Check if dry-run succeeded (exit code 0 and contains "DryRunOperation")
                        if [ $exit_code -eq 0 ] || echo "$error_output" | grep -q "DryRunOperation"; then
                            echo "✓"
                            compatible_instances+=("$instance_type")
                        else
                            echo "✗"
                        fi
                    done

                    # Save results
                    if [ ${#compatible_instances[@]} -gt 0 ]; then
                        compatible_list=$(IFS=';'; echo "${compatible_instances[*]}")
                        echo "$ami_id,$region,$arch,$platform,$owner_alias,\"$name\",$compatible_list" >> "$COMPATIBLE_FILE"
                        echo "  Compatible with: $compatible_list in $region"
                    else
                        echo "$ami_id,$region,$platform,$owner_alias,\"$name\",No AMD instances compatible (marketplace restrictions)" >> "$INCOMPATIBLE_FILE"
                        echo "  No AMD instances compatible in $region"
                    fi
                else
                    echo "$ami_id,$region,$platform,$owner_alias,\"$name\",Architecture $arch not AMD compatible" >> "$INCOMPATIBLE_FILE"
                    echo "  Architecture $arch not compatible in $region"
                fi
                break
            fi
        fi
    done

    if [ "$found" = false ]; then
        echo "$ami_id,none,unknown,unknown,unknown,AMI not found in any region" >> "$INCOMPATIBLE_FILE"
        echo "  Not found in any region"
    fi
    echo
done

echo "Results:"
echo "- AMD compatible: $COMPATIBLE_FILE"
echo "- Incompatible: $INCOMPATIBLE_FILE"
