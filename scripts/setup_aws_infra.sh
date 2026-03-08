#!/bin/bash
# ============================================================
# UniEvent – AWS Infrastructure Setup (AWS CLI)
# CE 308/408 Cloud Computing – Assignment 1
# Prerequisites: AWS CLI v2 configured with admin credentials
# ============================================================

set -euo pipefail

REGION="us-east-1"
PROJECT="unievent"
BUCKET="${PROJECT}-media-bucket-$(date +%s)"   # unique suffix

echo "========================================"
echo "  UniEvent AWS Infrastructure Setup"
echo "========================================"

# ─────────────────────────────────────────────────────────────────
# 1. IAM ROLE FOR EC2
# ─────────────────────────────────────────────────────────────────
echo "[1/7] Creating IAM role..."

aws iam create-role \
  --role-name UniEventEC2Role \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{
      "Effect":"Allow",
      "Principal":{"Service":"ec2.amazonaws.com"},
      "Action":"sts:AssumeRole"
    }]
  }' --region "$REGION"

# S3 read/write for our bucket only
aws iam put-role-policy \
  --role-name UniEventEC2Role \
  --policy-name UniEventS3Policy \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Effect\":\"Allow\",
      \"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\",\"s3:ListBucket\"],
      \"Resource\":[\"arn:aws:s3:::${BUCKET}\",\"arn:aws:s3:::${BUCKET}/*\"]
    }]
  }"

# CloudWatch Logs
aws iam attach-role-policy \
  --role-name UniEventEC2Role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess

# Instance profile
aws iam create-instance-profile --instance-profile-name UniEventInstanceProfile
aws iam add-role-to-instance-profile \
  --instance-profile-name UniEventInstanceProfile \
  --role-name UniEventEC2Role

echo "  ✓ IAM role created"

# ─────────────────────────────────────────────────────────────────
# 2. VPC + SUBNETS + INTERNET GATEWAY + NAT GATEWAY
# ─────────────────────────────────────────────────────────────────
echo "[2/7] Creating VPC..."

VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --region "$REGION" \
  --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources "$VPC_ID" --tags Key=Name,Value=UniEvent-VPC

# Public subnets (ALB)
PUB_SUB_A=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" --cidr-block 10.0.1.0/24 \
  --availability-zone "${REGION}a" \
  --query 'Subnet.SubnetId' --output text)
PUB_SUB_B=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" --cidr-block 10.0.2.0/24 \
  --availability-zone "${REGION}b" \
  --query 'Subnet.SubnetId' --output text)

# Private subnets (EC2)
PRIV_SUB_A=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" --cidr-block 10.0.11.0/24 \
  --availability-zone "${REGION}a" \
  --query 'Subnet.SubnetId' --output text)
PRIV_SUB_B=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" --cidr-block 10.0.12.0/24 \
  --availability-zone "${REGION}b" \
  --query 'Subnet.SubnetId' --output text)

# Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

# NAT Gateway (for private → internet API calls)
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
NAT_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUB_SUB_A" \
  --allocation-id "$EIP_ALLOC" \
  --query 'NatGateway.NatGatewayId' --output text)
echo "  Waiting for NAT Gateway to be available..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID"

# Route tables
PUB_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"
aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_SUB_A"
aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB_SUB_B"

PRIV_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$PRIV_RT" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID"
aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_SUB_A"
aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV_SUB_B"

echo "  ✓ VPC, subnets, IGW, NAT created"

# ─────────────────────────────────────────────────────────────────
# 3. SECURITY GROUPS
# ─────────────────────────────────────────────────────────────────
echo "[3/7] Creating security groups..."

ALB_SG=$(aws ec2 create-security-group \
  --group-name UniEvent-ALB-SG \
  --description "UniEvent ALB Security Group" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" \
  --protocol tcp --port 80  --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" \
  --protocol tcp --port 443 --cidr 0.0.0.0/0

EC2_SG=$(aws ec2 create-security-group \
  --group-name UniEvent-EC2-SG \
  --description "UniEvent EC2 Security Group" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)
# Allow traffic ONLY from ALB SG
aws ec2 authorize-security-group-ingress --group-id "$EC2_SG" \
  --protocol tcp --port 80 --source-group "$ALB_SG"

echo "  ✓ Security groups created"

# ─────────────────────────────────────────────────────────────────
# 4. S3 BUCKET
# ─────────────────────────────────────────────────────────────────
echo "[4/7] Creating S3 bucket: $BUCKET"

aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION" 2>/dev/null || \
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"

# Block all public access
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Versioning
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

# Create folder structure
aws s3api put-object --bucket "$BUCKET" --key "media/"
aws s3api put-object --bucket "$BUCKET" --key "cache/"

echo "  ✓ S3 bucket created: $BUCKET"

# ─────────────────────────────────────────────────────────────────
# 5. EC2 LAUNCH TEMPLATE
# ─────────────────────────────────────────────────────────────────
echo "[5/7] Creating EC2 Launch Template..."

# Amazon Linux 2023 AMI (us-east-1) — update if region differs
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-*-x86_64" "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)

LT_ID=$(aws ec2 create-launch-template \
  --launch-template-name UniEvent-LT \
  --version-description "v1" \
  --launch-template-data "{
    \"ImageId\":\"${AMI_ID}\",
    \"InstanceType\":\"t3.micro\",
    \"IamInstanceProfile\":{\"Name\":\"UniEventInstanceProfile\"},
    \"SecurityGroupIds\":[\"${EC2_SG}\"],
    \"UserData\":\"$(base64 -w0 ../scripts/ec2_userdata.sh)\"
  }" \
  --query 'LaunchTemplate.LaunchTemplateId' --output text)

echo "  ✓ Launch Template created: $LT_ID"

# ─────────────────────────────────────────────────────────────────
# 6. APPLICATION LOAD BALANCER + TARGET GROUP
# ─────────────────────────────────────────────────────────────────
echo "[6/7] Creating ALB..."

ALB_ARN=$(aws elbv2 create-load-balancer \
  --name UniEvent-ALB \
  --subnets "$PUB_SUB_A" "$PUB_SUB_B" \
  --security-groups "$ALB_SG" \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

TG_ARN=$(aws elbv2 create-target-group \
  --name UniEvent-TG \
  --protocol HTTP --port 80 \
  --vpc-id "$VPC_ID" \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN"

echo "  ✓ ALB and Target Group created"

# ─────────────────────────────────────────────────────────────────
# 7. AUTO SCALING GROUP
# ─────────────────────────────────────────────────────────────────
echo "[7/7] Creating Auto Scaling Group..."

aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name UniEvent-ASG \
  --launch-template LaunchTemplateId="${LT_ID}",Version='$Latest' \
  --min-size 2 --max-size 4 --desired-capacity 2 \
  --vpc-zone-identifier "${PRIV_SUB_A},${PRIV_SUB_B}" \
  --target-group-arns "$TG_ARN" \
  --health-check-type ELB \
  --health-check-grace-period 120

aws autoscaling put-scaling-policy \
  --auto-scaling-group-name UniEvent-ASG \
  --policy-name UniEvent-CPU-ScaleOut \
  --policy-type TargetTrackingScaling \
  --target-tracking-configuration '{
    "PredefinedMetricSpecification":{"PredefinedMetricType":"ASGAverageCPUUtilization"},
    "TargetValue":60.0
  }'

echo ""
echo "========================================"
echo "  ✅ Infrastructure deployed!"
echo "========================================"
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)
echo "  S3 Bucket : $BUCKET"
echo "  ALB DNS   : http://${ALB_DNS}"
echo ""
echo "  Update S3_BUCKET_NAME in scripts/ec2_userdata.sh before re-running."
echo "========================================"
