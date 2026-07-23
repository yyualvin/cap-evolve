# Optimize the tau2 AIRLINE skill package — ship several REAL, SAFE, VERIFIED fixes this iteration

{{FOCUS_SUMMARY}}

{{EMPTY_SEED}}

GOAL: raise mean tau2 task reward on the airline domain as much as you can THIS
iteration, then STOP (the harness re-scores you — don't run evaluation yourself). This
run is **skill-package only**. The editable artifact is the Agent Skill under your
candidate dir: `SKILL.md` (frontmatter + body) plus optional `references/*.md` and
`scripts/` you add under the skill. The adapter feeds the skill body (+ references) to
tau2 as the agent's policy.

**Out of scope — do NOT edit these:**
- `tools/tools.py` — tools are frozen for this run; they still run at eval time, but you
  must not change them.
- `policy/policy.md` — legacy duplicate; the adapter never reads it when `SKILL.md`
  exists. Edits here are invisible to `score()`.
- `reference/data_model.py` — read-only context if present; not part of the skill.

Make **AS MANY real fixes as you can this iteration — solve many issues across many
trajectories, not just the biggest one.** A timid one- or two-edit iteration is an
under-used iteration: diagnose EVERY failure cluster in `./trajectories/` and ship a fix
for each one that passes the three tests below. Breadth is the goal — improve the
description/trigger, body rules, references, and (when useful) skill scripts together in
ONE candidate.

The ONLY brake on breadth is regression: every edit must pass all three tests, because a
single speculative edit that breaks a passing task can sink an iteration of good work.
So the discipline is "many fixes, each one real and safe" — NOT "few fixes".

## What you can change (skill-package edit classes)
Read `./guidance/skill-package/SKILL.md` in FULL — it is your menu. Highest leverage first:

1. **Description / trigger** — frontmatter `description` (what + when). Rarely the main
   lever here (tau2 always loads this policy), but keep it accurate and valid.
2. **Body** — make required steps unmissable: clarify rules, add WHY, consolidate
   duplicates, add missing policy grounded in the domain, tighten the output contract
   (e.g. state exact figures from tool results), add short examples. Keep the body within
   skill-creator budget (~500 lines / ~5k tokens); imperative voice.
3. **References** — factor rarely-co-used detail into `references/*.md` (one level deep)
   with an explicit "load this when …" pointer from `SKILL.md`.
4. **Scripts** — only when a step is deterministic and the agent keeps re-deriving it
   wrongly in prose; bundle under `scripts/` and state execute-vs-read intent. Prefer
   clearer body rules first for airline policy adherence.

Stay a **valid** skill: frontmatter (`name`/`description`), body budget, one-level refs,
no broken links.

## Prefer HIGH-LEVERAGE prose — know the limits
Because tools are frozen, you cannot add in-body guards or new tools. Spend the iteration
on clusters prose **can** move:

- **KNOWLEDGE / OUTPUT CONTRACT** — agent doesn't know a rule, format, or that it must
  **state** a computed total/refund from observed tool results (e.g. `payment_history`).
  Sharpen `SKILL.md` so the fact/contract is unmissable.
- **PROCEDURE / ORDERING** — agent skips a required step (get user id first, confirm
  before write, look up reservation before modify/cancel). Make the sequence checklisted
  and ordered in the body.
- **NARROWING decision rules** — wrong ACT-vs-REFUSE on compensation, cancellation
  eligibility, transfer. Add an ADDITIVE rule that states the **exact discriminating
  predicate** — never loosen a global permission (that regresses passing tasks).

**Be honest about hard stalls:** if the agent already knows the rule and still executes
the wrong write (or skips the write after confirming), more prose often will not fix it.
Still try the strongest unmissable procedure / counterexample you can; do not invent tool
edits. Prefer clusters where score feedback shows communication misses, missing
preconditions stated as knowledge, or decision criteria the policy omitted.

## The THREE TESTS every change must pass
1. **REAL** — targets a cluster FAILING in THIS iteration's `./trajectories/` (reward 0,
   partial credit, or communicate miss). No hypothetical edits.
2. **SAFE** — would this change what the agent does on ANY currently-passing task?
   Prefer ADDITIVE / narrowing rules over rewriting global permissions. Name passing
   tasks in the same decision class and confirm none flip from refuse→act (or vice versa)
   incorrectly.
3. **VERIFIED** — tie the edit to a specific failing check in the trace / score feedback
   (see VERIFY-THE-FIX). Unverifiable = drop.

Don't re-add anything `LEDGER.md` / `JOURNAL.md` show was already tried and rejected.

## Read these first
- **`./guidance/skill-package/SKILL.md`** — READ IN FULL before editing (edit classes +
  validity rules). Do **not** read `./guidance/tools/` as an edit menu — tools are not
  selected for this run.
- `./guidance/diagnose/SKILL.md` — failure clustering.
- `./trajectories/` — full traces + `reward_info`; use `{{FAILURES}}` as an index, then
  read the actual traces for clusters you fix.
- Current `SKILL.md` (+ any `references/`) in this workdir — the live policy.
- `./LEDGER.md`, `./JOURNAL.md`, `./RUNMAP.md` + `./prior_iterations/` — prior results;
  if the latest RESULT is REJECTED, keep only non-regressing edits from that batch.
- `./PROCESS.md` — required explainability for THIS iteration.
- `./guidance/optimizer/<name>.md` — optional parallelism features.
{{BENCH_REPO}}

## Process (do this, then STOP)
**Parallelism:** {{PARALLEL_NOTE}} Phase 1 — diagnose fan-out (read-only) into issue lists;
Phase 2 — edit fan-out per cluster into `SKILL.md` / references / scripts; merge into ONE
candidate.
1. Read STEP-0 guidance + cross-iteration files.
2. Diagnose THIS iteration's `./trajectories/` only. Cluster ALL failures; rank by
   leverage; plan to fix as many as pass the three tests.
3. For each cluster, pick a skill edit class; draft; keep only if REAL + SAFE + VERIFIED.
4. Ship every kept edit in this ONE candidate. Re-check skill validity.
5. Fill `PROCESS.md`; APPEND intent-only entry to `JOURNAL.md`. STOP.

## VERIFY-THE-FIX
- **Body / procedure:** name the failing communicate/action check and show how the new
  wording would change the agent's next turn; confirm passing tasks in the same class
  stay on their current path.
- **Decision / permission:** enumerate currently-passing tasks in that class; confirm the
  edit does not newly ACT where gold was refuse/escalate (or the reverse). Prefer
  narrowing predicates over global loosenings.
- **Reference:** body pointer exists; link resolves; detail not paid for on every turn
  unless needed.
- **Script:** only if added — run it on failing-task inputs if possible; body states
  execute intent.

Record one verify + blast-radius line per edit in PROCESS.md.

## NON-OVERFITTING
Encode GENERAL policy (membership/cabin/cancellation/compensation classes), never a
literal reservation id, user id, or gold dollar amount from one task. Allowed constants:
policy date `2024-05-15`, stated fees ($50 bag, $30 insurance, $100/$50 compensation
multipliers), payment-method counts (≤1 certificate, ≤1 card, ≤3 gift cards).

## Handover (REQUIRED before STOP)
- **PROCESS.md** — ranked clusters (KNOWLEDGE / PROCEDURE / DECISION tags), every kept
  edit + class, verify + blast-radius lines, what you skipped and why.
- **JOURNAL.md** — append ONE intent entry (changes, expected effect, safety, what prior
  RESULTS you built on / did not re-try). Framework stamps RESULT below.

{{FAILURES}}
{{PASSING}}
{{CAP_BRIEF}}
{{ALGO_BRIEF}}

## Self-check before STOP
- Every kept edit passes REAL / SAFE / VERIFIED with a PROCESS.md line.
- You only edited the skill package (`SKILL.md`, `references/`, optional `scripts/`) —
  **not** `tools/tools.py`, **not** `policy/policy.md`.
- You read `./guidance/skill-package/SKILL.md` and used multiple edit classes where useful.
- You addressed every cluster you could fix safely with prose/skill structure; you did not
  invent tool/code edits.
- Decision edits NARROWS / ADD knowledge — never loosen global permissions.
- No task-specific hardcoded ids/answers; skill stays valid (frontmatter, budget, refs).
- PROCESS.md + JOURNAL.md filled. Keep narration minimal.
