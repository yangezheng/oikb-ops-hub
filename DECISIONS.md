# Decision record: oikb Ops Assistant

## 1. Freshness

- **Options:** GitHub webhook; a GitHub Action in the repository; scheduled polling; no copy, everything live through MCP.
- **Chosen:** a Container Apps job runs `oikb sync` every **15 minutes**. Fresh enough = at most 15 minutes behind `main`; 45 minutes is an incident. oikb compares checksums, so most runs upload nothing. Bugs and recent changes do not wait for the sync: the assistant reads issues, pull requests and commits live through MCP.
- **Trade-off:** up to 15 minutes of lag. Webhook and Action are not possible: `open-webui/oikb` is not our repository.
- **Would change my mind:** a repository the OpCo owns. Then webhook first, the schedule kept as the safety net.

## 2. Access scope

- **Options:** GitHub App, fine-grained PAT, classic PAT, per-user OAuth, anonymous.
- **Chosen:** the official remote GitHub MCP server, restricted three times: (1) its `/readonly` endpoint, which registers no write tools; (2) toolsets limited to `repos,issues,pull_requests`; (3) one **fine-grained PAT, "Public repositories (read-only)", no permissions**, kept in Key Vault and read through a managed identity. (3) is the control: this token cannot write to any repository, whatever the configuration or the model does. The connection is an environment variable, so "read-only" is reviewable in Git. The assistant's built-in tools are cut down to knowledge search and the date.
- **Trade-off:** a PAT belongs to a person and expires; rotation is manual. Public issue text is untrusted input: it can cause a wrong answer, but the Hub holds nothing it could write with.
- **Would change my mind:** private OpCo repositories. Then a GitHub App installed on those repositories only, with short-lived tokens.

## 3. Failure detection

- **Options:** oikb's `notify` webhook; alert on job failures; alert on the absence of a success; an external probe.
- **Chosen:** alert on absence. The sync job prints `OIKB_SYNC_OK` only if `oikb sync` exits 0 **and** a following `oikb diff` finds nothing left to change. Azure Monitor **e-mails the admin** when that line has not appeared for 45 minutes (three missed runs). A second check requests `/health` from three regions. The diff matters: in testing, with the embedding model unreachable, oikb reported "76 added" and exited 0 while the knowledge base was empty.
- **Trade-off:** a stall is reported after 45 to 60 minutes, and one failed run does not alert, on purpose.
- **Would change my mind:** existing on-call tooling; then I would route into it.

## 4. Scope

- **Built beyond the brief:** Container Apps instead of a VM, PostgreSQL + pgvector and Blob Storage instead of files on a disk, and Terraform split into a shared platform layer and a per-OpCo layer. Reason: on a file share, two replicas during a revision switch can corrupt SQLite, and the split makes a second OpCo a tfvars file.
- **Left out:** private networking (PostgreSQL and Azure OpenAI use public endpoints with TLS); SSO; a least-privilege service account for the sync (it signs in as admin); Redis and more than one replica; a staging stage; Application Gateway and WAF; remote Terraform state; a prompt-injection test with planted content.
- **Trade-off:** day 0 is two applies and four jobs instead of one command, and the shared PostgreSQL server is one failure domain with whole-server restore only.
- **Would change my mind:** production use. Order: private endpoints and SSO, then the service account, then staging with the eval suite as the release gate.
