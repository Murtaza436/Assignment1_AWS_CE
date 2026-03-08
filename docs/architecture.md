# UniEvent — AWS Architecture Diagram
# CE 308/408 Cloud Computing · Assignment 1 · GIKI

```
┌──────────────────────────────────────────────────────────────────┐
│                         AWS Cloud (us-east-1)                    │
│                                                                  │
│   ┌──────────────────────────────────────────────────────────┐   │
│   │                    Custom VPC (10.0.0.0/16)              │   │
│   │                                                          │   │
│   │  ╔═══════════════════════════════════════════════════╗   │   │
│   │  ║          Public Subnets                           ║   │   │
│   │  ║  ┌─────────────────────────────────────────────┐  ║   │   │
│   │  ║  │     Application Load Balancer (ALB)         │  ║   │   │
│   │  ║  │     Listens on :80  ·  Routes /health       │  ║   │   │
│   │  ║  └──────────────┬───────────────────────────────┘  ║   │   │
│   │  ║     AZ-A(10.0.1)│   AZ-B(10.0.2)                  ║   │   │
│   │  ║            NAT Gateway (EIP)                       ║   │   │
│   │  ╚═══════════════════════════════════════════════════╝   │   │
│   │                   │ (private routing)                    │   │
│   │  ╔════════════════╪══════════════════════════════════╗   │   │
│   │  ║          Private Subnets                          ║   │   │
│   │  ║  ┌─────────────┴─────────────────────────────┐   ║   │   │
│   │  ║  │          Auto Scaling Group                │   ║   │   │
│   │  ║  │  min=2  desired=2  max=4                   │   ║   │   │
│   │  ║  │                                            │   ║   │   │
│   │  ║  │   ┌────────────┐    ┌────────────┐         │   ║   │   │
│   │  ║  │   │ EC2 AZ-A   │    │ EC2 AZ-B   │         │   ║   │   │
│   │  ║  │   │ t3.micro   │    │ t3.micro   │         │   ║   │   │
│   │  ║  │   │ Flask+Nginx│    │ Flask+Nginx│         │   ║   │   │
│   │  ║  │   │ IAM Role ✓ │    │ IAM Role ✓ │         │   ║   │   │
│   │  ║  │   └──────┬─────┘    └──────┬─────┘         │   ║   │   │
│   │  ║  └──────────┼────────────────┼──────────────┘   ║   │   │
│   │  ╚═════════════╪════════════════╪══════════════════╝   │   │
│   │                └────────┬───────┘                      │   │
│   │                         │ boto3 (IAM role auth)         │   │
│   │  ┌──────────────────────▼──────────────────────────┐   │   │
│   │  │               Amazon S3 Bucket                  │   │   │
│   │  │  media/  ──── event posters & images            │   │   │
│   │  │  cache/  ──── events.json (API response)        │   │   │
│   │  │  Versioning: ON  ·  Public Access: BLOCKED      │   │   │
│   │  └──────────────────────────────────────────────────┘   │   │
│   └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
                          ▲                   ▲
                          │                   │
                  Students / Users    Ticketmaster API
                  (HTTPS via ALB)     (outbound via NAT)
```

## IAM Permission Boundary

| Principal        | Service  | Permissions                              |
|------------------|----------|------------------------------------------|
| EC2 Instance     | S3       | GetObject, PutObject, ListBucket         |
| EC2 Instance     | CloudWatch| CreateLogGroup, PutLogEvents            |
| ALB              | EC2      | DescribeInstances (health check)         |
| Developer        | IAM      | Full (for initial setup only)            |

## Security Groups

| SG Name         | Inbound                    | Outbound        |
|-----------------|----------------------------|-----------------|
| UniEvent-ALB-SG | 0.0.0.0/0 :80, :443       | All             |
| UniEvent-EC2-SG | UniEvent-ALB-SG :80 only   | All (via NAT)   |
