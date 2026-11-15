# Decision record: oikb Ops Assistant

## 1. Freshness

- **Question:** How fresh is fresh enough? What triggers the sync, and where does it run?
- **Options:** GitHub webhook; a GitHub Action in the repository; scheduled polling; no copy, everything live through MCP.
- **Chosen:** fresh enough = at most **15 minutes** behind `main`; 45 minutes is an incident. A **schedule** triggers the sync: a Container Apps job runs `oikb sync` every 15 minutes, **in the same Container Apps environment as Open WebUI**, as its own short-lived container. oikb compares checksums, so most runs upload nothing. Bugs and recent changes do not wait for the sync: the assistant reads issues, pull requests and commits live through MCP.
- **Trade-off:** up to 15 minutes of lag. Webhook and Action are not possible: `open-webui/oikb` is not our repository.
- **Would change my mind:** a repository the OpCo owns. Then webhook first, the schedule kept as the safety net.

## 2. Access scope

- **Question:** Which credentials and permissions does the MCP connection get, and how do you meet the security requirement?
- **Options:** one shared read-only PAT; a GitHub App; per-user OAuth; anonymous.
- **Target design:** credentials follow who is asking.
  - **Machines** (the knowledge base sync, automated tests): a **read-only GitHub App**. Nobody is present to sign in, and an App is not tied to a person: each run gets a fresh installation token that expires after one hour.
  - **People** (support engineers asking the assistant): **OAuth 2.1**. Each user signs in to GitHub once, and the assistant reads with that user's own permissions, so it never shows anyone more than they could see themselves, and GitHub's audit log shows who asked.
- **Deployed, for lack of time:** one **fine-grained PAT** with a single permission, read public repositories, for both paths. It is stored in Key Vault, never in code. The App and OAuth paths are implemented in the code (`github_app_*` variables) but not switched on.
- **How "nothing may write" is met**, in both designs:
  1. GitHub's read-only MCP endpoint offers no write tools.
  2. Only three tool groups are enabled: repositories, issues, pull requests.
  3. The credential itself cannot write: the PAT has no write permission; an App declares none, and an OAuth user token can never exceed the App's permissions.

  Number 3 is the real guarantee: GitHub rejects a write even if 1 and 2 were misconfigured. The connection is defined in the repository, so anyone can verify it. Automation signs in to Open WebUI as ordinary user accounts, not the admin.
- **Trade-off of the shortcut:** the PAT belongs to one person, expires, and GitHub's audit log cannot tell users apart. Acceptable here only because the repository is public: the token shows nothing a user could not see anyway.
- **Would change my mind:** this is a shortcut, not a choice. With private repositories, or as soon as there is time, switch to the target design.


## 3. Failure detection

- **Question:** How does the admin learn the sync is broken before the support team notices?
- **Options:** oikb's `notify` webhook; alert on job failures; alert on the absence of a success; an external probe.
- **Chosen:** alert on absence. The sync job prints `OIKB_SYNC_OK` only if `oikb sync` exits 0 **and** a following `oikb diff` finds nothing left to change. Azure Monitor **e-mails the admin** when that line has not appeared for 45 minutes (three missed runs). A second check requests `/health` from three regions. The diff matters: on the first deployment oikb reported "82 added" and exited 0, while 17 of those files had not been indexed. The check caught it; the next runs retried them.
- **Trade-off:** a stall is reported after 45 to 60 minutes, and one failed run does not alert, on purpose.
- **Would change my mind:** existing on-call tooling; then I would route into it.

## 4. Scope

- **Question:** Something will not fit into the time available. What do you leave out, and why that?
- **Left out:** private networking (PostgreSQL and Azure OpenAI use public endpoints with TLS); SSO; Redis and more than one replica; a staging stage; Application Gateway and WAF; remote Terraform state; an implemented eval suite (`EVAL.md` is a proposal; only the freshness check is built).
- **Why these:** none of them decides whether the four requirements are met, and each can be added later without redoing what exists. Not cut: infrastructure as code for everything, the read-only guarantee, failure detection, and no state on a container's disk.
- **Built beyond the brief:** Container Apps instead of a single VM or a plain `docker run`, PostgreSQL + pgvector and Blob Storage instead of files on a disk, and Terraform split into a shared platform layer and a per-OpCo layer. Reason: on a file share, two replicas during a revision switch can corrupt SQLite, and the split makes a second OpCo a tfvars file.
- **Deviation:** PostgreSQL runs in `<region>`, not in Sweden Central with the rest, because the trial subscription was not allowed to create a server there. In production, app and database share a region.
- **Trade-off:** day 0 is a seven-step script (three applies, four jobs, one setup step against the running instance) instead of one command, because the database and the service accounts must exist before the app and the sync can use them. The shared PostgreSQL server is one failure domain with whole-server restore only.
- **Would change my mind:** production use. Order: private endpoints and SSO, then staging with the proposed eval as the release gate.