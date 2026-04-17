#!/usr/bin/env bash
set -euo pipefail

#######################################################################
# ECS Deploy CLI - AWS Copilot Replacement
#
# Admin commands (one-time):
#   ./deploy.sh app-init    --app <name> --department <dept>
#   ./deploy.sh env-init    --app <name> --env <env> --department <dept> \
#                           --vpc-id <id> --private-subnets <s1,s2> --cert-arn <arn>
#   ./deploy.sh add-repo    --app <name> --service <svc> --department <dept>
#
# Developer commands:
#   ./deploy.sh svc-deploy  --config <path> --env <env> [--tag <tag>]
#   ./deploy.sh secret-init --app <name> --env <env> --name <key> --value <val> --department <dept>
#######################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/../templates"
REGION="${AWS_REGION:-ap-south-1}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
  cat <<'EOF'
ECS Deploy CLI - AWS Copilot Replacement

ADMIN COMMANDS (one-time setup):
  app-init      Initialize app infrastructure (IAM roles, KMS, S3)
  env-init      Initialize environment (ECS cluster, ALB, security groups)
  add-repo      Create ECR repository for a service

DEVELOPER COMMANDS:
  svc-deploy    Build, push, and deploy a service to ECS
  secret-init   Store a secret in SSM Parameter Store

OPTIONS:
  --app             Application name (e.g., myapp)
  --env             Environment name (e.g., uat, prod)
  --department      Department tag (e.g., IT)
  --config          Path to manifest YAML (default: manifest.yml)
  --tag             Docker image tag (default: git short SHA)
  --vpc-id          VPC ID (env-init)
  --private-subnets Comma-separated private subnet IDs (env-init)
  --cert-arn        ACM certificate ARN (env-init)
  --service         Service name (add-repo)
  --name            Secret name (secret-init)
  --value           Secret value (secret-init)
  --region          AWS region (default: ap-south-1)

EXAMPLES:
  ./deploy.sh app-init --app myapp --department IT
  ./deploy.sh env-init --app myapp --env uat --department IT \
    --vpc-id vpc-xxx --private-subnets subnet-a,subnet-b --cert-arn arn:aws:acm:...
  ./deploy.sh add-repo --app myapp --service order-service --department IT
  ./deploy.sh svc-deploy --config manifest.yml --env uat
  ./deploy.sh svc-deploy --config manifest.yml --env uat --tag v1.2.3
  ./deploy.sh secret-init --app myapp --env uat --name DB_PASSWORD --value "xxx" --department IT
EOF
  exit 1
}

#######################################################################
# YAML Parser Helpers (lightweight, no external deps)
# For complex configs, install yq: pip install yq
#######################################################################
yaml_get() {
  local file="$1" key="$2"
  grep "^${key}:" "$file" 2>/dev/null | head -1 | sed "s/^${key}:[[:space:]]*//" | sed 's/^"//' | sed 's/"$//' | xargs || echo ""
}

yaml_get_nested() {
  local file="$1" parent="$2" child="$3"
  awk -v parent="$parent" -v child="$child" '
    BEGIN { in_parent=0; indent=0 }
    {
      # Calculate current indentation
      match($0, /^[[:space:]]*/);
      cur_indent = RLENGTH;
    }
    $0 ~ "^"parent":" || $0 ~ "^  "parent":" {
      in_parent=1;
      indent=cur_indent;
      next
    }
    in_parent && cur_indent <= indent && NF > 0 && $0 !~ /^[[:space:]]*#/ {
      in_parent=0
    }
    in_parent && $0 ~ child":" {
      sub(/.*"child":[[:space:]]*/, "")
      sub(/^[[:space:]]*[a-zA-Z_]+:[[:space:]]*/, "")
      gsub(/"/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      print
      exit
    }
  ' "$file"
}

yaml_get_env_value() {
  local file="$1" env="$2" key="$3"
  awk -v env="$env" -v key="$key" '
    BEGIN { in_envs=0; in_env=0 }
    /^environments:/ { in_envs=1; next }
    in_envs && $0 ~ "^  "env":" { in_env=1; next }
    in_env && /^  [a-zA-Z]/ && $0 !~ "^    " { in_env=0 }
    in_env && $0 ~ "^    "key":" {
      sub(/^    [^:]+:[[:space:]]*/, "")
      gsub(/"/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      print
      exit
    }
  ' "$file"
}

yaml_get_env_map() {
  local file="$1" env="$2" section="$3"
  awk -v env="$env" -v section="$section" '
    BEGIN { in_envs=0; in_env=0; in_section=0 }
    /^environments:/ { in_envs=1; next }
    in_envs && $0 ~ "^  "env":" { in_env=1; next }
    in_env && /^  [a-zA-Z]/ && $0 !~ "^    " { in_env=0; in_section=0 }
    in_env && $0 ~ "^    "section":" { in_section=1; next }
    in_section && /^    [a-zA-Z]/ && $0 !~ "^      " { in_section=0 }
    in_section && /^      [a-zA-Z_]/ {
      line = $0
      gsub(/^[[:space:]]+/, "", line)
      # Split on first colon
      idx = index(line, ":")
      if (idx > 0) {
        k = substr(line, 1, idx-1)
        v = substr(line, idx+1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        gsub(/"/, "", v)
        print k "=" v
      }
    }
  ' "$file"
}

#######################################################################
# Wait for CloudFormation stack to complete
#######################################################################
wait_for_stack() {
  local stack_name="$1"
  log_info "Waiting for stack ${stack_name} to complete..."
  aws cloudformation wait stack-create-complete --stack-name "$stack_name" --region "$REGION" 2>/dev/null || \
  aws cloudformation wait stack-update-complete --stack-name "$stack_name" --region "$REGION" 2>/dev/null || true
}

#######################################################################
# Command: app-init
#######################################################################
cmd_app_init() {
  local app="" department=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app) app="$2"; shift 2 ;;
      --department) department="$2"; shift 2 ;;
      --region) REGION="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -z "$app" ]] && { log_error "--app is required"; exit 1; }
  [[ -z "$department" ]] && { log_error "--department is required"; exit 1; }

  local stack_name="${app}-infrastructure"
  log_info "Deploying app infrastructure: ${stack_name}"

  aws cloudformation deploy \
    --template-file "${TEMPLATES_DIR}/app-infrastructure.yml" \
    --stack-name "$stack_name" \
    --parameter-overrides \
      AppName="$app" \
      Department="$department" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$REGION" \
    --tags "app=${app}" "Department=${department}" \
    --no-fail-on-empty-changeset

  log_ok "App infrastructure deployed: ${stack_name}"
  echo ""
  log_info "Outputs:"
  aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" \
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table
}

#######################################################################
# Command: env-init
#######################################################################
cmd_env_init() {
  local app="" env="" department="" vpc_id="" subnets="" cert_arn=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app) app="$2"; shift 2 ;;
      --env) env="$2"; shift 2 ;;
      --department) department="$2"; shift 2 ;;
      --vpc-id) vpc_id="$2"; shift 2 ;;
      --private-subnets) subnets="$2"; shift 2 ;;
      --cert-arn) cert_arn="$2"; shift 2 ;;
      --region) REGION="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -z "$app" ]] && { log_error "--app is required"; exit 1; }
  [[ -z "$env" ]] && { log_error "--env is required"; exit 1; }
  [[ -z "$department" ]] && { log_error "--department is required"; exit 1; }
  [[ -z "$vpc_id" ]] && { log_error "--vpc-id is required"; exit 1; }
  [[ -z "$subnets" ]] && { log_error "--private-subnets is required"; exit 1; }
  [[ -z "$cert_arn" ]] && { log_error "--cert-arn is required"; exit 1; }

  local stack_name="${app}-${env}"
  log_info "Deploying environment: ${stack_name}"

  aws cloudformation deploy \
    --template-file "${TEMPLATES_DIR}/environment.yml" \
    --stack-name "$stack_name" \
    --parameter-overrides \
      AppName="$app" \
      EnvName="$env" \
      Department="$department" \
      VpcId="$vpc_id" \
      PrivateSubnetIds="$subnets" \
      CertificateArn="$cert_arn" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$REGION" \
    --tags "app=${app}" "environment=${env}" "Department=${department}" \
    --no-fail-on-empty-changeset

  log_ok "Environment deployed: ${stack_name}"
  echo ""
  log_info "Internal ALB DNS (share with network team):"
  aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`InternalLoadBalancerDNS`].OutputValue' --output text
}

#######################################################################
# Command: add-repo
#######################################################################
cmd_add_repo() {
  local app="" service="" department=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app) app="$2"; shift 2 ;;
      --service) service="$2"; shift 2 ;;
      --department) department="$2"; shift 2 ;;
      --region) REGION="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -z "$app" ]] && { log_error "--app is required"; exit 1; }
  [[ -z "$service" ]] && { log_error "--service is required"; exit 1; }
  [[ -z "$department" ]] && { log_error "--department is required"; exit 1; }

  local stack_name="${app}-ecr-${service}"
  log_info "Creating ECR repository: ${app}/${service}"

  aws cloudformation deploy \
    --template-file "${TEMPLATES_DIR}/ecr-repository.yml" \
    --stack-name "$stack_name" \
    --parameter-overrides \
      AppName="$app" \
      ServiceName="$service" \
      Department="$department" \
    --region "$REGION" \
    --tags "app=${app}" "service=${service}" "Department=${department}" \
    --no-fail-on-empty-changeset

  log_ok "ECR repository created: ${app}/${service}"
}

#######################################################################
# Command: svc-deploy
#######################################################################
cmd_svc_deploy() {
  local config="manifest.yml" env="" tag=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) config="$2"; shift 2 ;;
      --env) env="$2"; shift 2 ;;
      --tag) tag="$2"; shift 2 ;;
      --region) REGION="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -z "$env" ]] && { log_error "--env is required"; exit 1; }
  [[ ! -f "$config" ]] && { log_error "Manifest file not found: $config (use --config to specify a different path)"; exit 1; }

  # --- Parse top-level config ---
  local app service department port path healthcheck dockerfile priority
  app=$(yaml_get "$config" "app")
  service=$(yaml_get "$config" "service")
  department=$(yaml_get "$config" "department")
  port=$(yaml_get "$config" "port")
  path=$(yaml_get "$config" "path")
  healthcheck=$(yaml_get "$config" "healthcheck")
  dockerfile=$(yaml_get "$config" "dockerfile")
  priority=$(yaml_get "$config" "listener_rule_priority")

  [[ -z "$app" ]] && { log_error "Missing 'app' in config"; exit 1; }
  [[ -z "$service" ]] && { log_error "Missing 'service' in config"; exit 1; }
  [[ -z "$department" ]] && { log_error "Missing 'department' in config"; exit 1; }

  port="${port:-3000}"
  healthcheck="${healthcheck:-/health}"
  dockerfile="${dockerfile:-Dockerfile}"
  priority="${priority:-100}"

  # --- Parse environment-specific config ---
  local alias cpu memory count deployment
  alias=$(yaml_get_env_value "$config" "$env" "alias")
  cpu=$(yaml_get_env_value "$config" "$env" "cpu")
  memory=$(yaml_get_env_value "$config" "$env" "memory")
  count=$(yaml_get_env_value "$config" "$env" "count")
  deployment=$(yaml_get_env_value "$config" "$env" "deployment")

  cpu="${cpu:-512}"
  memory="${memory:-1024}"
  count="${count:-1}"
  deployment="${deployment:-rolling}"
  [[ -z "$alias" ]] && { log_error "Missing 'alias' for env '${env}' in config"; exit 1; }

  # --- Docker image tag ---
  if [[ -z "$tag" ]]; then
    tag=$(git rev-parse --short HEAD 2>/dev/null || echo "latest")
  fi

  local account_id
  account_id=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
  local ecr_uri="${account_id}.dkr.ecr.${REGION}.amazonaws.com/${app}/${service}"
  local image_uri="${ecr_uri}:${tag}"

  echo ""
  log_info "=== Service Deploy ==="
  log_info "App:         ${app}"
  log_info "Service:     ${service}"
  log_info "Environment: ${env}"
  log_info "Department:  ${department}"
  log_info "Image:       ${image_uri}"
  log_info "CPU/Memory:  ${cpu}/${memory}"
  log_info "Count:       ${count}"
  log_info "Alias:       ${alias}"
  log_info "Path:        ${path}"
  echo ""

  # --- Step 1: Docker Build ---
  log_info "[1/4] Building Docker image..."
  docker build -t "${image_uri}" -f "$dockerfile" .
  log_ok "Docker image built"

  # --- Step 2: ECR Login & Push ---
  log_info "[2/4] Pushing to ECR..."
  aws ecr get-login-password --region "$REGION" | \
    docker login --username AWS --password-stdin "${account_id}.dkr.ecr.${REGION}.amazonaws.com"
  docker push "${image_uri}"
  log_ok "Image pushed to ECR"

  # --- Step 3: Build parameter JSON strings ---
  log_info "[3/4] Preparing parameters..."

  # Environment variables
  local env_vars_json
  env_vars_json=$(build_env_vars_json "$config" "$env" "$app" "$service")

  # Secrets
  local secrets_json
  secrets_json=$(build_secrets_json "$config" "$env")

  # Datadog config
  local enable_datadog="false" enable_firelens="false"
  local dd_api_key_ssm="" dd_site="datadoghq.com" dd_logs_host="http-intake.logs.datadoghq.com" dd_source="nodejs"

  local dd_enabled
  dd_enabled=$(yaml_get_nested "$config" "datadog" "enabled")
  if [[ "$dd_enabled" == "true" ]]; then
    enable_datadog="true"
    dd_api_key_ssm=$(yaml_get_nested "$config" "datadog" "api_key_ssm")
    dd_api_key_ssm="${dd_api_key_ssm//\$\{ENV\}/$env}"
    dd_site=$(yaml_get_nested "$config" "datadog" "site")
    dd_site="${dd_site:-datadoghq.com}"

    # Check firelens under datadog
    local fl_line
    fl_line=$(grep -A5 "firelens:" "$config" 2>/dev/null | grep "enabled:" | head -1 | awk '{print $2}' || echo "")
    if [[ "$fl_line" == "true" ]]; then
      enable_firelens="true"
      dd_logs_host=$(grep -A5 "firelens:" "$config" 2>/dev/null | grep "host:" | head -1 | awk '{print $2}' || echo "http-intake.logs.datadoghq.com")
      dd_source=$(grep -A5 "firelens:" "$config" 2>/dev/null | grep "source:" | head -1 | awk '{print $2}' || echo "nodejs")
    fi
  fi

  # --- Step 4: Deploy CloudFormation ---
  local stack_name="${app}-${env}-${service}"
  log_info "[4/4] Deploying CloudFormation stack: ${stack_name}"

  aws cloudformation deploy \
    --template-file "${TEMPLATES_DIR}/service.yml" \
    --stack-name "$stack_name" \
    --parameter-overrides \
      AppName="$app" \
      EnvName="$env" \
      ServiceName="$service" \
      Department="$department" \
      ContainerImage="$image_uri" \
      ContainerPort="$port" \
      TaskCPU="$cpu" \
      TaskMemory="$memory" \
      DesiredCount="$count" \
      HealthCheckPath="$healthcheck" \
      RulePath="$path" \
      HostAlias="$alias" \
      ListenerRulePriority="$priority" \
      DeploymentStrategy="$deployment" \
      EnableDatadogSidecar="$enable_datadog" \
      DatadogApiKeySSMParam="$dd_api_key_ssm" \
      DatadogSite="$dd_site" \
      EnableFirelensLogging="$enable_firelens" \
      DatadogLogsHost="$dd_logs_host" \
      DatadogSource="$dd_source" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$REGION" \
    --tags "app=${app}" "environment=${env}" "service=${service}" "Department=${department}" \
    --no-fail-on-empty-changeset

  echo ""
  log_ok "=== Deploy Complete ==="
  log_ok "Stack:   ${stack_name}"
  log_ok "Image:   ${image_uri}"
  log_ok "URL:     https://${alias}${path}"
  echo ""
}

#######################################################################
# Build environment variables JSON for CloudFormation
# Returns: JSON array string for --parameter-overrides
#######################################################################
build_env_vars_json() {
  local config="$1" env="$2" app="$3" service="$4"
  local json="["
  local first=true

  # Add standard variables
  json+="{\"name\":\"APP_NAME\",\"value\":\"${app}\"}"
  json+=",{\"name\":\"ENV_NAME\",\"value\":\"${env}\"}"
  json+=",{\"name\":\"SERVICE_NAME\",\"value\":\"${service}\"}"
  first=false

  # Add user-defined variables
  local vars
  vars=$(yaml_get_env_map "$config" "$env" "variables")
  if [[ -n "$vars" ]]; then
    while IFS='=' read -r key value; do
      [[ -z "$key" ]] && continue
      json+=",{\"name\":\"${key}\",\"value\":\"${value}\"}"
    done <<< "$vars"
  fi

  json+="]"
  echo "$json"
}

#######################################################################
# Build secrets JSON for CloudFormation
# Returns: JSON array string
#######################################################################
build_secrets_json() {
  local config="$1" env="$2"
  local json="["
  local first=true

  local secs
  secs=$(yaml_get_env_map "$config" "$env" "secrets")
  if [[ -n "$secs" ]]; then
    while IFS='=' read -r key value; do
      [[ -z "$key" ]] && continue
      if [[ "$first" == "true" ]]; then
        first=false
      else
        json+=","
      fi
      json+="{\"name\":\"${key}\",\"valueFrom\":\"${value}\"}"
    done <<< "$secs"
  fi

  json+="]"
  echo "$json"
}

#######################################################################
# Command: secret-init
#######################################################################
cmd_secret_init() {
  local app="" env="" name="" value="" department=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app) app="$2"; shift 2 ;;
      --env) env="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      --value) value="$2"; shift 2 ;;
      --department) department="$2"; shift 2 ;;
      --region) REGION="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -z "$app" ]] && { log_error "--app is required"; exit 1; }
  [[ -z "$env" ]] && { log_error "--env is required"; exit 1; }
  [[ -z "$name" ]] && { log_error "--name is required"; exit 1; }
  [[ -z "$value" ]] && { log_error "--value is required"; exit 1; }
  [[ -z "$department" ]] && { log_error "--department is required"; exit 1; }

  local param_name="/${app}/${env}/secrets/${name}"
  log_info "Storing secret: ${param_name}"

  # Try with tags first (new parameter), fall back to overwrite (existing)
  aws ssm put-parameter \
    --name "$param_name" \
    --value "$value" \
    --type SecureString \
    --tags "Key=app,Value=${app}" "Key=environment,Value=${env}" "Key=Department,Value=${department}" \
    --region "$REGION" 2>/dev/null || \
  aws ssm put-parameter \
    --name "$param_name" \
    --value "$value" \
    --type SecureString \
    --overwrite \
    --region "$REGION"

  log_ok "Secret stored: ${param_name}"
}

#######################################################################
# Main
#######################################################################
[[ $# -lt 1 ]] && usage

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
