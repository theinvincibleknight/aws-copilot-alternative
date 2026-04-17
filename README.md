# ECS Deploy - AWS Copilot Replacement

A simplified ECS deployment framework using reusable CloudFormation templates and a bash deploy script.

## AWS Architecture Diagram

```mermaid
graph TB
    subgraph INTERNET["☁️ Internet"]
        USER["👤 End Users"]
    end

    subgraph AWS["AWS Account"]
        subgraph VPC["VPC (Existing)"]

            subgraph PUB_SUBNET["Public Subnets (Managed by Network Team)"]
                PUBLIC_ALB["🌐 Internet-Facing ALB<br/>(Managed by Network Team)"]
            end

            subgraph PRIV_SUBNET["Private Subnets"]
                INTERNAL_ALB["⚖️ Internal ALB<br/>(Created by env-init)<br/>HTTPS :443 + HTTP :80"]

                subgraph ECS_CLUSTER["ECS Cluster (Fargate)"]
                    subgraph SVC_A["Service A"]
                        TASK_A1["📦 Task<br/>App Container<br/>+ Datadog Sidecar<br/>+ Firelens Router"]
                    end
                    subgraph SVC_B["Service B"]
                        TASK_B1["📦 Task<br/>App Container"]
                    end
                    subgraph SVC_N["Service N..."]
                        TASK_N1["📦 Task"]
                    end
                end

                SD["🔍 Service Discovery<br/>(Cloud Map)<br/>*.uat.myapp.local"]
            end
        end

        ECR["📦 ECR<br/>(Container Registry)<br/>myapp/order-service"]
        SSM["🔐 SSM Parameter Store<br/>/myapp/uat/secrets/*"]
        CW["📊 CloudWatch Logs<br/>/myapp/uat/service-name"]
        KMS["🔑 KMS<br/>(Encryption Key)"]
        S3["🪣 S3<br/>(Artifacts Bucket)"]
        CFN["📋 CloudFormation<br/>(Stack Management)"]
        IAM["🛡️ IAM Roles<br/>Execution + Task + Deploy"]
        ACM["📜 ACM Certificate<br/>(HTTPS)"]
    end

    subgraph DEPLOY["🖥️ Deploy Machine"]
        SCRIPT["deploy.sh"]
        DOCKER["Docker Build"]
        MANIFEST["manifest.yml"]
    end

    USER -->|HTTPS| PUBLIC_ALB
    PUBLIC_ALB -->|Forward| INTERNAL_ALB
    INTERNAL_ALB -->|Path + Host<br/>Routing Rules| TASK_A1
    INTERNAL_ALB -->|Path + Host<br/>Routing Rules| TASK_B1
    INTERNAL_ALB -->|Path + Host<br/>Routing Rules| TASK_N1
    ACM -.->|TLS Cert| INTERNAL_ALB

    TASK_A1 <-->|DNS Lookup| SD
    TASK_B1 <-->|DNS Lookup| SD

    TASK_A1 -->|Logs| CW
    TASK_B1 -->|Logs| CW

    SCRIPT -->|1. Read Config| MANIFEST
    SCRIPT -->|2. Build Image| DOCKER
    DOCKER -->|3. Push Image| ECR
    SCRIPT -->|4. Deploy Stack| CFN
    CFN -->|Creates/Updates| ECS_CLUSTER
    CFN -->|Creates| INTERNAL_ALB

    ECR -.->|Pull Image| TASK_A1
    SSM -.->|Inject Secrets| TASK_A1
    KMS -.->|Decrypt| SSM
    IAM -.->|Permissions| TASK_A1

    style INTERNET fill:#e1f5fe,stroke:#0288d1
    style AWS fill:#fff3e0,stroke:#f57c00
    style VPC fill:#e8f5e9,stroke:#388e3c
    style PUB_SUBNET fill:#fff9c4,stroke:#f9a825
    style PRIV_SUBNET fill:#e8f5e9,stroke:#66bb6a
    style ECS_CLUSTER fill:#e3f2fd,stroke:#1976d2
    style SVC_A fill:#e8eaf6,stroke:#3f51b5
    style SVC_B fill:#e8eaf6,stroke:#3f51b5
    style SVC_N fill:#e8eaf6,stroke:#3f51b5
    style DEPLOY fill:#fce4ec,stroke:#c62828
```

## Deployment Flow

```mermaid
sequenceDiagram
    participant DEV as 👤 Developer
    participant SCRIPT as 📜 deploy.sh
    participant DOCKER as 🐳 Docker
    participant ECR as 📦 ECR
    participant CFN as 📋 CloudFormation
    participant ECS as ⚙️ ECS Cluster
    participant ALB as ⚖️ Internal ALB
    participant APP as 📦 New Task

    DEV->>SCRIPT: ./deploy.sh svc-deploy --env uat
    SCRIPT->>SCRIPT: Read manifest.yml<br/>(app, service, cpu, memory, secrets...)

    rect rgb(232, 245, 233)
        Note over SCRIPT,ECR: Step 1-2: Build & Push
        SCRIPT->>DOCKER: docker build -t image:tag .
        DOCKER-->>SCRIPT: Image built
        SCRIPT->>ECR: docker push image:tag
        ECR-->>SCRIPT: Image pushed
    end

    rect rgb(227, 242, 253)
        Note over SCRIPT,ALB: Step 3: CloudFormation Deploy
        SCRIPT->>CFN: aws cloudformation deploy<br/>(service.yml + parameters)
        CFN->>CFN: Create/Update Task Definition<br/>(new image URI)
        CFN->>ECS: Update ECS Service<br/>(new task definition)
    end

    rect rgb(255, 243, 224)
        Note over ECS,APP: Step 4: Rolling Deployment
        ECS->>APP: Start new task (new image)
        APP->>APP: Container starts up
        ALB->>APP: Health check (/api/orders/health)
        APP-->>ALB: 200 OK
        ALB->>ALB: Register new task IP in Target Group
        ECS->>ECS: Stop old task (60s drain)
    end

    ALB-->>DEV: ✅ Service live at https://uat.app.example.com/api/orders
```

## CloudFormation Stack Dependency

```mermaid
graph LR
    subgraph ADMIN["Admin Stacks (One-Time)"]
        APP["📋 myapp-infrastructure<br/><i>app-infrastructure.yml</i><br/>─────────────<br/>IAM Roles<br/>KMS Key<br/>S3 Bucket"]
        ENV["📋 myapp-uat<br/><i>environment.yml</i><br/>─────────────<br/>ECS Cluster<br/>Internal ALB<br/>Security Groups<br/>Service Discovery"]
        ECR1["📋 myapp-ecr-order-service<br/><i>ecr-repository.yml</i><br/>─────────────<br/>ECR Repository"]
        ECR2["📋 myapp-ecr-user-service<br/><i>ecr-repository.yml</i><br/>─────────────<br/>ECR Repository"]
    end

    subgraph DEV["Developer Stacks (Per Service)"]
        SVC1["📋 myapp-uat-order-service<br/><i>service.yml</i><br/>─────────────<br/>ECS Service + Task Def<br/>Target Group<br/>Listener Rules<br/>IAM Roles<br/>Log Group<br/>Service Discovery"]
        SVC2["📋 myapp-uat-user-service<br/><i>service.yml</i><br/>─────────────<br/>ECS Service + Task Def<br/>Target Group<br/>Listener Rules<br/>IAM Roles<br/>Log Group<br/>Service Discovery"]
    end

    ENV -->|"Fn::ImportValue<br/>ClusterId, ListenerArns,<br/>VpcId, SubnetIds, SG"| SVC1
    ENV -->|"Fn::ImportValue<br/>ClusterId, ListenerArns,<br/>VpcId, SubnetIds, SG"| SVC2

    style ADMIN fill:#e8f5e9,stroke:#388e3c
    style DEV fill:#e3f2fd,stroke:#1976d2
    style APP fill:#fff9c4,stroke:#f9a825
    style ENV fill:#c8e6c9,stroke:#43a047
    style ECR1 fill:#c8e6c9,stroke:#43a047
    style ECR2 fill:#c8e6c9,stroke:#43a047
    style SVC1 fill:#bbdefb,stroke:#1976d2
    style SVC2 fill:#bbdefb,stroke:#1976d2
```

## Secrets Flow

```mermaid
graph LR
    A["👤 Admin runs:<br/>deploy.sh secret-init<br/>--name DB_PASSWORD<br/>--value 'mypass'"] -->|"aws ssm put-parameter<br/>type: SecureString"| B["🔐 SSM Parameter Store<br/>/myapp/uat/secrets/DB_PASSWORD<br/>(encrypted with KMS)"]

    C["👤 Developer adds to manifest.yml:<br/>secrets:<br/>  DB_PASSWORD: /myapp/uat/secrets/DB_PASSWORD"] -->|"deploy.sh svc-deploy"| D["📋 CloudFormation<br/>Task Definition:<br/>Secrets:<br/>  - Name: DB_PASSWORD<br/>    ValueFrom: /myapp/..."]

    D -->|"ECS starts task"| E["⚙️ ECS Agent<br/>(uses Execution Role)"]
    E -->|"ssm:GetParameters"| B
    B -->|"Decrypted value"| E
    E -->|"Injects as env var"| F["📦 Container<br/>process.env.DB_PASSWORD = 'mypass'"]

    style A fill:#fff9c4,stroke:#f9a825
    style B fill:#ffcdd2,stroke:#e53935
    style C fill:#e8eaf6,stroke:#3f51b5
    style D fill:#e3f2fd,stroke:#1976d2
    style E fill:#e8f5e9,stroke:#388e3c
    style F fill:#c8e6c9,stroke:#43a047
```

---

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
├── CODE_EXPLANATION.md          # Detailed code explanation of every file
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
# Deploy a new service or update existing (reads manifest.yml by default)
./deploy.sh svc-deploy --env uat

# Deploy with explicit config path
./deploy.sh svc-deploy --config manifest.yml --env uat

# Deploy with a specific image tag
./deploy.sh svc-deploy --env uat --tag v1.2.3

# Store a secret
./deploy.sh secret-init --app myapp --env uat --name DB_PASSWORD --value "mypassword" --department IT
```

## Service Manifest (manifest.yml)

Developers create this file in their project root. See `config/manifest.yml` for a full example.

```yaml
app: myapp
service: order-service
department: IT
port: 3000
path: /api/orders
healthcheck: /api/orders/health
dockerfile: Dockerfile
listener_rule_priority: 10

environments:
  uat:
    alias: uat.app.example.com
    cpu: 2048
    memory: 4096
    count: 1
    deployment: recreate
    variables:
      AWS_REGION: ap-south-1
    secrets:
      DB_PASSWORD: /myapp/uat/secrets/DB_PASSWORD
```

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

## Prerequisites

- AWS CLI v2 configured with appropriate credentials
- Docker installed and running
- Bash shell (Linux/macOS/WSL)
- Existing VPC with private subnets
- ACM certificate for HTTPS

## Detailed Code Explanation

See [CODE_EXPLANATION.md](CODE_EXPLANATION.md) for a comprehensive breakdown of every file,
every resource, and the logic behind how each component works.
