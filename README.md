# ECS Deploy - AWS Copilot Replacement

A simplified ECS deployment framework using reusable CloudFormation templates and a bash deploy script.

## Architecture

```
Admin (one-time setup)          Developer (ongoing)
─────────────────────           ───────────────────
app-init                        svc-deploy (new service)
  └─ IAM roles, KMS, S3        svc-deploy (update existing service)
env-init                        secret-init (store secrets)
  └─ ECS Cluster, Internal
     ALB, Security Groups
add-repo
  └─ ECR repo per service
```

## Folder Structure

```
ecs-deploy/
├── templates/
│   ├── app-infrastructure.yml   # Admin: IAM roles, KMS, S3
│   ├── ecr-repository.yml       # Admin: ECR repo per service
│   ├── environment.yml          # Admin: ECS cluster, ALB, SGs
│   └── service.yml              # Dev: ECS service, task def, TG, listener rules
├── scripts/
│   └── deploy.sh                # CLI wrapper
├── config/
│   └── manifest.yml             # Example manifest (developers copy this)
└── README.md
```

## Admin Commands (one-time)

```bash
# 1. Initialize app infrastructure
./deploy.sh app-init --app myapp --department IT

# 2. Create environment
./deploy.sh env-init --app myapp --env uat --department IT \
  --vpc-id vpc-0abc123def456789 \
  --private-subnets subnet-0abc123,subnet-0def456 \
  --cert-arn arn:aws:acm:ap-south-1:123456789012:certificate/abcd-1234-efgh-5678

# 3. Create ECR repo for a service
./deploy.sh add-repo --app myapp --service order-service --department IT
```

## Developer Commands

```bash
# Deploy a new service or update existing
./deploy.sh svc-deploy --config manifest.yml --env uat

# Deploy with a specific image tag
./deploy.sh svc-deploy --config manifest.yml --env uat --tag v1.2.3

# Store a secret
./deploy.sh secret-init --app myapp --env uat --name DB_PASSWORD --value "mypassword" --department IT
```

## Service Manifest (manifest.yml)

Developers create this file in their project root. See `config/manifest.yml` for a full example.

## SSM Secrets Path Convention

```
/{app}/{env}/secrets/{SECRET_NAME}
```

Example: `/myapp/uat/secrets/DB_PASSWORD`

## Tags

All resources are tagged with:
- `app` - Application name
- `environment` - Environment name (where applicable)
- `service` - Service name (where applicable)
- `Department` - Department name (e.g., IT)
