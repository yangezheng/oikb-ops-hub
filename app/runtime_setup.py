"""Day-0 step that needs the running instance: service accounts, knowledge
base access, and (with a GitHub App) the OAuth client record. Idempotent.

Writes the values that only Open WebUI can produce into a tfvars file, so the
next `terraform apply` can use them:

  eval_user_id                   the eval account may use the github-eval connection
  github_mcp_oauth_client_info   encrypted OAuth client record (GitHub App only)

What it does:
  1. creates two ordinary users, or resets their passwords to Terraform's:
       sync  signs in from the sync job; may WRITE the knowledge base
       eval  signs in from the eval runner; reads like any user
  2. knowledge base access: read for every user, write for the sync account
  3. GitHub App only: asks Open WebUI to build its OAuth client record for the
     MCP connection (the call the Admin UI makes when you press "Register").
     Open WebUI must do this itself: it discovers GitHub's OAuth endpoints and
     encrypts the record with its own WEBUI_SECRET_KEY.

    OPEN_WEBUI_URL ADMIN_EMAIL ADMIN_PASSWORD
    SYNC_EMAIL SYNC_PASSWORD EVAL_EMAIL EVAL_PASSWORD
    KB_NAME               (default "oikb repository")
    GITHUB_APP_CLIENT_SECRET   optional; enables step 3
    python3 app/runtime_setup.py infra/instance/opco1.runtime.tfvars

Standard library only. Run by scripts/day0.sh.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

MCP_URL = os.environ.get("MCP_URL", "https://api.githubcopilot.com/mcp/readonly")  # override only for tests
SERVER_ID = "github"  # must equal info.id of the OAuth connection in infra/instance/secrets.tf
SCOPE = "read:user"  # ignored by GitHub Apps; must equal oauth_scope in secrets.tf

BASE = os.environ["OPEN_WEBUI_URL"].rstrip("/")
KB_NAME = os.environ.get("KB_NAME", "oikb repository")


def log(message: str) -> None:
    print(f"[runtime-setup] {message}", flush=True)


def api(method: str, path: str, token: str | None = None, body: dict | None = None):
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{BASE}{path}", data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"{method} {path} -> HTTP {exc.code}: {exc.read().decode()[:400]}") from exc


def find_user(token: str, email: str) -> dict | None:
    result = api("GET", f"/api/v1/users/?query={urllib.parse.quote(email)}", token) or {}
    users = result.get("users", []) if isinstance(result, dict) else result
    return next((u for u in users if (u.get("email") or "").lower() == email.lower()), None)


def ensure_user(token: str, name: str, email: str, password: str) -> str:
    """An ordinary, active user whose password is the one in Terraform/Key Vault."""
    existing = find_user(token, email)
    if existing:
        api(
            "POST",
            f"/api/v1/users/{existing['id']}/update",
            token,
            {"role": "user", "name": name, "email": email, "password": password},
        )
        log(f"user {email} exists, password and role set")
        return existing["id"]
    created = api("POST", "/api/v1/auths/add", token, {"name": name, "email": email, "password": password, "role": "user"})
    log(f"user {email} created")
    return created["id"]


def ensure_knowledge_access(token: str, sync_user_id: str) -> str:
    listing = api("GET", "/api/v1/knowledge/", token) or {}
    items = listing.get("items", []) if isinstance(listing, dict) else listing
    kb = next((k for k in items if k.get("name") == KB_NAME), None)
    if not kb:
        raise RuntimeError(f"knowledge base '{KB_NAME}' not found: run the bootstrap job first")
    grants = [
        {"principal_type": "user", "principal_id": "*", "permission": "read"},
        {"principal_type": "user", "principal_id": sync_user_id, "permission": "write"},
    ]
    api("POST", f"/api/v1/knowledge/{kb['id']}/access/update", token, {"access_grants": grants})
    log(f"knowledge base {kb['id']}: read for all users, write for the sync account")
    return kb["id"]


def register_oauth_client(token: str, client_secret: str) -> str:
    # Same request the Admin UI sends: client_id is the connection id, and a
    # client_secret selects the static-credentials path (no dynamic registration).
    result = api(
        "POST",
        "/api/v1/configs/oauth/clients/register?type=mcp",
        token,
        {"url": MCP_URL, "client_id": SERVER_ID, "client_secret": client_secret, "oauth_scope": SCOPE},
    )
    blob = (result or {}).get("oauth_client_info")
    if not blob:
        raise RuntimeError(f"no oauth_client_info in response: {result}")
    log("OAuth client record built by Open WebUI")
    return blob


def read_tfvars(path: str) -> dict:
    values = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            m = re.match(r'\s*(\w+)\s*=\s*(".*")\s*$', line)
            if m:
                values[m.group(1)] = json.loads(m.group(2))
    return values


def write_tfvars(path: str, values: dict) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("# Written by app/runtime_setup.py: values only the running instance can produce.\n")
        f.write("# Holds the GitHub App client secret (encrypted with WEBUI_SECRET_KEY). Keep it out of Git.\n")
        for key in sorted(values):
            f.write(f"{key} = {json.dumps(values[key])}\n")


def main() -> int:
    out = sys.argv[1] if len(sys.argv) > 1 else "runtime.tfvars"
    token = api(
        "POST",
        "/api/v1/auths/signin",
        body={"email": os.environ["ADMIN_EMAIL"], "password": os.environ["ADMIN_PASSWORD"]},
    )["token"]

    sync_id = ensure_user(token, "Sync service account", os.environ["SYNC_EMAIL"], os.environ["SYNC_PASSWORD"])
    eval_id = ensure_user(token, "Eval service account", os.environ["EVAL_EMAIL"], os.environ["EVAL_PASSWORD"])
    ensure_knowledge_access(token, sync_id)

    values = read_tfvars(out)
    values["eval_user_id"] = eval_id
    secret = os.environ.get("GITHUB_APP_CLIENT_SECRET", "")
    if secret and not values.get("github_mcp_oauth_client_info"):
        # Built once: the record stays valid as long as WEBUI_SECRET_KEY does.
        # A new one on every run would roll out a new revision every time.
        values["github_mcp_oauth_client_info"] = register_oauth_client(token, secret)
    elif secret:
        log("OAuth client record already present, kept")

    write_tfvars(out, values)
    log(f"wrote {out}")
    if secret:
        log(f"callback URL to set in the GitHub App: {BASE}/oauth/clients/mcp:{SERVER_ID}/callback")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001
        log(f"FAILED: {exc}")
        sys.exit(1)
