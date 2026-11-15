#!/usr/bin/env bash
# Day 0 for one OpCo: from an applied platform layer to a working assistant.
#
#   scripts/day0.sh infra/instance/opco1.tfvars
#
# Order matters, and it is the same order as an upgrade (see README):
#   1. apply without the app   database, secrets, storage, jobs exist
#   2. db-init job             login role, REVOKE CONNECT FROM PUBLIC, vector extension
#   3. migrate job             Open WebUI schema
#   4. apply with the app      first replica starts against a ready database
#   5. bootstrap job           knowledge base + "oikb Ops Assistant"
#   6. sync job                first sync, so the heartbeat alert starts green
#   7. GitHub App only:        Open WebUI builds its OAuth client record for the
#                              MCP connection; a third apply puts it in place
#
# Every step is idempotent; the script can be re-run after a failure.
# Needs: terraform, az (logged in), curl, python3.
set -euo pipefail

VARS="${1:?usage: scripts/day0.sh <path to the OpCo tfvars file>}"
VARS="$(cd "$(dirname "$VARS")" && pwd)/$(basename "$VARS")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPCO="$(basename "$VARS" .tfvars)"
# Written in step 7 when a GitHub App is used; passed to every apply after that.
OAUTH_VARS="$(dirname "$VARS")/$OPCO.mcp-oauth.tfvars"
var_files() {
  echo "-var-file=$VARS"
  if [[ -f "$OAUTH_VARS" ]]; then echo "-var-file=$OAUTH_VARS"; fi
}

cd "$ROOT/infra/instance"
terraform init -input=false
# One state per OpCo: a change to this OpCo cannot touch another one.
terraform workspace select -or-create "$OPCO"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
out() { terraform output -raw "$1"; }
job() { terraform output -json jobs | python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }

run_job() {
  local name="$1" timeout="${2:-1800}" rg execution status waited=0
  rg="$(out resource_group_name)"
  execution="$(az containerapp job start --name "$name" --resource-group "$rg" --query name -o tsv)"
  echo "started $execution"
  while :; do
    status="$(az containerapp job execution show --name "$name" --resource-group "$rg" \
      --job-execution-name "$execution" --query properties.status -o tsv 2>/dev/null || echo Unknown)"
    case "$status" in
      Succeeded) echo "$name: Succeeded"; return 0 ;;
      Failed | Degraded | Stopped)
        echo "$name: $status. Logs:" >&2
        echo "  az containerapp job logs show --name $name --resource-group $rg --execution $execution --container \$(az containerapp job show -n $name -g $rg --query 'properties.template.containers[0].name' -o tsv)" >&2
        return 1 ;;
    esac
    ((waited += 10))
    if ((waited > timeout)); then echo "$name: timed out after ${timeout}s" >&2; return 1; fi
    sleep 10
  done
}

step "1/7 apply without the app"
# shellcheck disable=SC2046
terraform apply -input=false $(var_files) -var deploy_app=false

step "2/7 db-init"
run_job "$(job db_init)" 600

step "3/7 migrate"
run_job "$(job migrate)" 2400

step "4/7 apply with the app"
# shellcheck disable=SC2046
terraform apply -input=false $(var_files)

URL="$(out url)"
echo "waiting for $URL/health"
for _ in $(seq 1 90); do
  curl -fsS "$URL/health" >/dev/null 2>&1 && break
  sleep 10
done
curl -fsS "$URL/health" >/dev/null || { echo "Open WebUI did not become healthy" >&2; exit 1; }

step "5/7 bootstrap"
run_job "$(job bootstrap)" 1500

step "6/7 first sync"
run_job "$(job sync)" 1200

step "7/7 per-user GitHub access (GitHub App only)"
if [[ -z "${TF_VAR_github_app_client_secret:-}" ]]; then
  echo "no GitHub App client secret in the environment: MCP uses the shared token, nothing to do"
elif [[ -f "$OAUTH_VARS" ]]; then
  echo "$OAUTH_VARS exists: OAuth client already registered"
else
  OPEN_WEBUI_URL="$URL" ADMIN_EMAIL="$(out admin_email)" ADMIN_PASSWORD="$(out admin_password)" \
  GITHUB_APP_CLIENT_SECRET="$TF_VAR_github_app_client_secret" \
    python3 "$ROOT/app/register_mcp_oauth.py" "$OAUTH_VARS"
  # shellcheck disable=SC2046
  terraform apply -input=false $(var_files)
  echo "Callback URL that must be set in the GitHub App: $(out github_oauth_callback_url)"
fi

step "done"
echo "URL:      $URL"
echo "Login:    $(out admin_email)"
echo "Password: terraform -chdir=infra/instance output -raw admin_password"
