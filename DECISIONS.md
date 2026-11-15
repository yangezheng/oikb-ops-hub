# Decision record: oikb Ops Assistant

## 1. Freshness

- **Options:** GitHub webhook; a GitHub Action in the repository; scheduled polling; no copy, everything live through MCP.
- **Chosen:** a Container Apps job runs `oikb sync` every **15 minutes**. Fresh enough = at most 15 minutes behind `main`; 45 minutes is an incident. oikb compares checksums, so most runs upload nothing. Bugs and recent changes do not wait for the sync: the assistant reads issues, pull requests and commits live through MCP.
- **Trade-off:** up to 15 minutes of lag. Webhook and Action are not possible: `open-webui/oikb` is not our repository.
- **Would change my mind:** a repository the OpCo owns. Then webhook first, the schedule kept as the safety net.

## 2. Access scope

- **Options:** one shared PAT; a GitHub App for everything; an App for the sync plus per-user OAuth for the assistant; anonymous.
- **Chosen:** one **GitHub App with read-only permissions** (contents, issues, pull requests). The sync job mints a 1-hour installation token per run. The MCP connection is OAuth 2.1 with the App's credentials, so each support engineer reads GitHub **with their own identity**: the assistant sees what that person may see, and GitHub's audit log shows who asked. Read-only holds three times: the `/readonly` MCP endpoint registers no write tools; toolsets are limited to `repos,issues,pull_requests`; and the App declares no write permission, while a user token is the intersection of App and user permissions. The last is the control. Secrets stay in Key Vault; the assistant's built-in tools are cut to knowledge search and the date.
- **Trade-off:** every user authorises once. Unattended runs cannot, so the eval account alone gets a second connection with a read-only PAT; the eval therefore does not exercise the OAuth path itself. Day 0 needs a third apply, because Open WebUI must build its own encrypted OAuth client record. Automation runs as ordinary service accounts (sync may write one knowledge base), never as admin. A shared PAT would be simpler and, for a public repository, grants nothing a user could not see anyway; it remains the fallback.
- **Would change my mind:** users without GitHub accounts, or one repository with identical access for everyone: then the shared read-only token.

## 3. Failure detection

- **Options:** oikb's `notify` webhook; alert on job failures; alert on the absence of a success; an external probe.
- **Chosen:** alert on absence. The sync job prints `OIKB_SYNC_OK` only if `oikb sync` exits 0 **and** a following `oikb diff` finds nothing left to change. Azure Monitor **e-mails the admin** when that line has not appeared for 45 minutes (three missed runs). A second check requests `/health` from three regions. The diff matters: in testing, with the embedding model unreachable, oikb reported "76 added" and exited 0 while the knowledge base was empty.
- **Trade-off:** a stall is reported after 45 to 60 minutes, and one failed run does not alert, on purpose.
- **Would change my mind:** existing on-call tooling; then I would route into it.

## 4. Scope

- **Built beyond the brief:** Container Apps instead of a VM, PostgreSQL + pgvector and Blob Storage instead of files on a disk, and Terraform split into a shared platform layer and a per-OpCo layer. Reason: on a file share, two replicas during a revision switch can corrupt SQLite, and the split makes a second OpCo a tfvars file.
- **Left out:** private networking (PostgreSQL and Azure OpenAI use public endpoints with TLS); SSO; Redis and more than one replica; a staging stage; Application Gateway and WAF; remote Terraform state; a prompt-injection test with planted content.
- **Trade-off:** day 0 is two applies and four jobs instead of one command, and the shared PostgreSQL server is one failure domain with whole-server restore only.
- **Would change my mind:** production use. Order: private endpoints and SSO, then staging with the eval suite as the release gate.
