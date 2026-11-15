# oikb Ops Hub

A vanilla Open WebUI on Azure Container Apps with an **oikb Ops Assistant** that answers support questions from the current state of [`open-webui/oikb`](https://github.com/open-webui/oikb), flags known bugs and recent changes through the official GitHub MCP server (read-only), and e-mails the platform admin when the knowledge base falls behind.

Infrastructure, Open WebUI configuration, knowledge base, custom model, sync and alerting are all code. Nothing is clicked together.

- Decisions and trade-offs: [`DECISIONS.md`](DECISIONS.md)
- How quality is evaluated: [`EVAL.md`](EVAL.md)

## How the request is met

| The admin asked for | Implementation | Where |
|---|---|---|
| Answers from the current repository | A scheduled job runs `oikb sync` on the entire repository every 15 minutes | `app/oikb_sync.py`, `infra/instance/jobs.tf` |
| "Tells us when a question touches a known bug or recent change" | Custom model with the GitHub MCP server; the system prompt requires an issue / PR / commit check and a "Heads-up" section | `app/assistant/system_prompt.md`, `app/bootstrap.py` |
| Nothing in the Hub may write to code repositories | `/readonly` MCP endpoint + read toolsets only + a GitHub App whose permissions are read-only (or a PAT without write permission) | `infra/instance/secrets.tf` |
| "I need to know when it breaks before the support team does" | Alert when no sync has *verifiably succeeded* for 45 minutes, plus an outside availability check; both e-mail the admin | `infra/instance/monitoring.tf` |

## Architecture

It starts from the official [Open WebUI guide for Azure Container Apps](https://docs.openwebui.com/deployment/azure-container-apps) (PostgreSQL + pgvector, Blob Storage, Key Vault, one replica, migrations as a job), turns it into Terraform, and splits it into what is shared and what belongs to one operating company (OpCo).

```
 rg-aihub-platform  (shared, one per stage)          rg-aihub-opco1  (one per OpCo)
 ┌──────────────────────────────────────────┐        ┌───────────────────────────────────────┐
 │ Container Apps environment  ◄────────────┼── runs ┤ Container App: Open WebUI (1 replica) │◄── HTTPS ── users
 │ Azure OpenAI: chat + embeddings ◄────────┼────────┤ Job: sync      (every 15 min)         │
 │ PostgreSQL server                        │        │ Job: db-init, migrate, bootstrap      │
 │   └─ database aihub_opco1 (+ pgvector) ◄─┼────────┤ Key Vault      (this OpCo's secrets)  │
 │ Log Analytics + alerts ──► e-mail        │        │ Blob Storage   (uploaded files)       │
 └──────────────────────────────────────────┘        │ Managed identity                      │
                                                     └───────────────────────────────────────┘
 Outside Azure:  github.com/open-webui/oikb  ◄── read ── sync job
                 api.githubcopilot.com/mcp/readonly ◄── Open WebUI (issues, PRs, commits, live)
```

No state lives in a container: rows and vectors are in PostgreSQL, uploaded files in Blob Storage. A second OpCo is a second tfvars file and a second state; it gets its own resource group, database, login role, Key Vault and storage account, and shares the rest.

## Repository layout

```
infra/
  platform/   shared: environment, Azure OpenAI, PostgreSQL server, logs, alert routing
  instance/   one OpCo: app, 4 jobs, database, Key Vault, Blob Storage, alerts
  tfstate/    optional: storage account for remote state
app/
  bootstrap.py           idempotent: API key, knowledge base, base model access, custom model
  oikb_sync.py           one sync run + check that knowledge base == repository
  db_init.py             login role, REVOKE CONNECT FROM PUBLIC, vector extension
  runtime_setup.py       day 0: service accounts, knowledge base access, OAuth client record
  assistant/             system prompt of the oikb Ops Assistant
scripts/day0.sh          first deployment of an OpCo, in the right order
evals/                   golden set and runner
tests/                   unit tests for the sync success rule
```

## Deploy

Prerequisites: Terraform ≥ 1.9, Azure CLI (`az login`), an Azure subscription with Azure OpenAI quota for the two models in `infra/platform/variables.tf`, and GitHub access: a **GitHub App** (recommended, see below) or a fine-grained personal access token with "Public repositories (read-only)" and no further permissions.

```bash
# 1. Platform (once per stage)
cd infra/platform
cp terraform.tfvars.example terraform.tfvars      # subscription_id, alert_email
terraform init && terraform apply

# 2. One OpCo
cd ../instance
cp opco1.tfvars.example opco1.tfvars              # subscription_id, admin_email, GitHub App ids
export TF_VAR_github_app_private_key="$(cat ~/Downloads/<app>.private-key.pem)"
export TF_VAR_github_app_client_secret=...
export TF_VAR_github_token=github_pat_...         # read-only; with an App only the eval account uses it
cd ../..
scripts/day0.sh infra/instance/opco1.tfvars
```

`day0.sh` does seven steps, each idempotent: apply without the app → `db-init` job → `migrate` job → apply with the app → `bootstrap` job → runtime setup and a third apply → first `sync`. The database role and schema have to exist before the first replica starts, which is why the app is created in the second apply. Azure sends one e-mail to `alert_email` to confirm the action group.

### GitHub App

One App serves both uses: the sync job reads the repository with a 1-hour installation token, and the MCP connection lets every user read GitHub with their own identity (OAuth 2.1), so the assistant only sees what that user may see.

1. **github.com → Settings → Developer settings → GitHub Apps → New GitHub App.**
   - Homepage URL: anything, for example the repository URL.
   - **Callback URL:** `https://<url>/oauth/clients/mcp:github/callback`. The URL is known after step 4 of `day0.sh` (`terraform output github_oauth_callback_url`); put a placeholder first and edit the App afterwards.
   - Leave "Expire user authorization tokens" on. Open WebUI refreshes them.
   - **Webhook:** untick "Active".
   - **Repository permissions:** Contents: *Read-only*, Issues: *Read-only*, Pull requests: *Read-only* (Metadata: *Read-only* is added automatically). Nothing else, no write permission anywhere: this is what keeps the Hub read-only.
   - Where can it be installed: "Only on this account".
2. On the App page: note the **App ID** and **Client ID**, **generate a client secret**, **generate a private key** (downloads a `.pem`).
3. **Install App** → your account → any repository. Public repositories such as `open-webui/oikb` are readable with the installation token anyway. The number at the end of the installation's URL is the **installation ID**.
4. Fill `github_app_id`, `github_app_installation_id`, `github_app_client_id` into `opco1.tfvars`; private key and client secret go in environment variables (above).

Every user, the admin included, authorises the App once: the first question that needs GitHub shows a sign-in link.

### Accounts

| Account | Role | Used by | May |
|---|---|---|---|
| `admin_email` | admin | people, for administration | everything; runs no automation after day 0 |
| `sync@<instance>.invalid` | user | the sync job | write this one knowledge base |
| `eval@<instance>.invalid` | user | the eval runner | what any user may; plus the `github-eval` connection |

The assistant carries two GitHub connections to the same read-only server: `github` (per-user OAuth, for everyone) and `github-eval` (a read-only PAT, granted to the eval account only, because an unattended run cannot sign in to GitHub). Open WebUI gives a user only the tools of connections they may use. Passwords are generated by Terraform; the sync password is in Key Vault.

Step 6 exists because some values only the running instance can produce: the service accounts' ids and the encrypted OAuth client record, which Open WebUI builds itself (it discovers GitHub's OAuth endpoints and encrypts the record with its own key). `app/runtime_setup.py` creates them through the admin API, the same calls the Admin UI makes, and writes them to `infra/instance/opco1.runtime.tfvars`; from then on, pass that file to every apply as well.

## Verify

```bash
cd infra/instance && terraform workspace select opco1
URL=$(terraform output -raw url)
curl -s $URL/health        # {"status":true}
curl -s -o /dev/null -w '%{http_code}\n' $URL/ready    # 200: database reachable
```

In the UI (login: `terraform output admin_email` / `terraform output -raw admin_password`): **Workspace → Knowledge → oikb repository** shows the repository tree; **Workspace → Models → oikb Ops Assistant** shows the prompt, the attached knowledge base and the GitHub tool; **Admin Settings → Integrations** shows the MCP connection.

Support engineers get ordinary user accounts (**Admin Panel → Users**; self sign-up is off). They see exactly one model, the assistant. Its built-in tools are limited to knowledge search and the current date.

Run the golden set:

```bash
pip install -r evals/requirements.txt
export HUB_URL=$URL HUB_EMAIL=$(terraform output -raw eval_email) HUB_PASSWORD=$(terraform output -raw eval_password)
python ../../evals/run_eval.py --keep-chats
```

Unit tests: `python -m unittest discover -s tests -v`.

## Operate

| Task | How |
|---|---|
| Change the system prompt | Edit `app/assistant/system_prompt.md`, `terraform apply`, start the `bootstrap` job |
| Change sync interval, sizes, image of oikb | Edit the variable, `terraform apply` |
| Look at the sync | `az containerapp job execution list -n job-aihub-opco1-sync -g rg-aihub-opco1 -o table`; the last log line of a run is `OIKB_SYNC_OK …` or `OIKB_SYNC_FAILED …` with the reason |
| Sync now | `az containerapp job start -n job-aihub-opco1-sync -g rg-aihub-opco1` |
| Later applies | `terraform apply -var-file=opco1.tfvars -var-file=opco1.runtime.tfvars` |
| Rotate GitHub credentials | App: new client secret or private key in the env variable, apply; a changed MCP connection rolls out a new revision by itself. PAT: same with `TF_VAR_github_token` |
| Test the alert | Set an impossible schedule or revoke the token. The mail arrives after 45 minutes without a successful sync, and a "resolved" mail follows the next good run |
| Offboard an OpCo | `terraform destroy` in its workspace. Never delete the resource group in the portal: apps removed that way can stay registered in the shared environment |

Admin settings in Open WebUI are driven by environment variables (`ENABLE_PERSISTENT_CONFIG=false`): a change made in the Admin UI is lost at the next restart. Change it in this repository instead.

### Upgrading Open WebUI

An upgrade is a release, not a restart, because a schema migration cannot be undone by rolling the image back.

1. Change `open_webui_image`. On a platform with a staging stage: apply there first and run the eval suite.
2. Deactivate the app revision; back up the database (`pg_dump`) and the blob container.
3. `terraform apply -var deploy_app=false`, then start the `migrate` job. It must succeed.
4. `terraform apply`. Verify login, a chat, the knowledge base, then run the eval suite.

## What was verified, and what was not

Verified locally against Open WebUI 0.13.3, oikb 0.6.0 and PostgreSQL 16 with pgvector: `db_init.py` (role, revoke, extension; a second role cannot connect), the migration entry point, Open WebUI running with migrations off on PostgreSQL + pgvector, `bootstrap.py` and `oikb_sync.py` started the way the jobs start them, 76 files synced into 1,238 vector rows, and the three outcomes of the sync check (embedding down → failed, up → ok, no change → ok).

Also verified locally, with a stand-in for GitHub's OAuth discovery: an Open WebUI started without the client record logs the expected error and keeps running; `runtime_setup.py` (run twice, idempotent) creates both service accounts, grants the knowledge base, and obtains the record; after a restart with it, Open WebUI redirects a user to the authorize endpoint with the App's client ID, the right callback URL and PKCE. A support user gets only the `github` connection, the eval account gets `github-eval` as well. The sync account synced 76 files but cannot read admin settings; the eval account cannot change the knowledge base. GitHub's real discovery documents were checked to have the same shape.

Not verified, because it needs an Azure subscription or a real GitHub App: `terraform validate` / `apply`, the Container Apps job definitions, Key Vault references, Blob Storage through the managed identity, the two alert rules, `day0.sh`, the GitHub App token exchange and sign-in against github.com, and the real Azure OpenAI endpoints.

## Cost and teardown

Rough order per month for one OpCo: PostgreSQL B1ms about 15 EUR, one always-on replica (1 vCPU, 2 GiB) about 60 to 70 EUR, logs, storage, Key Vault and web test a few EUR, plus Azure OpenAI usage. Check the Azure pricing calculator for your region.

```bash
cd infra/instance && terraform workspace select opco1 && terraform destroy -var-file=opco1.tfvars
cd ../platform && terraform destroy
```
