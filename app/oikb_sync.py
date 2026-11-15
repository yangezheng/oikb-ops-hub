"""One sync run: repository -> knowledge base. Run by the scheduled sync job.

Wraps `oikb sync` so that the job needs no stored API key and no knowledge
base id: it signs in, looks the knowledge base up by name, and hands oikb a
short-lived token. Nothing has to be passed from the bootstrap job to this one.

The last line is the contract with monitoring (infra/instance/monitoring.tf):

  OIKB_SYNC_OK instance=<id> ...      printed only when BOTH hold:
                                        1. `oikb sync` exits 0
                                        2. a following `oikb diff` finds nothing
                                           left to add, change or delete

Check 2 exists because check 1 is not enough: Open WebUI processes uploads
after it has accepted them. If embedding fails (model quota, wrong key), oikb
has already reported "76 added" and exited 0, while the knowledge base is
empty. The diff asks the question that matters: is the knowledge base equal
to the repository right now?

Azure Monitor alerts when that line has NOT appeared for 45 minutes. So a run
that crashes, hangs, cannot log in or is never scheduled needs no error
handling here: silence is the signal.

GitHub credentials, in this order:
  1. GitHub App (GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY):
     a read-only installation token is minted for this run and expires after
     one hour. Nothing long-lived reaches oikb.
  2. GITHUB_TOKEN: a fine-grained read-only PAT.

Runs with the Python inside the oikb image, which ships PyJWT and cryptography.
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

BASE_URL = os.environ["OPEN_WEBUI_URL"].rstrip("/")
# An ordinary account with write access to this knowledge base, not the admin.
# (ADMIN_* still works for a laptop run before the service account exists.)
SYNC_EMAIL = os.environ.get("SYNC_EMAIL") or os.environ["ADMIN_EMAIL"]
SYNC_PASSWORD = os.environ.get("SYNC_PASSWORD") or os.environ["ADMIN_PASSWORD"]
KB_NAME = os.environ.get("KB_NAME", "oikb repository")
SYNC_SOURCE = os.environ.get("SYNC_SOURCE", "github:open-webui/oikb")
INSTANCE = os.environ.get("INSTANCE", "local")
PROCESSING_TIMEOUT = int(os.environ.get("PROCESSING_TIMEOUT", "300"))
GITHUB_API = "https://api.github.com"

DRIFT = re.compile(r"\b(\d+) (added|modified|deleted)\b")


def log(message: str) -> None:
    print(f"[sync] {message}", flush=True)


def api(method: str, path: str, token: str | None = None, body: dict | None = None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(f"{BASE_URL}{path}", data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"{method} {path} -> HTTP {exc.code}: {exc.read().decode()[:300]}") from exc


def unset(value: str | None) -> bool:
    return not value or value == "none"


def github_app_jwt(app_id: str, private_key: str, now: int | None = None) -> str:
    """The short-lived JWT a GitHub App signs to ask for an installation token."""
    import jwt  # PyJWT, shipped in the oikb image

    now = int(now if now is not None else time.time())
    payload = {"iat": now - 60, "exp": now + 540, "iss": str(app_id)}  # GitHub allows at most 10 minutes
    return jwt.encode(payload, private_key, algorithm="RS256")


def github_app_token(app_id: str, installation_id: str, private_key: str) -> str:
    """Installation token limited to reading contents, issues and pull requests."""
    body = {"permissions": {"contents": "read", "metadata": "read"}}
    req = urllib.request.Request(
        f"{GITHUB_API}/app/installations/{installation_id}/access_tokens",
        data=json.dumps(body).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {github_app_jwt(app_id, private_key)}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())["token"]
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"GitHub App token: HTTP {exc.code}: {exc.read().decode()[:300]}") from exc


def github_credentials() -> tuple[str | None, str]:
    """(token, how) for the oikb subprocess."""
    app_id = os.environ.get("GITHUB_APP_ID")
    installation_id = os.environ.get("GITHUB_APP_INSTALLATION_ID")
    private_key = os.environ.get("GITHUB_APP_PRIVATE_KEY")
    if not (unset(app_id) or unset(installation_id) or unset(private_key)):
        return github_app_token(app_id, installation_id, private_key), "github-app"
    token = os.environ.get("GITHUB_TOKEN")
    if not unset(token):
        return token, "pat"
    return None, "anonymous"


def find_knowledge_base(listing, name: str) -> str | None:
    """The list endpoint returns either a list or {"items": [...]}."""
    items = listing.get("items", []) if isinstance(listing, dict) else (listing or [])
    for kb in items:
        if kb.get("name") == name:
            return kb.get("id")
    return None


def main() -> int:
    started = time.time()
    token = api("POST", "/api/v1/auths/signin", body={"email": SYNC_EMAIL, "password": SYNC_PASSWORD})["token"]

    kb_id = find_knowledge_base(api("GET", "/api/v1/knowledge/", token), KB_NAME)
    if not kb_id:
        raise RuntimeError(f"knowledge base '{KB_NAME}' not found: run the bootstrap job first")

    github_token, how = github_credentials()
    log(f"syncing {SYNC_SOURCE} -> knowledge base {kb_id} (GitHub auth: {how})")
    env = {k: v for k, v in os.environ.items() if not k.startswith("GITHUB_APP_")}
    env.update(OPEN_WEBUI_URL=BASE_URL, OPEN_WEBUI_API_KEY=token)
    env.pop("GITHUB_TOKEN", None)
    if github_token:
        env["GITHUB_TOKEN"] = github_token
    sync = subprocess.run(["oikb", "sync", SYNC_SOURCE, "--kb-id", kb_id], env=env, check=False)
    if sync.returncode != 0:
        return fail(f"exit={sync.returncode}", started)

    wait_for_processing(token, kb_id)

    diff = subprocess.run(
        ["oikb", "diff", SYNC_SOURCE, "--kb-id", kb_id], env=env, check=False, capture_output=True, text=True
    )
    summary = last_line(diff.stdout)
    if diff.returncode != 0:
        return fail(f"diff_exit={diff.returncode} {last_line(diff.stderr)}", started)
    if pending_changes(summary):
        return fail(f'drift="{summary}" (uploads accepted but not in the knowledge base: check embedding errors)', started)

    seconds = round(time.time() - started)
    log(f'OIKB_SYNC_OK instance={INSTANCE} source={SYNC_SOURCE} kb={kb_id} state="{summary}" seconds={seconds}')
    return 0


def fail(reason: str, started: float) -> int:
    log(f"OIKB_SYNC_FAILED instance={INSTANCE} source={SYNC_SOURCE} {reason} seconds={round(time.time() - started)}")
    return 1


def last_line(text: str) -> str:
    lines = [line.strip() for line in (text or "").splitlines() if line.strip()]
    return lines[-1] if lines else ""


def pending_changes(summary: str) -> bool:
    """True if oikb's diff summary still lists files to add, change or delete.

    In sync looks like "76 unchanged" or "nothing to do".
    """
    return bool(DRIFT.search(summary))


def wait_for_processing(token: str, kb_id: str) -> None:
    """Open WebUI extracts and embeds uploads in the background."""
    deadline = time.time() + PROCESSING_TIMEOUT
    while time.time() < deadline:
        try:
            pending = api("GET", f"/api/v1/knowledge/{kb_id}/files/pending", token)
        except RuntimeError:
            return  # endpoint not available: the diff below decides
        if not pending:
            return
        time.sleep(5)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001
        log(f"OIKB_SYNC_FAILED instance={INSTANCE} error={exc}")
        sys.exit(1)
