# Code Explanation - ECS Deploy Framework

This document explains every file, every block of code, and the logic behind how this framework works as a replacement for AWS Copilot.

---

## Overall Architecture and Flow

```
STEP 1 (Admin, once)          STEP 2 (Admin, once per env)     STEP 3 (Admin, per service)
app-infrastructure.yml   -->  environment.yml              -->  ecr-repository.yml
Creates:                      Creates:                          Creates:
- CFN Execution Role          - ECS Cluster                     - ECR repo for the service
- Deploy Role                 - Internal ALB + Listeners
- KMS Key                     - Security Groups                 STEP 4 (Developer, ongoing)
- S3 Artifact Bucket          - Service Discovery Namespace     service.yml (via deploy.sh)
                              - Log Resource Policy             Creates/Updates:
                                                                - ECS Task Definition
                                                                - ECS Service
                                                                - Target Group
                                                                - ALB Listener Rules
                                                                - IAM Roles (exec + task)
                                                                - Service Discovery entry
                                                                - CloudWatch Log Group
```

**How stacks link together:**
- `environment.yml` exports values (Cluster ID, Listener ARNs, VPC ID, Subnet IDs, Security Group IDs)
  using CloudFormation Exports with names like `{app}-{env}-ClusterId`
- `service.yml` imports those values using `Fn::ImportValue` to attach services to the shared environment
- This means environment is created once, and multiple services plug into it independently

---

## File 1: templates/app-infrastructure.yml

**Purpose:** One-time setup per application. Creates foundational IAM roles, encryption key, and artifact storage.
**Stack name convention:** `{app}-infrastructure` (e.g., `myapp-infrastructure`)
**Who runs it:** AWS Admins only

### Parameters Block
```yaml
Parameters:
  AppName:    # e.g., "myapp" - used in all resource naming
  Department: # e.g., "IT" - tagged on every resource for cost tracking/ownership
```
These are passed via `--parameter-overrides` in the deploy script.

### Resource: CFNExecutionRole
```yaml
CFNExecutionRole:
  Type: AWS::IAM::Role
```
**What it does:** This IAM role is assumed by the CloudFormation service itself when it creates/updates
the service stacks (Step 4). When a developer runs `aws cloudformation deploy` for a service,
CloudFormation assumes this role to create ECS services, target groups, IAM roles, etc.

**Why `NotAction` instead of `Action`:**
```yaml
- Effect: Allow
  NotAction:
    - 'organizations:*'
    - 'account:*'
  Resource: '*'
```
This grants CloudFormation permission to do everything EXCEPT modify AWS Organizations and Account settings.
This is a security guardrail - CloudFormation needs broad permissions to create diverse resources
(ECS, ELB, IAM, Logs, etc.) but should never touch org-level settings.

### Resource: DeployRole
```yaml
DeployRole:
  Type: AWS::IAM::Role
```
**What it does:** This role is assumed by the person or CI/CD pipeline running the deploy script.
It has permissions scoped to exactly what the deploy process needs:

- **CloudFormation:** Create/update/delete stacks (to deploy service stacks)
- **ECR:** Push/pull images (to push Docker images during deploy)
- **ECS:** Describe/update services (to monitor deployment status, run exec commands)
- **SSM:** Put/get parameters under `/{app}/*` only (to store/read secrets - scoped to this app only)
- **IAM PassRole:** Can only pass the CFNExecutionRole (so CloudFormation can assume it)
- **Logs:** Read log events (for debugging)

**Trust policy:**
```yaml
Principal:
  AWS: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:root'
```
This means any IAM user/role in the same AWS account can assume this role.
In production, you'd tighten this to specific IAM users or CI/CD roles.

### Resource: ArtifactKey + ArtifactKeyAlias
```yaml
ArtifactKey:
  Type: AWS::KMS::Key
```
**What it does:** Creates a KMS encryption key with automatic annual rotation enabled.
Used to encrypt the S3 artifact bucket. The key alias (`alias/{app}-artifact-key`) makes it
easy to reference by name instead of key ID.

**Key policy:** Grants full key management to the AWS account root, meaning any IAM principal
with appropriate IAM permissions can use/manage this key.

### Resource: ArtifactBucket + ArtifactBucketPolicy
```yaml
ArtifactBucket:
  Type: AWS::S3::Bucket
```
**What it does:** Creates an encrypted S3 bucket for storing deployment artifacts.

**Security features:**
- `VersioningConfiguration: Enabled` - keeps history of all objects, enables rollback
- `BucketEncryption` - all objects encrypted with the KMS key created above
- `BucketKeyEnabled: true` - reduces KMS API calls (cost optimization)
- `PublicAccessBlockConfiguration` - all four public access blocks enabled (no public access possible)
- `OwnershipControls: BucketOwnerEnforced` - disables ACLs, only bucket policies control access
- `LifecycleConfiguration` - auto-deletes artifacts after 90 days, old versions after 7 days

**Bucket policy:**
```yaml
- Sid: ForceHTTPS
  Effect: Deny
  Principal: '*'
  Action: 's3:*'
  Condition:
    Bool:
      aws:SecureTransport: false
```
Denies any non-HTTPS access to the bucket. All communication must be encrypted in transit.

### Outputs Block
Exports 4 values that other stacks can reference:
- `{app}-CFNExecutionRoleArn` - used when deploying with `--role-arn`
- `{app}-DeployRoleArn` - for CI/CD to assume
- `{app}-ArtifactKeyArn` - for encrypting/decrypting artifacts
- `{app}-ArtifactBucket` - bucket name for storing artifacts

---

## File 2: templates/ecr-repository.yml

**Purpose:** Creates one ECR (Elastic Container Registry) repository per service.
Docker images are pushed here during deploy and pulled by ECS tasks at runtime.
**Stack name convention:** `{app}-ecr-{service}` (e.g., `myapp-ecr-order-service`)
**Who runs it:** AWS Admins (before a developer can deploy a new service)

### Resource: ECRRepository
```yaml
ECRRepository:
  Type: AWS::ECR::Repository
  Properties:
    RepositoryName: !Sub '${AppName}/${ServiceName}'
```
**Naming:** Creates repo as `myapp/order-service`. The full image URI becomes:
`123456789012.dkr.ecr.ap-south-1.amazonaws.com/myapp/order-service:tag`

**Repository Policy:**
```yaml
RepositoryPolicyText:
  Statement:
    - Sid: AllowPushPull
      Principal:
        AWS: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:root'
```
Allows any IAM principal in the same account to push and pull images.
This is needed because:
- The deploy script pushes images during `svc-deploy`
- The ECS execution role pulls images when starting tasks

**Lifecycle Policy:**
```json
{
  "rules": [{
    "rulePriority": 1,
    "description": "Keep last 20 images",
    "selection": {
      "tagStatus": "any",
      "countType": "imageCountMoreThan",
      "countNumber": 20
    },
    "action": { "type": "expire" }
  }]
}
```
**What it does:** Automatically deletes old images when more than 20 exist.
This prevents ECR storage costs from growing indefinitely.
Only the 20 most recent images are kept (regardless of tag).

**Why separate stacks per service (not one big stack):**
- Each service gets its own CloudFormation stack
- Adding a new service doesn't require modifying an existing stack
- Deleting a service's repo doesn't affect other services
- Copilot used one giant StackSet with all repos - that was fragile

---

## File 3: templates/environment.yml

**Purpose:** Creates the shared environment infrastructure that all services in an environment use.
This is the "platform" that services plug into.
**Stack name convention:** `{app}-{env}` (e.g., `myapp-uat`)
**Who runs it:** AWS Admins only, once per environment

### Parameters Block
```yaml
VpcId:              # Your existing VPC - we don't create a new one
PrivateSubnetIds:   # Your existing private subnets - ECS tasks and ALB go here
CertificateArn:     # Your existing ACM cert - used for HTTPS on the internal ALB
```
These reference your existing network infrastructure. The template creates everything else fresh.

### Resource: Cluster
```yaml
Cluster:
  Type: AWS::ECS::Cluster
  Properties:
    ClusterName: !Sub '${AppName}-${EnvName}'
    CapacityProviders:
      - FARGATE
      - FARGATE_SPOT
```
**What it does:** Creates an ECS cluster named like `myapp-uat`.

**CapacityProviders:** Registers both FARGATE (on-demand, reliable) and FARGATE_SPOT
(cheaper, can be interrupted). Services default to FARGATE but can be configured for SPOT.

**ExecuteCommandConfiguration:**
```yaml
Configuration:
  ExecuteCommandConfiguration:
    Logging: DEFAULT
```
Enables `aws ecs execute-command` - lets you SSH into running containers for debugging.
Logs the exec sessions to CloudWatch (DEFAULT logging).

**ContainerInsights:** Disabled by default (parameter `EnableContainerInsights`).
Can be enabled for detailed CPU/memory/network metrics per container, but adds cost.

### Resource: ServiceDiscoveryNamespace
```yaml
ServiceDiscoveryNamespace:
  Type: AWS::ServiceDiscovery::PrivateDnsNamespace
  Properties:
    Name: !Sub '${EnvName}.${AppName}.local'
    Vpc: !Ref VpcId
```
**What it does:** Creates a private DNS namespace like `uat.myapp.local` within your VPC.

**How it works:** When a service registers with this namespace (done in service.yml),
it gets a DNS name like `order-service.uat.myapp.local`. Other services in the same VPC
can reach it using this DNS name directly, without going through the load balancer.

**Use case:** Service-to-service communication within the cluster.
For example, if service A needs to call service B, it can use
`http://service-b.uat.myapp.local:3000` instead of going through the ALB.

### Security Groups (3 resources + 3 ingress rules)

**InternalALBSecurityGroup:**
```yaml
InternalALBSecurityGroup:
  Type: AWS::EC2::SecurityGroup
```
Attached to the Internal ALB. Controls what traffic can reach the load balancer.

**EnvironmentSecurityGroup:**
```yaml
EnvironmentSecurityGroup:
  Type: AWS::EC2::SecurityGroup
```
Attached to all ECS tasks. Controls what traffic can reach the containers.

**Ingress rules - the traffic flow:**
```
ECSIngressFromALB:     ALB SG ──────> ECS Tasks SG    (ALB can reach containers)
ECSIngressFromSelf:    ECS SG ──────> ECS Tasks SG    (containers can reach each other)
ALBIngressFromECS:     ECS SG ──────> ALB SG           (containers can reach ALB)
```

All three rules use `IpProtocol: -1` which means ALL protocols and ALL ports.
This is intentional - the ALB listener rules and target group health checks
handle the actual port-level routing. The security groups just control
which resource groups can talk to each other.

**Why no inbound rule from 0.0.0.0/0:**
This is an INTERNAL ALB. It's not internet-facing. Your network team maps
the internal ALB DNS to an internet-facing LB separately. So no public
ingress rules are needed here.

### Internal Application Load Balancer
```yaml
InternalLoadBalancer:
  Type: AWS::ElasticLoadBalancingV2::LoadBalancer
  Properties:
    Scheme: internal
    Type: application
    Subnets: !Ref PrivateSubnetIds
```
**Key properties:**
- `Scheme: internal` - NOT internet-facing. Only accessible from within the VPC.
- `Type: application` - Layer 7 (HTTP/HTTPS), supports path-based and host-based routing.
- `Subnets` - Placed in your private subnets.

**After creation:** The output `InternalLoadBalancerDNS` gives you the ALB DNS name
(e.g., `internal-myapp-uat-int-123456.ap-south-1.elb.amazonaws.com`).
You share this with your network team to map to the internet-facing LB.

### DefaultTargetGroup
```yaml
DefaultTargetGroup:
  Type: AWS::ElasticLoadBalancingV2::TargetGroup
```
**What it does:** A placeholder target group with no real targets.
ALB listeners REQUIRE a default action, so this empty target group serves as the
"catch-all" for requests that don't match any service's listener rules.

**Health check settings:**
- `HealthCheckIntervalSeconds: 10` - checks every 10 seconds (faster than default 30)
- `HealthyThresholdCount: 2` - needs 2 consecutive successes to be "healthy"
- `HealthCheckTimeoutSeconds: 5` - times out after 5 seconds
- `deregistration_delay: 60` - waits 60 seconds before removing a target (allows in-flight requests to complete)

### Listeners (HTTP + HTTPS)
```yaml
InternalHTTPListener:   # Port 80  - services add HTTP->HTTPS redirect rules here
InternalHTTPSListener:  # Port 443 - services add forward-to-target-group rules here
```
**How routing works:**
1. Request comes in on port 80 or 443
2. Listener checks its rules (added by each service stack)
3. Rules match on host header + path pattern
4. HTTP rules redirect to HTTPS (301)
5. HTTPS rules forward to the service's target group
6. If no rule matches, traffic goes to the default (empty) target group

**HTTPS listener** attaches the ACM certificate you provided, enabling TLS termination at the ALB.

### LogResourcePolicy
```yaml
LogResourcePolicy:
  Type: AWS::Logs::ResourcePolicy
```
**What it does:** Allows the AWS log delivery service to write to CloudWatch log groups
under the pattern `/{app}/{env}/*`. Without this, some AWS services (like ALB access logs
routed through delivery.logs.amazonaws.com) would be denied permission to write logs.

### Outputs Block (Critical - this is how services connect)
Every output uses `Export` with a predictable name pattern:
```yaml
Export:
  Name: !Sub '${AppName}-${EnvName}-ClusterId'
```

**Exported values and who uses them:**
| Export Name | Value | Used By |
|---|---|---|
| `{app}-{env}-VpcId` | VPC ID | service.yml (target group) |
| `{app}-{env}-PrivateSubnets` | Comma-separated subnet IDs | service.yml (ECS task networking) |
| `{app}-{env}-ClusterId` | ECS Cluster ARN | service.yml (ECS service) |
| `{app}-{env}-EnvironmentSecurityGroup` | SG ID | service.yml (ECS task networking) |
| `{app}-{env}-InternalHTTPListenerArn` | Listener ARN | service.yml (HTTP redirect rule) |
| `{app}-{env}-InternalHTTPSListenerArn` | Listener ARN | service.yml (HTTPS forward rule) |
| `{app}-{env}-ServiceDiscoveryNamespaceID` | Namespace ID | service.yml (service registration) |
| `{app}-{env}-InternalLoadBalancerDNS` | ALB DNS name | Network team (map to public LB) |

**This is the glue:** When service.yml does `Fn::ImportValue: 'myapp-uat-ClusterId'`,
CloudFormation looks up the exported value from the environment stack and injects it.
This is how services "plug into" the shared environment without hardcoding any IDs.

---

## File 4: templates/service.yml

**Purpose:** Creates everything needed for a single ECS service. This is the template
developers interact with (via the deploy script). Each service gets its own CloudFormation stack.
**Stack name convention:** `{app}-{env}-{service}` (e.g., `myapp-uat-order-service`)
**Who runs it:** Developers (via `./deploy.sh svc-deploy`)

### Parameters Block
The deploy script reads `manifest.yml` and passes these as `--parameter-overrides`:

```yaml
# Identity
AppName, EnvName, ServiceName, Department

# Container config
ContainerImage:    # Full ECR URI like 123456789012.dkr.ecr.ap-south-1.amazonaws.com/myapp/order-service:abc123
ContainerPort:     # Port the app listens on (default 3000)
TaskCPU:           # Fargate CPU units (512 = 0.5 vCPU, 1024 = 1 vCPU, 2048 = 2 vCPU)
TaskMemory:        # Fargate memory in MB (1024 = 1GB, 4096 = 4GB)
DesiredCount:      # Number of running tasks (instances of the container)

# Routing
HealthCheckPath:   # ALB health check endpoint (e.g., /api/orders/health)
RulePath:          # URL path for ALB routing (e.g., /api/orders)
HostAlias:         # Domain name for host-header matching (e.g., uat.app.example.com)
ListenerRulePriority: # Unique number 1-50000, determines rule evaluation order

# Behavior
DeploymentStrategy:   # "rolling" (zero-downtime) or "recreate" (stop old, start new)
EnableExecuteCommand: # Allow SSH into containers via aws ecs execute-command

# Datadog (optional)
EnableDatadogSidecar, DatadogApiKeySSMParam, DatadogSite
EnableFirelensLogging, DatadogLogsHost, DatadogSource
```

### Conditions Block
```yaml
Conditions:
  IsRecreate: !Equals [!Ref DeploymentStrategy, 'recreate']
  UseDatadog: !Equals [!Ref EnableDatadogSidecar, 'true']
  UseFirelens: !Equals [!Ref EnableFirelensLogging, 'true']
  UseExecCommand: !Equals [!Ref EnableExecuteCommand, 'true']
  HasDatadogApiKey: !Not [!Equals [!Ref DatadogApiKeySSMParam, '']]
```
**What it does:** CloudFormation conditions are evaluated at deploy time.
They control which resources are created:
- `IsRecreate` - changes deployment config (min 0% vs min 100%)
- `UseDatadog` - adds/removes the Datadog agent sidecar container
- `UseFirelens` - adds/removes the Fluent Bit log router container
- `UseExecCommand` - enables/disables ECS Exec on the service
- `HasDatadogApiKey` - only injects DD_API_KEY secret if the SSM param is provided

### Resource: LogGroup
```yaml
LogGroup:
  Type: AWS::Logs::LogGroup
  Properties:
    LogGroupName: !Sub '/${AppName}/${EnvName}/${ServiceName}'
    RetentionInDays: !Ref LogRetentionDays
```
**What it does:** Creates a CloudWatch log group like `/myapp/uat/order-service`.
All container logs (app, datadog sidecar, firelens) go here.
`RetentionInDays: 30` means logs older than 30 days are automatically deleted.

### Resource: ExecutionRole
```yaml
ExecutionRole:
  Type: AWS::IAM::Role
  Properties:
    RoleName: !Sub '${AppName}-${EnvName}-${ServiceName}-exec'
```
**What it does:** This is the ECS EXECUTION role - used by the ECS AGENT (not your app code).
The ECS agent uses this role to:
1. Pull Docker images from ECR
2. Fetch secrets from SSM Parameter Store
3. Fetch secrets from Secrets Manager
4. Write logs to CloudWatch

**ManagedPolicyArns:**
```yaml
- !Sub 'arn:${AWS::Partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy'
```
This AWS-managed policy grants ECR pull + CloudWatch logs write permissions.

**Custom policy - SecretsAccess:**
```yaml
- Sid: SSMAccess
  Action: ['ssm:GetParameters', 'ssm:GetParameter']
  Resource:
    - !Sub 'arn:...:parameter/${AppName}/${EnvName}/secrets/*'
```
**This is the key change from Copilot:** The execution role can access ANY SSM parameter
under `/{app}/{env}/secrets/*`. No special role or tag required.
When you store a secret at `/myapp/uat/secrets/DB_PASSWORD`, any service in the `myapp-uat`
environment can read it. This replaces Copilot's restrictive tag-based access.

**KMS Decrypt:** Needed because SSM SecureString parameters are encrypted with KMS.
The execution role needs `kms:Decrypt` to read the decrypted value.

### Resource: TaskRole
```yaml
TaskRole:
  Type: AWS::IAM::Role
  Properties:
    RoleName: !Sub '${AppName}-${EnvName}-${ServiceName}-task'
```
**What it does:** This is the ECS TASK role - used by YOUR APPLICATION CODE inside the container.
If your app calls AWS APIs (S3, DynamoDB, etc.), it uses this role's permissions.

**DenyIAM policy:**
```yaml
- Effect: Deny
  Action: 'iam:*'
  Resource: '*'
```
Security guardrail - prevents application code from creating/modifying IAM roles.
Even if the app is compromised, it cannot escalate privileges.

**ExecuteCommand policy:**
```yaml
Action:
  - 'ssmmessages:CreateControlChannel'
  - 'ssmmessages:OpenControlChannel'
  - 'ssmmessages:CreateDataChannel'
  - 'ssmmessages:OpenDataChannel'
```
Required for `aws ecs execute-command` to work. ECS Exec uses SSM Session Manager
under the hood, so the task role needs these SSM Messages permissions.

### Resource: TaskDefinition
```yaml
TaskDefinition:
  Type: AWS::ECS::TaskDefinition
  Properties:
    Family: !Sub '${AppName}-${EnvName}-${ServiceName}'
    NetworkMode: awsvpc
    RequiresCompatibilities: [FARGATE]
```
**What it does:** Defines what containers to run and how to configure them.
Think of it as a "blueprint" for your containers.

**Family:** Groups task definition revisions. Each deploy creates a new revision
(e.g., `myapp-uat-order-service:1`, `myapp-uat-order-service:2`, etc.)

**NetworkMode: awsvpc:** Each task gets its own ENI (network interface) with a private IP.
Required for Fargate. This is how the ALB target group routes to individual tasks by IP.

**ContainerDefinitions - Main Application Container:**
```yaml
- Name: !Ref ServiceName
  Image: !Ref ContainerImage
  Essential: true
  PortMappings:
    - ContainerPort: !Ref ContainerPort
```
- `Essential: true` - if this container dies, the entire task is stopped
- `PortMappings` - exposes the container port (e.g., 3000) to the task's ENI

**LogConfiguration - Two modes (conditional):**

Mode 1 - Firelens (when `UseFirelens` is true):
```yaml
LogDriver: awsfirelens
Options:
  Name: datadog          # Fluent Bit output plugin
  Host: http-intake.logs.datadoghq.com
  dd_service: order-service  # Service name in Datadog
  dd_tags: env:uat,source:nodejs
```
Logs are routed through the Fluent Bit sidecar to Datadog.
The `apikey` is fetched from SSM at runtime via `SecretOptions`.

Mode 2 - CloudWatch (when `UseFirelens` is false):
```yaml
LogDriver: awslogs
Options:
  awslogs-group: !Ref LogGroup
  awslogs-stream-prefix: app
```
Logs go directly to CloudWatch. Simpler, no sidecar needed.

**ContainerDefinitions - Datadog Agent Sidecar (conditional):**
```yaml
- !If
  - UseDatadog
  - Name: datadog-agent
    Image: 'public.ecr.aws/datadog/agent:7'
    Essential: false
```
- Only created when `EnableDatadogSidecar: true`
- `Essential: false` - if the Datadog agent crashes, the main app keeps running
- `ECS_FARGATE: true` - tells the agent it's running on Fargate (changes metric collection)
- `DD_API_KEY` is injected from SSM as a secret (never in plain text)

**ContainerDefinitions - Firelens Log Router (conditional):**
```yaml
- !If
  - UseFirelens
  - Name: log_router
    Image: 'public.ecr.aws/aws-observability/aws-for-fluent-bit:stable'
    Essential: true
    FirelensConfiguration:
      Type: fluentbit
      Options:
        enable-ecs-log-metadata: 'true'
```
- Only created when `EnableFirelensLogging: true`
- `Essential: true` - if the log router dies, the task stops (logs must not be lost)
- `FirelensConfiguration` tells ECS to route other containers' logs through this container
- `enable-ecs-log-metadata` adds ECS task metadata (task ID, cluster, etc.) to each log line
- Uses the AWS-maintained Fluent Bit image from public ECR

### Resource: DiscoveryService
```yaml
DiscoveryService:
  Type: AWS::ServiceDiscovery::Service
  Properties:
    DnsConfig:
      RoutingPolicy: MULTIVALUE
      DnsRecords:
        - TTL: 10
          Type: A
        - TTL: 10
          Type: SRV
```
**What it does:** Registers this service in the Cloud Map namespace created by environment.yml.
Creates DNS records like `order-service.uat.myapp.local`.

**MULTIVALUE routing:** Returns all healthy IPs when queried (client-side load balancing).
**TTL: 10:** DNS records expire after 10 seconds, so clients get fresh IPs quickly.
**A record:** Returns the task's private IP address.
**SRV record:** Returns IP + port (useful when services run on non-standard ports).

**HealthCheckCustomConfig:**
```yaml
HealthCheckCustomConfig:
  FailureThreshold: 1
```
Uses ECS health status (not Route53 health checks). If ECS reports a task as unhealthy,
it's removed from DNS after 1 failure.

### Resource: TargetGroup
```yaml
TargetGroup:
  Type: AWS::ElasticLoadBalancingV2::TargetGroup
  Properties:
    Name: !Sub '${AppName}-${EnvName}-${ServiceName}'
    HealthCheckPath: !Ref HealthCheckPath
    TargetType: ip
```
**What it does:** The ALB routes traffic to this target group, which contains the
private IPs of the running ECS tasks.

**TargetType: ip:** Required for Fargate. Each task gets a private IP, and the ALB
sends traffic directly to that IP (not via instance ID like EC2).

**Key attributes:**
- `deregistration_delay: 60` - when a task is being replaced, the ALB waits 60 seconds
  before removing it, allowing in-flight requests to complete
- `stickiness.enabled: false` - no session affinity, requests are distributed evenly

**Health check flow:**
1. ALB sends GET request to `HealthCheckPath` (e.g., `/api/orders/health`) every 10 seconds
2. If 2 consecutive checks return 200, task is marked healthy
3. If check takes longer than 5 seconds, it's a timeout (counts as failure)
4. Healthy tasks receive traffic; unhealthy tasks are removed from rotation

### Resources: HTTPListenerRule + HTTPSListenerRule
```yaml
HTTPListenerRule:   # Redirects HTTP -> HTTPS
HTTPSListenerRule:  # Forwards HTTPS -> Target Group
```
**How ALB routing works for this service:**

Both rules use TWO conditions (AND logic - both must match):
```yaml
Conditions:
  - Field: host-header        # e.g., uat.app.example.com
  - Field: path-pattern       # e.g., /api/orders or /api/orders/*
```

**HTTP rule (port 80):** Returns a 301 redirect to HTTPS.
```
Request:  http://uat.app.example.com/api/orders/list
Response: 301 -> https://uat.app.example.com/api/orders/list
```

**HTTPS rule (port 443):** Forwards to the target group.
```
Request:  https://uat.app.example.com/api/orders/list
Action:   Forward to TargetGroup -> ECS task IP:3000
```

**Priority:** Each rule has a unique priority number (1-50000).
Lower numbers are evaluated first. If two services have overlapping paths,
the one with lower priority number wins.

**Fn::ImportValue:** Both rules reference the listener ARNs exported by environment.yml.
This is how the service "attaches" its rules to the shared ALB.

### Resource: ECSService
```yaml
ECSService:
  Type: AWS::ECS::Service
  DependsOn:
    - HTTPListenerRule
    - HTTPSListenerRule
```
**What it does:** Creates the actual running service - tells ECS to maintain
`DesiredCount` tasks running at all times.

**DependsOn:** The service must wait for listener rules to be created first,
because it registers with the target group which is referenced by those rules.

**Key properties explained:**

```yaml
PlatformVersion: LATEST        # Use latest Fargate platform version
LaunchType: FARGATE             # Serverless containers (no EC2 instances to manage)
PropagateTags: SERVICE          # Tags from the service are copied to each task
```

**DeploymentConfiguration:**
```yaml
DeploymentConfiguration:
  DeploymentCircuitBreaker:
    Enable: true
    Rollback: true
  MinimumHealthyPercent: !If [IsRecreate, 0, 100]
  MaximumPercent: !If [IsRecreate, 100, 200]
```
- **Circuit breaker:** If new tasks keep failing health checks, ECS automatically
  rolls back to the previous working task definition. Prevents bad deploys from
  taking down the service.
- **Rolling strategy (default):** `Min 100%, Max 200%` - ECS starts new tasks first,
  waits for them to be healthy, then stops old tasks. Zero downtime.
- **Recreate strategy:** `Min 0%, Max 100%` - ECS stops all old tasks first,
  then starts new ones. Brief downtime, but useful when you can't run two versions
  simultaneously (e.g., database migrations).

**NetworkConfiguration:**
```yaml
AwsvpcConfiguration:
  AssignPublicIp: DISABLED
  Subnets: (imported from environment)
  SecurityGroups: (imported from environment)
```
- `DISABLED` - tasks get private IPs only (no internet access unless you have a NAT gateway)
- Subnets and security groups come from the environment stack via `Fn::ImportValue`

**ServiceRegistries:**
```yaml
ServiceRegistries:
  - RegistryArn: !GetAtt DiscoveryService.Arn
    Port: !Ref ContainerPort
```
Registers running task IPs with Cloud Map (service discovery).
Other services can find this service via DNS.

**LoadBalancers:**
```yaml
LoadBalancers:
  - ContainerName: !Ref ServiceName
    ContainerPort: !Ref ContainerPort
    TargetGroupArn: !Ref TargetGroup
```
Tells ECS to register task IPs with the ALB target group.
When a new task starts, its IP is added to the target group.
When a task stops, its IP is removed.

**HealthCheckGracePeriodSeconds: 60:**
After a new task starts, ECS waits 60 seconds before checking ALB health.
This gives the application time to start up (load configs, warm caches, etc.)
before being evaluated.

### Outputs Block
```yaml
ServiceUrl:
  Value: !Sub 'https://${HostAlias}${RulePath}'
```
Outputs the full URL where the service is accessible (e.g., `https://uat.app.example.com/api/orders`).

---

## File 5: scripts/deploy.sh

**Purpose:** The CLI wrapper that developers and admins use. Reads manifest.yml,
builds Docker images, pushes to ECR, and deploys CloudFormation stacks.
**This is the main entry point** - replaces all `copilot` CLI commands.

### Script Header
```bash
#!/usr/bin/env bash
set -euo pipefail
```
- `set -e` - exit immediately if any command fails
- `set -u` - treat unset variables as errors (prevents typos from causing silent bugs)
- `set -o pipefail` - if any command in a pipe fails, the whole pipe fails

### Global Variables
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/../templates"
REGION="${AWS_REGION:-ap-south-1}"
```
- `SCRIPT_DIR` - absolute path to where deploy.sh lives (resolves symlinks)
- `TEMPLATES_DIR` - path to CloudFormation templates (relative to script location)
- `REGION` - defaults to `ap-south-1` but can be overridden via `AWS_REGION` env var or `--region` flag

### YAML Parser Functions

These are lightweight YAML parsers using `grep`, `sed`, and `awk`.
They avoid requiring external tools like `yq` or `python`.

**yaml_get(file, key)** - Reads a top-level key:
```bash
yaml_get() {
  local file="$1" key="$2"
  grep "^${key}:" "$file" | head -1 | sed "s/^${key}:[[:space:]]*//" | ...
}
```
Logic:
1. `grep "^${key}:"` - find lines starting with the key (e.g., `app:`)
2. `head -1` - take only the first match
3. `sed` - remove the key and colon, leaving just the value
4. Strip surrounding quotes and whitespace

Example: For `app: myapp`, `yaml_get manifest.yml "app"` returns `myapp`

**yaml_get_nested(file, parent, child)** - Reads a nested key:
```bash
yaml_get_nested() {
  local file="$1" parent="$2" child="$3"
  awk -v parent="$parent" -v child="$child" '...'
}
```
Logic (awk state machine):
1. Find a line matching `parent:` (e.g., `datadog:`)
2. Track indentation level
3. While inside the parent block, look for `child:` (e.g., `enabled:`)
4. Extract the value after the colon
5. Exit when indentation returns to parent level (left the block)

Example: For `datadog:\n  enabled: true`, `yaml_get_nested manifest.yml "datadog" "enabled"` returns `true`

**yaml_get_env_value(file, env, key)** - Reads a value under a specific environment:
```bash
yaml_get_env_value() {
  local file="$1" env="$2" key="$3"
  awk -v env="$env" -v key="$key" '...'
}
```
Logic (awk state machine):
1. Find `environments:` line, enter environments block
2. Find `  {env}:` line (e.g., `  uat:`), enter that env block
3. Look for `    {key}:` (e.g., `    cpu:`) at 4-space indent
4. Extract the value
5. Exit env block when indentation goes back to 2-space level

Example: `yaml_get_env_value manifest.yml "uat" "cpu"` returns `2048`

**yaml_get_env_map(file, env, section)** - Reads all key-value pairs under an env section:
```bash
yaml_get_env_map() {
  local file="$1" env="$2" section="$3"
  awk -v env="$env" -v section="$section" '...'
}
```
Logic:
1. Navigate to `environments: > {env}: > {section}:` (e.g., `variables:`)
2. Read all lines at 6-space indent (the key-value pairs)
3. Split each line on the first colon to get key=value
4. Output as `KEY=VALUE` pairs, one per line

Example: `yaml_get_env_map manifest.yml "uat" "variables"` returns:
```
AWS_REGION=ap-south-1
PORTAL_URL=https://uat.app.example.com/portal/login
MYSQL_DATABASE_HOST=10.0.1.100
```

### Command: cmd_app_init

```bash
cmd_app_init() {
  # 1. Parse --app and --department flags
  # 2. Run: aws cloudformation deploy --template-file app-infrastructure.yml
  # 3. Show stack outputs (role ARNs, bucket name, key ARN)
}
```
**Flow:**
1. Validates required flags (`--app`, `--department`)
2. Sets stack name to `{app}-infrastructure`
3. Calls `aws cloudformation deploy` which:
   - Creates the stack if it doesn't exist
   - Updates it if it already exists and there are changes
   - Does nothing if `--no-fail-on-empty-changeset` and nothing changed
4. `--capabilities CAPABILITY_NAMED_IAM` is required because the template creates IAM roles with custom names
5. `--tags` applies tags to the CloudFormation stack itself (in addition to resource-level tags)
6. After deploy, queries and displays the stack outputs in a table

### Command: cmd_env_init

```bash
cmd_env_init() {
  # 1. Parse --app, --env, --department, --vpc-id, --private-subnets, --cert-arn
  # 2. Run: aws cloudformation deploy --template-file environment.yml
  # 3. Show the Internal ALB DNS name
}
```
**Flow:**
1. Validates all 6 required flags
2. Sets stack name to `{app}-{env}` (e.g., `myapp-uat`)
3. Deploys the environment template
4. After deploy, queries specifically for the `InternalLoadBalancerDNS` output
   and displays it - this is what you share with the network team

### Command: cmd_add_repo

```bash
cmd_add_repo() {
  # 1. Parse --app, --service, --department
  # 2. Run: aws cloudformation deploy --template-file ecr-repository.yml
}
```
**Flow:** Simple - creates a stack named `{app}-ecr-{service}` that contains one ECR repository.
No `CAPABILITY_NAMED_IAM` needed because this template doesn't create IAM resources.

### Command: cmd_svc_deploy (The Main Developer Command)

This is the most complex command. Here's the step-by-step flow:

**Step 0: Parse config and validate**
```bash
local config="manifest.yml" env="" tag=""
```
- Defaults to `manifest.yml` if `--config` not provided
- Reads all top-level values: app, service, department, port, path, healthcheck, dockerfile, priority
- Reads environment-specific values: alias, cpu, memory, count, deployment strategy
- Applies defaults for any missing values (cpu=512, memory=1024, count=1, etc.)
- Validates that required values exist (app, service, department, alias)

**Step 1: Determine Docker image tag**
```bash
if [[ -z "$tag" ]]; then
  tag=$(git rev-parse --short HEAD 2>/dev/null || echo "latest")
fi
```
- If `--tag` not provided, uses the current git commit short SHA (e.g., `a1b2c3d`)
- Falls back to `latest` if not in a git repo
- Constructs full image URI: `{account_id}.dkr.ecr.{region}.amazonaws.com/{app}/{service}:{tag}`

**Step 2: Docker Build**
```bash
docker build -t "${image_uri}" -f "$dockerfile" .
```
- Builds the Docker image using the Dockerfile specified in manifest.yml
- Tags it with the full ECR URI so it can be pushed directly

**Step 3: ECR Login and Push**
```bash
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "${account_id}.dkr.ecr.${REGION}.amazonaws.com"
docker push "${image_uri}"
```
- Gets a temporary auth token from ECR (valid for 12 hours)
- Pipes it to `docker login` (avoids storing credentials)
- Pushes the image to ECR

**Step 4: Build Environment Variables JSON**
```bash
env_vars_json=$(build_env_vars_json "$config" "$env" "$app" "$service")
```
The `build_env_vars_json` function:
1. Starts with 3 standard variables: `APP_NAME`, `ENV_NAME`, `SERVICE_NAME`
2. Reads the `variables:` section from the manifest for the target environment
3. Builds a JSON array like:
```json
[
  {"name":"APP_NAME","value":"myapp"},
  {"name":"ENV_NAME","value":"uat"},
  {"name":"SERVICE_NAME","value":"order-service"},
  {"name":"AWS_REGION","value":"ap-south-1"},
  {"name":"MYSQL_DATABASE_HOST","value":"10.0.1.100"}
]
```
This JSON is passed to CloudFormation but NOTE: the current service.yml template
doesn't directly consume this JSON as a parameter (env vars and secrets are
handled differently in CloudFormation - see the note at the end).

**Step 5: Build Secrets JSON**
```bash
secrets_json=$(build_secrets_json "$config" "$env")
```
The `build_secrets_json` function:
1. Reads the `secrets:` section from the manifest for the target environment
2. Builds a JSON array like:
```json
[
  {"name":"DB_USERNAME","valueFrom":"/myapp/uat/secrets/APP_DB_USERNAME"},
  {"name":"DB_PASSWORD","valueFrom":"/myapp/uat/secrets/APP_DB_PASSWORD"}
]
```
`valueFrom` is the SSM parameter path. ECS resolves this at task startup time -
it fetches the actual secret value from SSM and injects it as an environment variable.

**Step 6: Parse Datadog Config**
```bash
dd_enabled=$(yaml_get_nested "$config" "datadog" "enabled")
if [[ "$dd_enabled" == "true" ]]; then
  enable_datadog="true"
  dd_api_key_ssm=$(yaml_get_nested "$config" "datadog" "api_key_ssm")
  dd_api_key_ssm="${dd_api_key_ssm//\$\{ENV\}/$env}"
```
- Checks if Datadog is enabled in the manifest
- Reads the SSM parameter path for the API key
- Replaces `${ENV}` placeholder with the actual environment name
  (e.g., `myapp/${ENV}/secrets/DATADOG_API_KEY` becomes `myapp/uat/secrets/DATADOG_API_KEY`)
- Similarly checks if Firelens logging is enabled under the `datadog.firelens` section

**Step 7: Deploy CloudFormation Stack**
```bash
aws cloudformation deploy \
  --template-file "${TEMPLATES_DIR}/service.yml" \
  --stack-name "${app}-${env}-${service}" \
  --parameter-overrides \
    AppName="$app" \
    EnvName="$env" \
    ...all other parameters...
  --capabilities CAPABILITY_NAMED_IAM \
  --tags "app=${app}" "environment=${env}" "service=${service}" "Department=${department}" \
  --no-fail-on-empty-changeset
```
**What happens during deploy:**
- **First deploy (new service):** CloudFormation creates all resources (task def, service, TG, rules, IAM roles, etc.)
- **Subsequent deploys (update):** CloudFormation detects what changed (usually just `ContainerImage`)
  and updates only the affected resources. ECS sees the new task definition and performs a rolling deployment.
- `--no-fail-on-empty-changeset` prevents errors when nothing changed (idempotent)

### Command: cmd_secret_init

```bash
cmd_secret_init() {
  local param_name="/${app}/${env}/secrets/${name}"

  aws ssm put-parameter \
    --name "$param_name" \
    --value "$value" \
    --type SecureString \
    --tags "Key=app,Value=${app}" ... \
    --region "$REGION" 2>/dev/null || \
  aws ssm put-parameter \
    --name "$param_name" \
    --value "$value" \
    --type SecureString \
    --overwrite \
    --region "$REGION"
}
```
**Flow:**
1. Constructs the SSM parameter path: `/{app}/{env}/secrets/{name}`
2. First attempt: creates a NEW parameter with tags
   - `SecureString` means the value is encrypted with KMS
   - Tags are applied for cost tracking and access control
3. If the parameter already exists, the first command fails (can't add tags to existing params)
4. Falls back to `--overwrite` which updates the existing parameter's value
   (tags from the original creation are preserved)

### Main Entry Point
```bash
COMMAND="$1"
shift
case "$COMMAND" in
  app-init)     cmd_app_init "$@" ;;
  env-init)     cmd_env_init "$@" ;;
  add-repo)     cmd_add_repo "$@" ;;
  svc-deploy)   cmd_svc_deploy "$@" ;;
  secret-init)  cmd_secret_init "$@" ;;
  help|--help|-h) usage ;;
  *) log_error "Unknown command: $COMMAND"; usage ;;
esac
```
Takes the first argument as the command name, shifts it off, and passes
remaining arguments to the appropriate function.

---

## File 6: config/manifest.yml

**Purpose:** Example service manifest that developers copy to their project root.
The deploy script reads this file to know how to deploy the service.

### Top-Level Config (applies to all environments)
```yaml
app: myapp                       # Which application this service belongs to
service: order-service           # Service name (used in stack names, ECR repo, etc.)
department: IT                   # Department tag applied to all resources
port: 3000                       # Port the application listens on inside the container
path: /api/orders                # URL path for ALB routing
healthcheck: /api/orders/health  # Endpoint ALB hits to check if the app is alive
dockerfile: Dockerfile           # Path to Dockerfile (relative to project root)
listener_rule_priority: 10       # Unique priority for ALB listener rules (1-50000)
```

**listener_rule_priority:** This MUST be unique across all services in the same environment.
If two services have the same priority, CloudFormation will fail.
Convention: assign each service a unique number (10, 20, 30, etc.)

### Datadog Section (optional)
```yaml
datadog:
  enabled: true
  api_key_ssm: myapp/${ENV}/secrets/DATADOG_API_KEY
  site: datadoghq.com
  firelens:
    enabled: true
    host: http-intake.logs.datadoghq.com
    source: nodejs
```
- `enabled: true` adds the Datadog agent sidecar container to the task
- `api_key_ssm` is the SSM parameter path where the Datadog API key is stored
  - `${ENV}` is replaced by the deploy script with the actual environment name
  - So for `--env uat`, it becomes `myapp/uat/secrets/DATADOG_API_KEY`
- `firelens.enabled: true` adds a Fluent Bit log router that sends app logs to Datadog
- `source: nodejs` tells Datadog how to parse the logs (use `java` for Java apps, etc.)

**If you don't use Datadog:** Simply remove the entire `datadog:` section or set `enabled: false`.
The service will use standard CloudWatch logging instead.

### Per-Environment Overrides
```yaml
environments:
  uat:
    alias: uat.app.example.com        # Domain name for this env
    cpu: 2048                           # 2 vCPUs
    memory: 4096                        # 4 GB RAM
    count: 1                            # 1 running task
    deployment: recreate                # Stop old, start new (brief downtime)
    variables:                          # Environment variables injected into container
      AWS_REGION: ap-south-1
      MYSQL_DATABASE_HOST: 10.0.1.100
    secrets:                            # SSM parameter paths (resolved at runtime)
      DB_USERNAME: /myapp/uat/secrets/APP_DB_USERNAME
      DB_PASSWORD: /myapp/uat/secrets/APP_DB_PASSWORD
```

**alias:** The domain name used in ALB host-header routing.
Requests to `https://uat.app.example.com/api/orders` are routed to this service.

**cpu/memory:** Fargate CPU/memory combinations must follow AWS rules:
| CPU (units) | Memory (MB) options |
|---|---|
| 256 | 512, 1024, 2048 |
| 512 | 1024 - 4096 |
| 1024 | 2048 - 8192 |
| 2048 | 4096 - 16384 |
| 4096 | 8192 - 30720 |

**deployment:**
- `rolling` (default) - zero downtime. New tasks start, get healthy, then old tasks stop.
- `recreate` - old tasks stop first, then new tasks start. Use when you can't run two versions at once.

**variables vs secrets:**
- `variables` are plain text, visible in the task definition. Use for non-sensitive config.
- `secrets` reference SSM parameter paths. ECS fetches the actual value at task startup
  and injects it as an environment variable. The value is NEVER stored in the task definition.

---

## End-to-End Deploy Flow (What Happens When a Developer Runs svc-deploy)

```
Developer runs: ./deploy.sh svc-deploy --env uat

1. Script reads manifest.yml
   ├── Extracts: app=myapp, service=order-service, port=3000, path=/api/orders
   └── Extracts env-specific: alias=uat.app.example.com, cpu=2048, memory=4096

2. Determines image tag
   └── git rev-parse --short HEAD → "a1b2c3d"
   └── image_uri = 123456789012.dkr.ecr.ap-south-1.amazonaws.com/myapp/order-service:a1b2c3d

3. Docker build
   └── docker build -t {image_uri} -f Dockerfile .

4. ECR push
   ├── aws ecr get-login-password | docker login
   └── docker push {image_uri}

5. CloudFormation deploy (stack: myapp-uat-order-service)
   ├── First time: Creates all resources
   │   ├── Log Group: /myapp/uat/order-service
   │   ├── Execution Role: myapp-uat-order-service-exec
   │   ├── Task Role: myapp-uat-order-service-task
   │   ├── Task Definition: myapp-uat-order-service (revision 1)
   │   ├── Target Group: myapp-uat-order-service
   │   ├── HTTP Listener Rule: redirect to HTTPS (priority 10)
   │   ├── HTTPS Listener Rule: forward to TG (priority 10)
   │   ├── Service Discovery: order-service.uat.myapp.local
   │   └── ECS Service: order-service (desired count: 1)
   │
   └── Subsequent times: Updates changed resources
       ├── New Task Definition revision (new image URI)
       └── ECS Service detects new task def → rolling deployment
           ├── Starts new task with new image
           ├── Waits for health check to pass (60s grace period)
           ├── Registers new task IP in target group
           ├── Deregisters old task IP (60s drain)
           └── Stops old task

6. Service is live at: https://uat.app.example.com/api/orders
```

---

## How Secrets Work (SSM Parameter Store)

```
Admin stores secret:
  ./deploy.sh secret-init --app myapp --env uat --name DB_PASSWORD --value "mypass" --department IT
  → Creates SSM parameter: /myapp/uat/secrets/DB_PASSWORD (type: SecureString, encrypted with KMS)

Developer references it in manifest.yml:
  secrets:
    DB_PASSWORD: /myapp/uat/secrets/DB_PASSWORD

During deploy:
  → CloudFormation creates task definition with:
    Secrets:
      - Name: DB_PASSWORD
        ValueFrom: /myapp/uat/secrets/DB_PASSWORD

At task startup:
  → ECS agent (using Execution Role) calls ssm:GetParameters
  → Fetches the decrypted value of /myapp/uat/secrets/DB_PASSWORD
  → Injects it as environment variable DB_PASSWORD="mypass" into the container
  → Application reads it via process.env.DB_PASSWORD (Node.js) or System.getenv("DB_PASSWORD") (Java)
```

The secret value is NEVER stored in CloudFormation, task definition, or container logs.
It only exists in SSM (encrypted) and in the container's memory at runtime.

---

## Tagging Strategy

Every resource created by every template gets these tags:

| Tag Key | Value | Purpose |
|---|---|---|
| `app` | e.g., `myapp` | Identifies which application owns the resource |
| `environment` | e.g., `uat` | Identifies which environment (not on app-level resources) |
| `service` | e.g., `order-service` | Identifies which service (only on service-level resources) |
| `Department` | e.g., `IT` | Cost allocation, ownership tracking |

CloudFormation stack-level tags (via `--tags` in the deploy command) are also applied,
which means they propagate to all resources in the stack automatically.
The resource-level tags are explicit for resources that don't inherit stack tags.
