# oikb Ops Hub

Open WebUI on Azure Container Apps with an **oikb Ops Assistant**: it answers support questions from the current state of [`open-webui/oikb`](https://github.com/open-webui/oikb), checks issues, pull requests and commits through the official GitHub MCP server (read-only), and e-mails the admin when the knowledge base falls behind.

Everything is created with Terraform and one setup script. Nothing is clicked together.

- Decisions: [`DECISIONS.md`](DECISIONS.md)
- Eval proposal: [`EVAL.md`](EVAL.md)

## Architecture

```
rg-aihub-platform (shared)                 rg-aihub-opco1 (one per OpCo)
  Container Apps environment  <── runs ──    Open WebUI (1 replica)   <── HTTPS ── users
  Azure OpenAI (chat, embeddings)            Job: oikb sync, every 15 min
  PostgreSQL + pgvector  <── data ───────    Jobs: db-init, migrate, bootstrap
  Log Analytics, alerts                      Key Vault, Blob Storage, managed identity

GitHub: repository (read by the sync), MCP server /readonly (used by the assistant)
```

No state lives in a container: data and vectors in PostgreSQL, uploaded files in Blob Storage. A second OpCo is a second tfvars file.

## Layout

```
infra/platform/   shared resources
infra/instance/   one OpCo
infra/tfstate/    optional: remote state storage
app/              scripts run by the jobs, system prompt
scripts/day0.sh   first deployment of an OpCo
```

## Deploy

Needs Terraform ≥ 1.9, Azure CLI (`az login`), Python 3, and a GitHub fine-grained token with "Public repositories (read-only)" and no other permissions.

```bash
# 1. Shared platform
cd infra/platform
cp terraform.tfvars.example terraform.tfvars   # subscription_id, alert_email
terraform init && terraform apply

# 2. One OpCo
cd ../instance
cp opco1.tfvars.example opco1.tfvars           # subscription_id, admin_email
export TF_VAR_github_token=github_pat_...
cd ../..
scripts/day0.sh infra/instance/opco1.tfvars
```

`day0.sh` runs seven idempotent steps: infrastructure, database setup, schema migration, the app, knowledge base and assistant, service accounts, first sync. If a step fails, fix it and run the script again.

## Use

```bash
cd infra/instance
terraform output url
terraform output -raw admin_password
```

Log in with `admin_email`, pick **oikb Ops Assistant**. Users get ordinary accounts (Admin Panel → Users); sign-up is off.

Later applies: `terraform apply -var-file=opco1.tfvars -var-file=opco1.runtime.tfvars`.

## Notes

- PostgreSQL runs in `francecentral`: the trial subscription could not create it in Sweden Central.
- Settings come from environment variables (`ENABLE_PERSISTENT_CONFIG=false`); changes in the Admin UI are lost on restart.

## Teardown

```bash
cd infra/instance && terraform destroy -var-file=opco1.tfvars -var-file=opco1.runtime.tfvars
cd ../platform && terraform destroy
```