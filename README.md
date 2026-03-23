# UniEvent — University Event Management System on AWS
### CE 308/408 Cloud Computing · Assignment 1 · GIKI
## 🌐 Live Demo
http://UniEvent-ALB-862031874.us-east-1.elb.amazonaws.com

> A production-grade, fault-tolerant web application deployed on AWS that automatically fetches university events from the **Ticketmaster Discovery API**, stores media in **Amazon S3**, and serves traffic through an **Application Load Balancer** across multiple **EC2 instances** in private subnets.

---

## Table of Contents
1. [Architecture Overview](#1-architecture-overview)
2. [AWS Services Used](#2-aws-services-used)
3. [External API: Ticketmaster](#3-external-api-ticketmaster)
4. [Project Structure](#4-project-structure)
5. [Prerequisites](#5-prerequisites)
6. [Step-by-Step Deployment Guide](#6-step-by-step-deployment-guide)
   - 6.1 [Clone the Repository](#61-clone-the-repository)
   - 6.2 [Configure Your API Key](#62-configure-your-api-key)
   - 6.3 [Create the S3 Bucket](#63-create-the-s3-bucket)
   - 6.4 [Set Up IAM Role](#64-set-up-iam-role)
   - 6.5 [Create the VPC](#65-create-the-vpc)
   - 6.6 [Configure Security Groups](#66-configure-security-groups)
   - 6.7 [Launch EC2 Instances](#67-launch-ec2-instances)
   - 6.8 [Set Up the Load Balancer](#68-set-up-the-load-balancer)
   - 6.9 [Configure Auto Scaling](#69-configure-auto-scaling)
   - 6.10 [Verify Deployment](#610-verify-deployment)
7. [Local Development](#7-local-development)
8. [Automated Setup Script](#8-automated-setup-script)
9. [Application Features](#9-application-features)
10. [Security Design](#10-security-design)
11. [Fault Tolerance Design](#11-fault-tolerance-design)
12. [Teardown](#12-teardown)

---

## 1. Architecture Overview

```
Internet Users
      │  HTTPS
      ▼
┌─────────────────────────────────────────────┐
│         Application Load Balancer           │  ← Public Subnet (AZ-A & AZ-B)
│         (internet-facing, port 80/443)      │
└────────────────┬────────────────────────────┘
                 │ HTTP :80
      ┌──────────┴──────────┐
      ▼                     ▼
┌──────────────┐    ┌──────────────┐           ← Private Subnet
│  EC2 AZ-A    │    │  EC2 AZ-B    │
│  Flask+Nginx │    │  Flask+Nginx │
│  t3.micro    │    │  t3.micro    │
│  IAM Role ✓  │    │  IAM Role ✓  │
└──────┬───────┘    └──────┬───────┘
       └─────────┬─────────┘
                 │ boto3 (IAM auth)
                 ▼
        ┌─────────────────┐
        │   Amazon S3     │
        │  media/  cache/ │
        └─────────────────┘
                 ▲
         NAT Gateway (outbound)
                 │
        Ticketmaster API
        (external, HTTPS)
```

**Key design decisions:**
- EC2 instances live in **private subnets** — they are never directly reachable from the internet.
- The ALB in **public subnets** is the only internet-facing component.
- A **NAT Gateway** allows EC2 instances to make outbound HTTPS calls (to Ticketmaster API) without being publicly exposed.
- Events are **cached in S3** so the app continues working even if the external API is unavailable.

---

## 2. AWS Services Used

| Service | Role in UniEvent |
|---------|-----------------|
| **IAM** | EC2 instance role with least-privilege S3 + CloudWatch permissions |
| **VPC** | Custom network with public/private subnets across 2 AZs |
| **EC2** | Application servers running Flask + Gunicorn + Nginx |
| **S3** | Stores event posters (`media/`) and API cache (`cache/events.json`) |
| **Elastic Load Balancing (ALB)** | Distributes traffic across healthy EC2 instances |
| **Auto Scaling Group** | Replaces failed instances; scales on CPU load |
| **NAT Gateway** | Private EC2 → outbound internet (Ticketmaster API) |
| **Security Groups** | Firewall: EC2 only accepts traffic from ALB SG |

---

## 3. External API: Ticketmaster

**API Chosen:** [Ticketmaster Discovery API v2](https://developer.ticketmaster.com/products-and-docs/apis/discovery-api/v2/)

**Justification:**
- Free tier available with a Developer API key (no credit card required)
- Returns structured JSON with: `name`, `dates.start.localDate`, `_embedded.venues`, `info`, `images[]`, `classifications[]`
- Supports filtering by classification (`education`, `conference`, `seminar`)
- Provides event images for richer UI display
- Widely used in production event platforms

**Sample API Response:**
```json
{
  "_embedded": {
    "events": [{
      "id": "Z7r9jZ1AdJ8uA",
      "name": "Tech Conference 2025",
      "dates": { "start": { "localDate": "2025-09-15", "localTime": "10:00:00" } },
      "_embedded": { "venues": [{ "name": "Convention Center", "city": { "name": "New York" } }] },
      "info": "Annual technology conference...",
      "images": [{ "url": "https://s1.ticketmaster.com/..." }]
    }]
  }
}
```

**Get your free API key:** https://developer-acct.ticketmaster.com/user/register

---

## 4. Project Structure

```
Assignment1_AWS_CE/
├── README.md                        ← This file
├── .gitignore
│
├── src/                             ← Application source code
│   ├── app.py                       ← Flask backend (main application)
│   ├── requirements.txt             ← Python dependencies
│   ├── templates/
│   │   └── index.html               ← Jinja2 HTML template
│   └── static/
│       ├── css/
│       │   └── style.css            ← Application stylesheet
│       ├── js/
│       │   └── main.js              ← Frontend JavaScript
│       └── images/
│           └── default_event.png    ← Fallback event image
│
├── infrastructure/
│   └── iam_ec2_policy.json          ← IAM policy document
│
├── scripts/
│   ├── ec2_userdata.sh              ← EC2 bootstrap (runs at instance launch)
│   └── setup_aws_infra.sh           ← Full AWS CLI setup automation
│
└── docs/
    └── architecture.md              ← Detailed architecture diagram
```

---

## 5. Prerequisites

Before starting, ensure you have:

- [ ] **AWS Account** with permissions to create VPC, EC2, S3, IAM, ELB resources
- [ ] **AWS CLI v2** installed and configured (`aws configure`)
- [ ] **Python 3.9+** (for local development)
- [ ] **Git** installed
- [ ] **Ticketmaster API key** (free at https://developer-acct.ticketmaster.com)

Verify AWS CLI is configured:
```bash
aws sts get-caller-identity
```

---

## 6. Step-by-Step Deployment Guide

### 6.1 Clone the Repository

```bash
git clone https://github.com/<YOUR_USERNAME>/Assignment1_AWS_CE.git
cd Assignment1_AWS_CE
```

---

### 6.2 Configure Your API Key

Open `scripts/ec2_userdata.sh` and replace the placeholder:
```bash
TICKETMASTER_API_KEY=YOUR_TICKETMASTER_API_KEY_HERE
```

Also update the GitHub URL in the same file:
```bash
git clone https://github.com/<YOUR_GITHUB_USERNAME>/Assignment1_AWS_CE.git unievent
```

---

### 6.3 Create the S3 Bucket

```bash
# Create the bucket (bucket names must be globally unique — add your student ID)
aws s3api create-bucket \
  --bucket unievent-media-bucket-<YOUR_STUDENT_ID> \
  --region us-east-1

# Block all public access (security best practice)
aws s3api put-public-access-block \
  --bucket unievent-media-bucket-<YOUR_STUDENT_ID> \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,\
    BlockPublicPolicy=true,RestrictPublicBuckets=true

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket unievent-media-bucket-<YOUR_STUDENT_ID> \
  --versioning-configuration Status=Enabled

# Create folder structure
aws s3api put-object --bucket unievent-media-bucket-<YOUR_STUDENT_ID> --key "media/"
aws s3api put-object --bucket unievent-media-bucket-<YOUR_STUDENT_ID> --key "cache/"
```

> Update `S3_BUCKET_NAME` in `scripts/ec2_userdata.sh` with your bucket name.

---

### 6.4 Set Up IAM Role

**Step 1 — Create the EC2 trust policy:**
```bash
aws iam create-role \
  --role-name UniEventEC2Role \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{
      "Effect":"Allow",
      "Principal":{"Service":"ec2.amazonaws.com"},
      "Action":"sts:AssumeRole"
    }]
  }'
```

**Step 2 — Attach the S3 policy** (update bucket name first in `infrastructure/iam_ec2_policy.json`):
```bash
aws iam put-role-policy \
  --role-name UniEventEC2Role \
  --policy-name UniEventS3Policy \
  --policy-document file://infrastructure/iam_ec2_policy.json
```

**Step 3 — Attach CloudWatch Logs policy:**
```bash
aws iam attach-role-policy \
  --role-name UniEventEC2Role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
```

**Step 4 — Create instance profile:**
```bash
aws iam create-instance-profile \
  --instance-profile-name UniEventInstanceProfile

aws iam add-role-to-instance-profile \
  --instance-profile-name UniEventInstanceProfile \
  --role-name UniEventEC2Role
```

---

### 6.5 Create the VPC

```bash
# Create VPC
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --query 'Vpc.VpcId' --output text)

aws ec2 create-tags --resources $VPC_ID \
  --tags Key=Name,Value=UniEvent-VPC

# Enable DNS hostnames
aws ec2 modify-vpc-attribute \
  --vpc-id $VPC_ID --enable-dns-hostnames

# Create Public Subnets (for ALB)
PUB_SUB_A=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 \
  --availability-zone us-east-1a \
  --query 'Subnet.SubnetId' --output text)

PUB_SUB_B=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 \
  --availability-zone us-east-1b \
  --query 'Subnet.SubnetId' --output text)

# Create Private Subnets (for EC2)
PRIV_SUB_A=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID --cidr-block 10.0.11.0/24 \
  --availability-zone us-east-1a \
  --query 'Subnet.SubnetId' --output text)

PRIV_SUB_B=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID --cidr-block 10.0.12.0/24 \
  --availability-zone us-east-1b \
  --query 'Subnet.SubnetId' --output text)

# Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway \
  --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

# NAT Gateway (allows private EC2 to reach Ticketmaster API)
EIP=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
NAT_ID=$(aws ec2 create-nat-gateway \
  --subnet-id $PUB_SUB_A --allocation-id $EIP \
  --query 'NatGateway.NatGatewayId' --output text)

echo "Waiting for NAT Gateway..."
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_ID

# Public route table → Internet Gateway
PUB_RT=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route \
  --route-table-id $PUB_RT \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id $PUB_SUB_A
aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id $PUB_SUB_B

# Private route table → NAT Gateway
PRIV_RT=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route \
  --route-table-id $PRIV_RT \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id $NAT_ID
aws ec2 associate-route-table --route-table-id $PRIV_RT --subnet-id $PRIV_SUB_A
aws ec2 associate-route-table --route-table-id $PRIV_RT --subnet-id $PRIV_SUB_B
```

---

### 6.6 Configure Security Groups

```bash
# ALB Security Group — accepts HTTP/HTTPS from the internet
ALB_SG=$(aws ec2 create-security-group \
  --group-name UniEvent-ALB-SG \
  --description "UniEvent ALB Security Group" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG --protocol tcp --port 80 --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG --protocol tcp --port 443 --cidr 0.0.0.0/0

# EC2 Security Group — ONLY accepts traffic from the ALB SG
EC2_SG=$(aws ec2 create-security-group \
  --group-name UniEvent-EC2-SG \
  --description "UniEvent EC2 Security Group" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

# Allow port 80 ONLY from the ALB security group
aws ec2 authorize-security-group-ingress \
  --group-id $EC2_SG \
  --protocol tcp --port 80 \
  --source-group $ALB_SG
```

> **Security note:** EC2 instances have **no SSH port (22) open**. Use AWS Systems Manager Session Manager for shell access.

---

### 6.7 Launch EC2 Instances

**Step 1 — Get the latest Amazon Linux 2023 AMI:**
```bash
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-*-x86_64" "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)
echo "AMI: $AMI_ID"
```

**Step 2 — Create a Launch Template:**
```bash
aws ec2 create-launch-template \
  --launch-template-name UniEvent-LT \
  --launch-template-data "{
    \"ImageId\":\"${AMI_ID}\",
    \"InstanceType\":\"t3.micro\",
    \"IamInstanceProfile\":{\"Name\":\"UniEventInstanceProfile\"},
    \"SecurityGroupIds\":[\"${EC2_SG}\"],
    \"UserData\":\"$(base64 -w0 scripts/ec2_userdata.sh)\"
  }"
```

The `ec2_userdata.sh` script automatically:
1. Installs Python, Nginx, Git
2. Clones this repository
3. Installs Python dependencies
4. Creates a `systemd` service for Gunicorn (4 workers)
5. Configures Nginx as a reverse proxy on port 80
6. Sets up a cron job to refresh events every 15 minutes

---

### 6.8 Set Up the Load Balancer

```bash
# Create Application Load Balancer in public subnets
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name UniEvent-ALB \
  --subnets $PUB_SUB_A $PUB_SUB_B \
  --security-groups $ALB_SG \
  --scheme internet-facing \
  --type application \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# Create Target Group
TG_ARN=$(aws elbv2 create-target-group \
  --name UniEvent-TG \
  --protocol HTTP --port 80 \
  --vpc-id $VPC_ID \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Create HTTP Listener
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN

# Get the public DNS name of your load balancer
aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text
```

---

### 6.9 Configure Auto Scaling

```bash
LT_ID=$(aws ec2 describe-launch-templates \
  --launch-template-names UniEvent-LT \
  --query 'LaunchTemplates[0].LaunchTemplateId' --output text)

# Create Auto Scaling Group
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name UniEvent-ASG \
  --launch-template LaunchTemplateId=${LT_ID},Version='$Latest' \
  --min-size 2 \
  --max-size 4 \
  --desired-capacity 2 \
  --vpc-zone-identifier "${PRIV_SUB_A},${PRIV_SUB_B}" \
  --target-group-arns $TG_ARN \
  --health-check-type ELB \
  --health-check-grace-period 120

# CPU-based scaling policy (scale out when CPU > 60%)
aws autoscaling put-scaling-policy \
  --auto-scaling-group-name UniEvent-ASG \
  --policy-name UniEvent-CPU-ScaleOut \
  --policy-type TargetTrackingScaling \
  --target-tracking-configuration '{
    "PredefinedMetricSpecification":{
      "PredefinedMetricType":"ASGAverageCPUUtilization"
    },
    "TargetValue":60.0
  }'
```

---

### 6.10 Verify Deployment

```bash
# 1. Check ALB DNS
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)
echo "App URL: http://$ALB_DNS"

# 2. Test health endpoint
curl http://$ALB_DNS/health

# 3. Test events API endpoint
curl http://$ALB_DNS/api/events

# 4. Check Auto Scaling Group
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names UniEvent-ASG \
  --query 'AutoScalingGroups[0].Instances[*].[InstanceId,HealthStatus,AvailabilityZone]' \
  --output table

# 5. Verify S3 cache after first event fetch
aws s3 ls s3://unievent-media-bucket-<YOUR_STUDENT_ID>/cache/
```

**Expected health response:**
```json
{"status": "healthy", "timestamp": "2025-09-15T10:30:00.000000"}
```

---

## 7. Local Development

Run the app locally without AWS (uses mock events):

```bash
# Clone repo
git clone https://github.com/<USERNAME>/Assignment1_AWS_CE.git
cd Assignment1_AWS_CE/src

# Create virtual environment
python3 -m venv venv
source venv/bin/activate     # Windows: venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt

# Set environment variables
export TICKETMASTER_API_KEY="your_key_here"
export S3_BUCKET_NAME="unievent-media-bucket"
export AWS_REGION="us-east-1"

# Run app
python app.py
# Open: http://localhost:5000
```

> Without valid AWS credentials, the app will use mock events and skip S3 operations gracefully.

---

## 8. Automated Setup Script

To deploy the entire infrastructure in one command:

```bash
# Make sure AWS CLI is configured and the repo is cloned
chmod +x scripts/setup_aws_infra.sh
./scripts/setup_aws_infra.sh
```

The script handles all steps in sections 6.3–6.9 automatically and prints the ALB DNS at the end.

> **Note:** NAT Gateways are billed hourly (~$0.045/hr). Run `scripts/teardown.sh` when done testing.

---

## 9. Application Features

| Feature | Implementation |
|---------|---------------|
| Live event fetching | `GET /api/events` → Ticketmaster API → normalized JSON |
| S3 event caching | `cache/events.json` written after every successful fetch |
| S3 media upload | `POST /api/upload` → boto3 → `media/<timestamp>_<filename>` |
| ELB health check | `GET /health` → returns `{"status":"healthy"}` |
| Fault tolerance | S3 cache served automatically if API is down |
| Periodic refresh | cron `*/15 * * * *` calls `/api/events` |
| Frontend refresh | "↻ Refresh" button calls `/api/events` and re-renders grid |
| Drag & drop upload | JavaScript `dragover`/`drop` handlers |

---

## 10. Security Design

| Concern | Mitigation |
|---------|-----------|
| EC2 exposed to internet | EC2 in private subnets; only ALB is public-facing |
| Over-privileged IAM | EC2 role limited to specific S3 bucket ARN + CloudWatch logs |
| S3 data exposure | `BlockPublicAcls=true`, no bucket policy granting public read |
| Secrets in code | API key injected via environment variable in userdata (not hardcoded) |
| SSH access | Port 22 not opened; use SSM Session Manager instead |
| XSS | Template escaping via Jinja2 `{{ }}` + JS `escHtml()` |

---

## 11. Fault Tolerance Design

```
Scenario: EC2 instance in AZ-A crashes
─────────────────────────────────────────────────────────
1. ALB detects health-check failure after 3 consecutive
   failed /health requests (90 seconds total).
2. ALB stops routing traffic to the failed instance.
3. All traffic goes to the healthy EC2 in AZ-B.
4. Auto Scaling Group detects instance count < desired (2).
5. A replacement EC2 is launched in AZ-A automatically.
6. Bootstrap script runs, app starts, health check passes.
7. ALB adds new instance back to rotation.
   Total recovery time: ~3–5 minutes. Zero data loss.

Scenario: Ticketmaster API is down
─────────────────────────────────────────────────────────
1. fetch_events_from_api() raises RequestException.
2. _load_events_from_s3() retrieves last cached events.json.
3. Users see cached events with no visible disruption.
```

---

## 12. Teardown

To avoid unexpected AWS charges, delete all resources:

```bash
# Delete Auto Scaling Group
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name UniEvent-ASG --force-delete

# Delete Load Balancer (get ARN first)
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN

# Delete Target Group
aws elbv2 delete-target-group --target-group-arn $TG_ARN

# Delete NAT Gateway
aws ec2 delete-nat-gateway --nat-gateway-id $NAT_ID

# Release Elastic IP
aws ec2 release-address --allocation-id $EIP

# Delete S3 bucket (must be empty first)
aws s3 rm s3://unievent-media-bucket-<STUDENT_ID>/ --recursive
aws s3api delete-bucket --bucket unievent-media-bucket-<STUDENT_ID>

# Delete Security Groups, Subnets, IGW, VPC (in order)
aws ec2 delete-security-group --group-id $EC2_SG
aws ec2 delete-security-group --group-id $ALB_SG
aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID
aws ec2 delete-subnet --subnet-id $PUB_SUB_A
aws ec2 delete-subnet --subnet-id $PUB_SUB_B
aws ec2 delete-subnet --subnet-id $PRIV_SUB_A
aws ec2 delete-subnet --subnet-id $PRIV_SUB_B
aws ec2 delete-vpc --vpc-id $VPC_ID

# Delete IAM resources
aws iam remove-role-from-instance-profile \
  --instance-profile-name UniEventInstanceProfile \
  --role-name UniEventEC2Role
aws iam delete-instance-profile \
  --instance-profile-name UniEventInstanceProfile
aws iam delete-role-policy \
  --role-name UniEventEC2Role --policy-name UniEventS3Policy
aws iam detach-role-policy \
  --role-name UniEventEC2Role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
aws iam delete-role --role-name UniEventEC2Role
```

---

## Author

**Student:** [Your Name]  
**Roll No:** [Your Roll Number]  
**Course:** CE 308/408 Cloud Computing  
**Institute:** Ghulam Ishaq Khan Institute of Engineering Sciences and Technology  
**Semester:** Fall 2025  

---

*Built with Flask · Deployed on AWS · Events powered by Ticketmaster Discovery API*
