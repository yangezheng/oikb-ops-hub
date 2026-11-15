# Eval proposal: is the oikb Ops Assistant good, and does it stay good?

The admin's request contains four testable promises. The eval system is built around them, not around generic RAG metrics.

| Promise in the request | What can go wrong | How it is measured |
|---|---|---|
| "answers from the **current state** of the repository" | sync stalls; files uploaded but not indexed; model answers from memory | Layer 0 (sync check) + `current-state` cases with ground truth computed live |
| "tells us when a question touches a **known bug or recent change**" | model never calls GitHub; calls it but misses the issue | `known-bug` / `recent-change` cases; tool-use check |
| "**nothing** in the Hub may have write access" | write tool exposed; model tries to write | `security` cases; token scope test |
| "answers questions about configuring and running oikb" | wrong file, invented flag, wrong language | `code-location`, `configuration`, `abstain` cases |

## Layers

**Layer 0 – Is the knowledge base the repository? (every 15 minutes, deterministic, built)**
After each sync the job runs `oikb diff`. Zero pending changes means the knowledge base holds exactly the files at HEAD; only then does the run count as a success. This is the cheapest and most important eval: if it is red, every other number is meaningless. It caught a real case in testing: uploads accepted, embedding failed, oikb reported success, knowledge base empty. No success for 45 minutes sends an e-mail (see `DECISIONS.md`, decision 3).

**Layer 1 – Golden set through the real chat path (built: `evals/run_eval.py`, 18 cases)**
Each question is asked through a real Open WebUI chat with the custom model, so the knowledge tools and the GitHub MCP server run exactly as they do for a support engineer. A plain `/api/chat/completions` call would not execute tools server-side, and the model's GitHub tool is attached by the browser, not by the backend; the runner therefore creates a saved chat and sends the model's tool list itself. Anything less would test a different system. Each case is graded on independent checks:

- **answer**: regexes that must or must not appear (`src/oikb/cli\.py`; no `oikb sync … --turbo`).
- **sources**: the expected file was actually retrieved or opened (`cli.py`, `webhooks.py`). Separates "retrieval missed" from "model ignored the context".
- **tools**: the right tool family was used: knowledge for code questions, GitHub for bugs and recent changes, and never a write tool.
- **dynamic**: ground truth computed from the GitHub API at run time. "Which connectors does oikb *currently* provide?" is graded against the connector modules at HEAD (47 today; the public docs page says 44, which is exactly the staleness the admin complains about). A static expected answer would make the eval go stale together with the system it tests.

Deterministic checks come first because they are free, reproducible and explainable to the admin.

**Layer 2 – LLM judge for what regexes cannot see (built, optional: `--judge`)**
Every case has a human-written reference answer. The judge scores correctness and completeness (0–2 each) against it. It is used for trends, not as the gate, until it has been calibrated: label 30 answers by hand, require ≥ 90 % agreement with the judge, re-check after every judge model change.

**Layer 3 – Real usage (proposed, not built)**
Open WebUI's thumbs up/down on answers, reviewed weekly. Every thumbs-down and every support escalation becomes a new golden case. This is how the set grows from 18 to something representative; I would not invent 200 synthetic questions up front.

## The golden set

Categories: `code-location` (2), `current-state` (2), `configuration` (5, one in German), `operations` (1), `recent-change` (1), `known-bug` (2), `abstain` (2), `security` (2), `scope` (1). It contains the three questions from the brief; they are `must_pass`. The negative cases matter as much as the positive ones: a support assistant that invents a `--turbo` flag is worse than one that says "I don't know".

## When it runs and what it gates

| Trigger | Run | Gate |
|---|---|---|
| Change to system prompt, model, RAG settings, Open WebUI or oikb version | full set before merge | all `must_pass` green and pass rate ≥ 85 % |
| Nightly (`.github/workflows/eval.yml`) | full set against the live Hub | same; a failed run notifies the repository owner |
| Every 15 minutes | Layer 0 check inside the sync job | e-mail after 45 minutes without a success |

Per run the runner stores a JSON file with answers, tool calls, sources, latency and token usage, so a regression can be diffed against the last green run. Reported per category, because one number hides that "known-bug" can be at 50 % while the total is at 90 %.

## Operational metrics tracked with every run

Latency per answer (p50 / max), tool calls per answer and token usage. They are not gated yet: I first want two weeks of numbers to set an honest threshold.

## Known limits

- 18 cases give a signal, not statistical confidence. One flaky case moves the pass rate by 5.5 points; runs should be repeated before acting on a single red.
- `known-bug` cases depend on real issues. When an issue is closed or renamed the case needs maintenance; the dynamic check for open issues reduces this but does not remove it.
- Prompt injection through issue text is tested only with a direct attempt. A planted-issue test needs a repository we control.
- The regex graders accept a correct answer in an unexpected phrasing less often than a human would. Failures are therefore read by a human before they count as a regression.
