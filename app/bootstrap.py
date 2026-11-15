"""Configure Open WebUI for the oikb Ops Assistant. Idempotent.

Run by the bootstrap job after Open WebUI is healthy (scripts/day0.sh), or
from a laptop against the public URL. Creates what cannot be expressed as an
environment variable, because it is data inside the application:

  1. an API key for the admin user        (used by the eval runner)
  2. the knowledge base "oikb repository" (target of the oikb sync)
  3. a registry entry for the base model  (so non-admin users may use it)
  4. the custom model "oikb Ops Assistant" = base model + system prompt
     + knowledge base + GitHub MCP server (read-only)

The model definition is re-applied on every run, so the system prompt in
assistant/system_prompt.md is the source of truth, not the Admin UI.

Standard library only. Runs as a file or through `python -c`.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE_URL = os.environ.get("OPEN_WEBUI_URL", "http://127.0.0.1:8080").rstrip("/")
ADMIN_EMAIL = os.environ["ADMIN_EMAIL"]
ADMIN_PASSWORD = os.environ["ADMIN_PASSWORD"]
CHAT_MODEL = os.environ["CHAT_MODEL"]
STATE_FILE = os.environ.get("STATE_FILE", "./runtime.env")
# The job passes the prompt itself (SYSTEM_PROMPT); a laptop run reads the file.
SYSTEM_PROMPT = os.environ.get("SYSTEM_PROMPT", "")
SYSTEM_PROMPT_FILE = os.environ.get("SYSTEM_PROMPT_FILE", "")

KB_NAME = os.environ.get("KB_NAME", "oikb repository")
KB_DESCRIPTION = (
    "Entire open-webui/oikb repository (default branch), synced by oikb every 15 minutes. "
    "Do not upload files by hand: oikb removes anything that is not in the repository."
)
MODEL_ID = "oikb-ops-assistant"
MODEL_NAME = "oikb Ops Assistant"
# "server:mcp:" + info.id of the GitHub connection. List them: GET /api/v1/tools/
MCP_TOOL_ID = os.environ.get("MCP_TOOL_ID", "server:mcp:github")

# Readable by every signed-in user (the support team); writable by the admin only.
READ_FOR_ALL = [{"principal_type": "user", "principal_id": "*", "permission": "read"}]


def log(msg: str) -> None:
    print(f"[bootstrap] {msg}", flush=True)


def api(method: str, path: str, token: str | None = None, body: dict | None = None, ok_404: bool = False):
    req = urllib.request.Request(f"{BASE_URL}{path}", method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(req, data=data, timeout=60) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        if ok_404 and exc.code in (401, 404):
            return None
        detail = exc.read().decode()[:500]
        raise RuntimeError(f"{method} {path} -> HTTP {exc.code}: {detail}") from exc


def wait_until_healthy(timeout: int = 900) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"{BASE_URL}/health", timeout=5) as resp:
                if resp.status == 200:
                    return
        except Exception:  # noqa: BLE001 - still starting
            pass
        time.sleep(5)
    raise RuntimeError("Open WebUI did not become healthy in time")


def sign_in() -> str:
    result = api("POST", "/api/v1/auths/signin", body={"email": ADMIN_EMAIL, "password": ADMIN_PASSWORD})
    return result["token"]


def ensure_api_key(token: str) -> str:
    existing = api("GET", "/api/v1/auths/api_key", token, ok_404=True)
    if existing and existing.get("api_key"):
        return existing["api_key"]
    log("creating API key")
    return api("POST", "/api/v1/auths/api_key", token)["api_key"]


def ensure_knowledge_base(token: str) -> dict:
    listing = api("GET", "/api/v1/knowledge/", token) or {}
    items = listing.get("items", listing) if isinstance(listing, dict) else listing
    for kb in items or []:
        if kb.get("name") == KB_NAME:
            return kb
    log(f"creating knowledge base '{KB_NAME}'")
    return api(
        "POST",
        "/api/v1/knowledge/create",
        token,
        {"name": KB_NAME, "description": KB_DESCRIPTION, "access_grants": READ_FOR_ALL},
    )


def upsert_model(token: str, form: dict) -> str:
    existing = api("GET", f"/api/v1/models/model?id={form['id']}", token, ok_404=True)
    if existing:
        api("POST", f"/api/v1/models/model/update?id={form['id']}", token, form)
        return "updated"
    api("POST", "/api/v1/models/create", token, form)
    return "created"


def ensure_base_model(token: str) -> None:
    """Register the Azure OpenAI deployment so that non-admin users may use it.

    Open WebUI treats a provider model without a registry entry as admin-only,
    and a custom model is only usable by someone who may also use its base
    model. Readable by all users, but hidden from the model picker: the support
    team should talk to the assistant, not to the raw model.
    """
    state = upsert_model(token, {
        "id": CHAT_MODEL,
        "base_model_id": None,
        "name": CHAT_MODEL,
        "is_active": True,
        "access_grants": READ_FOR_ALL,
        "params": {},
        "meta": {
            "description": "Azure OpenAI deployment behind the oikb Ops Assistant.",
            "hidden": True,
        },
    })
    log(f"base model '{CHAT_MODEL}' {state}")


def load_system_prompt() -> str:
    if SYSTEM_PROMPT.strip():
        return SYSTEM_PROMPT.strip()
    path = SYSTEM_PROMPT_FILE
    if not path:  # laptop run from the repository; __file__ is not set under `python -c`
        here = os.path.dirname(os.path.abspath(globals().get("__file__", "bootstrap.py")))
        path = os.path.join(here, "assistant", "system_prompt.md")
    with open(path, encoding="utf-8") as f:
        return f.read().strip()


def ensure_model(token: str, kb: dict) -> None:
    system_prompt = load_system_prompt()

    form = {
        "id": MODEL_ID,
        "base_model_id": CHAT_MODEL,
        "name": MODEL_NAME,
        "is_active": True,
        "access_grants": READ_FOR_ALL,
        "params": {
            "system": system_prompt,
            # Native tool calling: the model itself decides when to search the
            # knowledge base and when to call GitHub, over several rounds.
            "function_calling": "native",
        },
        "meta": {
            "description": (
                "Answers questions about configuring and running oikb from the current "
                "open-webui/oikb repository, and flags known bugs and recent changes via GitHub (read-only)."
            ),
            "knowledge": [
                {
                    "id": kb["id"],
                    "type": "collection",
                    "name": kb.get("name", KB_NAME),
                    "description": kb.get("description", KB_DESCRIPTION),
                }
            ],
            "toolIds": [MCP_TOOL_ID],
            # Least privilege inside the Hub as well: by default a model also
            # gets built-in tools to write notes, create tools, skills,
            # automations and calendar entries. A support assistant needs
            # none of them: knowledge tools and the current date only.
            "builtinTools": {
                "knowledge": True,
                "time": True,
                "automations": False,
                "calendar": False,
                "channels": False,
                "chats": False,
                "code_interpreter": False,
                "files": False,
                "image_generation": False,
                "memory": False,
                "notes": False,
                "notifications": False,
                "skills": False,
                "subagents": False,
                "tasks": False,
                "tools": False,
                "user_input": False,
                "web_search": False,
            },
            "capabilities": {
                "builtin_tools": True,  # knowledge search / grep / view
                "citations": True,
                "file_upload": False,
                "web_search": False,
                "image_generation": False,
                "code_interpreter": False,
                "vision": False,
            },
            "suggestion_prompts": [
                {"content": "Where in the code are the oikb commands defined?"},
                {"content": "Where in the code are GitHub webhooks processed?"},
                {"content": "Which connectors does oikb currently provide?"},
            ],
            "tags": [{"name": "support"}, {"name": "oikb"}],
        },
    }

    log(f"model '{MODEL_NAME}' {upsert_model(token, form)}")

    # Open WebUI serves chats from an in-memory model list that is rebuilt
    # when models are listed. Without this, API callers would keep getting
    # the previous definition until someone opens the UI.
    listed = api("GET", "/api/models", token) or {}
    ids = [m.get("id") for m in listed.get("data", [])]
    for required in (CHAT_MODEL, MODEL_ID):
        if required not in ids:
            raise RuntimeError(f"model '{required}' is not served by Open WebUI (served: {ids})")


def write_state(api_key: str, kb_id: str) -> None:
    tmp = f"{STATE_FILE}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(f"OPEN_WEBUI_API_KEY={api_key}\nKB_ID={kb_id}\n")
    os.replace(tmp, STATE_FILE)


def main() -> int:
    wait_until_healthy()
    token = sign_in()
    api_key = ensure_api_key(token)
    kb = ensure_knowledge_base(token)
    ensure_base_model(token)
    ensure_model(token, kb)
    write_state(api_key, kb["id"])
    log(f"ready: knowledge base {kb['id']}, model {MODEL_ID}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001
        log(f"FAILED: {exc}")
        sys.exit(1)
