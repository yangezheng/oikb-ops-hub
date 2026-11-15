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
#
# Every step is idempotent; the script can be re-run after a failure.
# Needs: terraform, az (logged in), curl, python3.
set -euo pipefail

VARS="${1:?usage: scripts/day0.sh <path to the OpCo tfvars file>}"
VARS="$(cd "$(dirname "$VARS")" && pwd)/$(basename "$VARS")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPCO="$(basename "$VARS" .tfvars)"

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

step "1/6 apply without the app"
terraform apply -input=false -var-file="$VARS" -var deploy_app=false

step "2/6 db-init"
run_job "$(job db_init)" 600

step "3/6 migrate"
run_job "$(job migrate)" 2400

step "4/6 apply with the app"
terraform apply -input=false -var-file="$VARS"

URL="$(out url)"
echo "waiting for $URL/health"
for _ in $(seq 1 90); do
  curl -fsS "$URL/health" >/dev/null 2>&1 && break
  sleep 10
done
curl -fsS "$URL/health" >/dev/null || { echo "Open WebUI did not become healthy" >&2; exit 1; }

step "5/6 bootstrap"
run_job "$(job bootstrap)" 1500

step "6/6 first sync"
run_job "$(job sync)" 1200

step "done"
echo "URL:      $URL"
echo "Login:    $(out admin_email)"
echo "Password: terraform -chdir=infra/instance output -raw admin_password"
