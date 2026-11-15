#!/usr/bin/env python3
"""Eval runner for the oikb Ops Assistant.

Asks every question in dataset.yaml through the same path a support engineer
uses (a real Open WebUI chat with the custom model, so the knowledge tools and
the GitHub MCP server run server-side), then grades the answer.

    export HUB_URL=https://<your-hub>          # terraform output -raw url
    export HUB_API_KEY=sk-...                  # Open WebUI API key (Settings > Account), or:
    export HUB_EMAIL=... HUB_PASSWORD=...      # sign in instead (terraform output -raw admin_password)
    python evals/run_eval.py                   # all cases, deterministic graders
    python evals/run_eval.py --judge           # + LLM judge against the reference answers
    python evals/run_eval.py --only code-commands,read-only --keep-chats

Exit code 0 = gate passed, 1 = gate failed, 2 = could not run.
Requires: pyyaml (pip install -r evals/requirements.txt). Everything else is stdlib.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

import yaml

HERE = Path(__file__).parent
REPO = os.environ.get("EVAL_REPO", "open-webui/oikb")
MODEL_ID = os.environ.get("EVAL_MODEL", "oikb-ops-assistant")
JUDGE_MODEL = os.environ.get("EVAL_JUDGE_MODEL", "gpt-5-mini")

# Release gate
MIN_PASS_RATE = float(os.environ.get("EVAL_MIN_PASS_RATE", "0.85"))

# Tool families, matched against the names of the tools the assistant called.
KNOWLEDGE_TOOLS = re.compile(r"knowledge|^view_file$")
WRITE_VERBS = re.compile(
    r"(^|_)(create|update|delete|add|remove|merge|push|write|fork|close|reopen|assign|request|submit|dismiss|star|unstar)(_|$)"
)


# ── HTTP helpers ─────────────────────────────────────────────────────────


def _request(method: str, url: str, headers: dict | None = None, body: dict | None = None, timeout: float = 60):
    req = urllib.request.Request(url, method=method, headers=headers or {})
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, data=data, timeout=timeout) as resp:
        raw = resp.read().decode()
    try:
        return json.loads(raw) if raw else None
    except json.JSONDecodeError:
        return raw


class Hub:
    def __init__(self, url: str, api_key: str):
        self.url = url.rstrip("/")
        self.headers = {"Authorization": f"Bearer {api_key}"}

    def call(self, method: str, path: str, body: dict | None = None, timeout: float = 60):
        return _request(method, f"{self.url}{path}", self.headers, body, timeout)

    def model_tool_ids(self, model: str) -> list[str]:
        """Tools attached to the custom model (the GitHub MCP server).

        In the browser the frontend reads them from the model and sends them as
        `tool_ids` with every message; the backend does not add them on its
        own. The eval must do the same or it would test an assistant without
        GitHub access.
        """
        if os.environ.get("EVAL_TOOL_IDS"):
            return os.environ["EVAL_TOOL_IDS"].split(",")
        try:
            info = self.call("GET", f"/api/v1/models/model?id={urllib.parse.quote(model)}") or {}
            return list((info.get("meta") or {}).get("toolIds") or [])
        except urllib.error.HTTPError:
            return ["server:mcp:github"]

    def ask(self, question: str, model: str, timeout: int, keep: bool, tool_ids: list[str] | None = None) -> dict:
        """One question through the full server-side agent loop.

        Open WebUI only executes tools server-side (knowledge tools + MCP) for
        a saved chat: create the chat, start the completion, wait for the
        background task, read the assistant message back.
        """
        user_id, assistant_id = str(uuid.uuid4()), str(uuid.uuid4())
        now = int(time.time())
        user_msg = {
            "id": user_id, "parentId": None, "childrenIds": [assistant_id],
            "role": "user", "content": question, "timestamp": now, "models": [model],
        }
        assistant_msg = {
            "id": assistant_id, "parentId": user_id, "childrenIds": [],
            "role": "assistant", "content": "", "model": model, "timestamp": now,
        }
        chat = self.call("POST", "/api/v1/chats/new", {
            "chat": {
                "title": f"[eval] {question[:60]}",
                "models": [model],
                "history": {"currentId": assistant_id, "messages": {user_id: user_msg, assistant_id: assistant_msg}},
                "messages": [user_msg, assistant_msg],
            }
        })
        chat_id = chat["id"]
        started = time.time()
        try:
            self.call("POST", "/api/chat/completions", {
                "model": model,
                "messages": [{"role": "user", "content": question}],
                "stream": True,
                "chat_id": chat_id,
                "id": assistant_id,
                "session_id": f"eval-{uuid.uuid4()}",
                "tool_ids": tool_ids or [],
                "background_tasks": {"title_generation": False, "tags_generation": False, "follow_up_generation": False},
            })
            deadline = started + timeout
            while time.time() < deadline:
                time.sleep(2)
                tasks = self.call("GET", f"/api/tasks/chat/{chat_id}") or {}
                if not tasks.get("task_ids"):
                    break
            else:
                raise TimeoutError(f"no answer within {timeout}s")
            latency = time.time() - started

            record = self.call("GET", f"/api/v1/chats/{chat_id}")
            message = record["chat"]["history"]["messages"][assistant_id]
        finally:
            if not keep:
                try:
                    self.call("DELETE", f"/api/v1/chats/{chat_id}")
                except Exception:  # noqa: BLE001 - cleanup is best effort
                    pass

        return {
            "answer": _text(message.get("content")),
            "tools": _tool_calls(message),
            "sources": _source_names(message),
            "usage": message.get("usage") or {},
            "latency_s": round(latency, 1),
            "error": message.get("error"),
        }


def _text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content if isinstance(p, dict))
    return ""


def _walk(node):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from _walk(value)
    elif isinstance(node, list):
        for item in node:
            yield from _walk(item)


def _tool_calls(message: dict) -> list[dict]:
    """Names + arguments of every tool the assistant called (from the structured output items)."""
    calls = []
    for item in _walk(message.get("output") or []):
        if item.get("type") in ("function_call", "tool_call", "mcp_call") and item.get("name"):
            calls.append({"name": item["name"], "arguments": item.get("arguments", "")})
        elif isinstance(item.get("function"), dict) and item["function"].get("name"):
            calls.append({"name": item["function"]["name"], "arguments": item["function"].get("arguments", "")})
    return calls


def _source_names(message: dict) -> list[str]:
    """Every knowledge base file the assistant retrieved or opened."""
    names: set[str] = set()
    for item in _walk(message.get("sources") or []):
        for key in ("name", "source", "filename", "title", "path"):
            value = item.get(key)
            if isinstance(value, str) and value:
                names.add(value)
    # Files opened or grepped directly show up as tool arguments / results.
    blob = json.dumps(message.get("output") or [])
    names.update(re.findall(r"[\w./-]+\.(?:py|md|toml|ya?ml)", blob))
    return sorted(names)


# ── Dynamic ground truth (computed from the live repository) ─────────────


class GitHub:
    def __init__(self, repo: str):
        self.repo = repo
        self.headers = {"Accept": "application/vnd.github+json", "User-Agent": "oikb-ops-eval"}
        if os.environ.get("GITHUB_TOKEN"):
            self.headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"

    def get(self, path: str):
        return _request("GET", f"https://api.github.com{path}", self.headers)

    def connectors(self) -> list[str]:
        tree = self.get(f"/repos/{self.repo}/git/trees/HEAD?recursive=1")["tree"]
        prefix = "src/oikb/connectors/"
        return sorted(
            Path(t["path"]).stem
            for t in tree
            if t["path"].startswith(prefix) and t["path"].endswith(".py") and not t["path"].endswith("__init__.py")
        )

    def latest_commit(self) -> dict:
        commit = self.get(f"/repos/{self.repo}/commits?per_page=1")[0]
        return {"sha": commit["sha"], "title": commit["commit"]["message"].splitlines()[0]}

    def changelog_head(self) -> dict:
        content = self.get(f"/repos/{self.repo}/contents/CHANGELOG.md")
        text = base64.b64decode(content["content"]).decode()
        match = re.search(r"^## \[?v?(\d+\.\d+\.\d+)\]?(?:\s*-\s*(\d{4}-\d{2}-\d{2}))?", text, re.M)
        return {"version": match.group(1), "date": match.group(2)} if match else {}

    def open_items(self, keyword: str) -> list[int]:
        query = urllib.parse.quote(f"repo:{self.repo} is:open {keyword}")
        return [item["number"] for item in self.get(f"/search/issues?q={query}&per_page=30")["items"]]


# Aliases people (and the README) use for connector module names.
CONNECTOR_ALIASES = {
    "azure_blob": ["azure"], "gdrive": ["google drive"], "gcs": ["google cloud storage"],
    "google_sites": ["google sites"], "oracle_storage": ["oracle"], "teams": ["microsoft teams", "teams"],
    "web": ["website", "sitemap", "crawler"], "filesystem": ["local", "directory", "directories", "filesystem"],
    "document360": ["document360"], "r2": ["r2"], "s3": ["s3"],
}


def grade_dynamic(kind: str, answer: str, gh: GitHub) -> tuple[bool, str]:
    low = answer.lower()
    if kind == "connectors":
        expected = gh.connectors()
        found = [c for c in expected if any(alias in low for alias in [c.replace("_", " "), c] + CONNECTOR_ALIASES.get(c, []))]
        recall = len(found) / len(expected)
        missing = sorted(set(expected) - set(found))
        return recall >= 0.9, f"named {len(found)}/{len(expected)} connectors at HEAD" + (f", missing: {missing}" if missing else "")
    if kind == "latest_commit":
        commit = gh.latest_commit()
        pr = re.search(r"#(\d+)", commit["title"])
        hit = commit["sha"][:7] in low or (pr and f"#{pr.group(1)}" in answer) or (pr and re.search(rf"\b{pr.group(1)}\b", answer))
        if not hit:
            words = [w for w in re.findall(r"[a-z][a-z0-9-]{4,}", commit["title"].lower()) if w not in ("merge", "request", "branch")]
            hit = bool(words) and sum(w in low for w in words) >= max(1, len(words) // 2)
        return bool(hit), f"HEAD is {commit['sha'][:7]} '{commit['title'][:70]}'"
    if kind == "changelog_head":
        head = gh.changelog_head()
        if not head:
            return False, "could not parse CHANGELOG.md at HEAD"
        ok = head["version"] in answer
        return ok, f"CHANGELOG head is {head['version']} ({head.get('date')})"
    if kind.startswith("open_issues_"):
        keyword = kind.removeprefix("open_issues_")
        numbers = gh.open_items(keyword)
        if numbers:
            hit = [n for n in numbers if re.search(rf"#?\b{n}\b", answer)]
            return bool(hit), f"{len(numbers)} open item(s) for '{keyword}' {numbers[:8]}, answer cites {hit[:8]}"
        ok = bool(re.search(r"(?i)\b(no|none|not find|n.t find|couldn.t find|did not find|0)\b", answer))
        return ok, f"no open items for '{keyword}'; answer must say so"
    return False, f"unknown dynamic check '{kind}'"


# ── Deterministic graders ────────────────────────────────────────────────


def grade_answer(spec: dict, answer: str) -> tuple[bool, str]:
    problems = []
    for pattern in spec.get("all", []):
        if not re.search(pattern, answer):
            problems.append(f"missing /{pattern}/")
    if spec.get("any") and not any(re.search(p, answer) for p in spec["any"]):
        problems.append("none of " + " | ".join(f"/{p}/" for p in spec["any"]))
    for pattern in spec.get("none", []):
        if re.search(pattern, answer):
            problems.append(f"forbidden /{pattern}/")
    if spec.get("language") == "de" and not re.search(r"\b(der|die|das|und|nicht|ist|Sie|mit|für)\b", answer):
        problems.append("answer is not in German")
    return not problems, "; ".join(problems) or "ok"


def grade_sources(expected: list[str], result: dict) -> tuple[bool, str]:
    seen = " ".join(result["sources"]).lower()
    missing = [name for name in expected if name.lower() not in seen]
    return not missing, f"not retrieved: {missing}" if missing else "ok"


def tool_families(result: dict) -> set[str]:
    families = set()
    for call in result["tools"]:
        name = call["name"]
        if KNOWLEDGE_TOOLS.search(name):
            families.add("knowledge")
        else:
            families.add("github")
            if WRITE_VERBS.search(name):
                families.add("github_write")
    return families


def grade_tools(spec: dict, result: dict) -> tuple[bool, str]:
    families = tool_families(result)
    problems = [f"did not use {f}" for f in spec.get("require", []) if f not in families]
    problems += [f"used forbidden {f}" for f in spec.get("forbid", []) if f in families]
    return not problems, "; ".join(problems) or "ok"


# ── LLM judge (optional) ─────────────────────────────────────────────────

JUDGE_PROMPT = """You grade an answer from a support assistant for the tool "oikb".

Question:
{question}

Reference answer (ground truth, written by a human):
{reference}

Assistant's answer:
{answer}

Grade on two criteria, each 0, 1 or 2:
- correctness: 2 = every claim agrees with the reference, 1 = minor deviation, 0 = contradicts it or invents facts
- completeness: 2 = covers what the reference covers, 1 = partly, 0 = misses the point

Reply with JSON only: {{"correctness": n, "completeness": n, "reason": "<one sentence>"}}"""


def judge(hub: Hub, case: dict, answer: str) -> dict:
    prompt = JUDGE_PROMPT.format(question=case["question"], reference=case["reference"].strip(), answer=answer[:6000])
    resp = hub.call("POST", "/api/chat/completions", {
        "model": JUDGE_MODEL, "stream": False, "messages": [{"role": "user", "content": prompt}],
    }, timeout=120)
    text = resp["choices"][0]["message"]["content"]
    match = re.search(r"\{.*\}", text, re.S)
    return json.loads(match.group(0)) if match else {"correctness": 0, "completeness": 0, "reason": "judge returned no JSON"}


# ── Main ─────────────────────────────────────────────────────────────────


def run_case(case: dict, hub: Hub, gh: GitHub, args) -> dict:
    out = {"id": case["id"], "category": case["category"], "must_pass": bool(case.get("must_pass")), "checks": {}}
    try:
        result = hub.ask(case["question"], MODEL_ID, args.timeout, args.keep_chats, args.tool_ids)
    except Exception as exc:  # noqa: BLE001
        out.update(passed=False, error=f"{type(exc).__name__}: {exc}")
        return out

    out.update(answer=result["answer"], tools=[c["name"] for c in result["tools"]],
               sources=result["sources"], latency_s=result["latency_s"], usage=result["usage"])
    if result.get("error") or not result["answer"].strip():
        out.update(passed=False, error=f"empty answer / model error: {result.get('error')}")
        return out

    checks = out["checks"]
    if "answer" in case:
        checks["answer"] = grade_answer(case["answer"], result["answer"])
    if "sources" in case:
        checks["sources"] = grade_sources(case["sources"], result)
    if "tools" in case:
        checks["tools"] = grade_tools(case["tools"], result)
    if "dynamic" in case:
        try:
            checks["dynamic"] = grade_dynamic(case["dynamic"], result["answer"], gh)
        except Exception as exc:  # noqa: BLE001
            checks["dynamic"] = (False, f"ground truth lookup failed: {exc}")
    if args.judge and case.get("reference"):
        try:
            verdict = judge(hub, case, result["answer"])
            checks["judge"] = (verdict.get("correctness", 0) >= 1 and verdict.get("completeness", 0) >= 1,
                               f"correctness {verdict.get('correctness')}/2, completeness {verdict.get('completeness')}/2: {verdict.get('reason')}")
        except Exception as exc:  # noqa: BLE001
            checks["judge"] = (False, f"judge failed: {exc}")

    out["passed"] = all(ok for ok, _ in checks.values())
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dataset", default=str(HERE / "dataset.yaml"))
    parser.add_argument("--only", help="comma-separated case ids")
    parser.add_argument("--judge", action="store_true", help="also grade with an LLM judge against the reference answers")
    parser.add_argument("--keep-chats", action="store_true", help="leave the eval chats in Open WebUI for inspection")
    parser.add_argument("--timeout", type=int, default=240, help="seconds to wait for one answer")
    parser.add_argument("--out", default=str(HERE / "results"))
    args = parser.parse_args()

    url, key = os.environ.get("HUB_URL"), os.environ.get("HUB_API_KEY")
    email, password = os.environ.get("HUB_EMAIL"), os.environ.get("HUB_PASSWORD")
    if url and not key and email and password:
        # Open WebUI accepts the session token wherever it accepts an API key.
        signin = _request("POST", f"{url.rstrip('/')}/api/v1/auths/signin", {}, {"email": email, "password": password}, 60)
        key = (signin or {}).get("token")
    if not url or not key:
        print("Set HUB_URL and either HUB_API_KEY or HUB_EMAIL + HUB_PASSWORD.", file=sys.stderr)
        return 2

    cases = yaml.safe_load(Path(args.dataset).read_text())["cases"]
    if args.only:
        wanted = set(args.only.split(","))
        cases = [c for c in cases if c["id"] in wanted]

    hub, gh = Hub(url, key), GitHub(REPO)
    served = [m.get("id") for m in (hub.call("GET", "/api/models") or {}).get("data", [])]  # also refreshes the model cache
    if MODEL_ID not in served:
        print(f"Model '{MODEL_ID}' is not available on {url} (found: {served}).", file=sys.stderr)
        return 2
    args.tool_ids = hub.model_tool_ids(MODEL_ID)
    print(f"model={MODEL_ID} tool_ids={args.tool_ids} cases={len(cases)}\n")
    results = []
    for case in cases:
        result = run_case(case, hub, gh, args)
        results.append(result)
        mark = "PASS" if result["passed"] else "FAIL"
        print(f"{mark}  {result['id']:<28} {result.get('latency_s', '-')!s:>6}s  tools={','.join(result.get('tools', [])) or '-'}")
        if result.get("error"):
            print(f"      error: {result['error']}")
        for name, (ok, detail) in result["checks"].items():
            if not ok or name == "dynamic":
                print(f"      {name}: {detail}")

    total = len(results)
    passed = sum(r["passed"] for r in results)
    must_failed = [r["id"] for r in results if r["must_pass"] and not r["passed"]]
    latencies = [r["latency_s"] for r in results if "latency_s" in r]
    by_category: dict[str, list[bool]] = {}
    for r in results:
        by_category.setdefault(r["category"], []).append(r["passed"])

    summary = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "hub": url, "model": MODEL_ID, "judge": args.judge,
        "pass_rate": round(passed / total, 3) if total else 0,
        "passed": passed, "total": total,
        "must_pass_failed": must_failed,
        "by_category": {k: f"{sum(v)}/{len(v)}" for k, v in sorted(by_category.items())},
        "latency_p50_s": round(statistics.median(latencies), 1) if latencies else None,
        "latency_max_s": max(latencies) if latencies else None,
    }
    gate_ok = total > 0 and not must_failed and summary["pass_rate"] >= MIN_PASS_RATE
    summary["gate"] = "passed" if gate_ok else "failed"

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"eval-{time.strftime('%Y%m%d-%H%M%S', time.gmtime())}.json"
    serialisable = [{**r, "checks": {k: {"ok": ok, "detail": d} for k, (ok, d) in r["checks"].items()}} for r in results]
    out_file.write_text(json.dumps({"summary": summary, "results": serialisable}, indent=2, ensure_ascii=False))

    print("\n" + json.dumps(summary, indent=2))
    print(f"\nDetails: {out_file}")
    return 0 if gate_ok else 1


if __name__ == "__main__":
    sys.exit(main())
