"""SWE-bench Lite adapter — optimize a coding-agent skill-package.

  * ``tasks``      -> 5 selected single-file instances from unique repos.
  * ``run_target`` -> read SKILL.md from candidate dir, call Claude via Vertex AI,
                      return the generated patch.
  * ``score``      -> lightweight (no Docker): check patch validity and file targeting.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cap_evolve import CapabilityAdapter, Rollout, Score, Task

SELECTED_IDS = [
    "astropy__astropy-12907",
    "django__django-10914",
    "matplotlib__matplotlib-18869",
    "psf__requests-1963",
    "pylint-dev__pylint-5859",
]


def _load_env() -> None:
    here = Path(__file__).resolve()
    for parent in [here.parent, *here.parents]:
        env = parent / ".env"
        if env.exists():
            try:
                for raw in env.read_text(encoding="utf-8").splitlines():
                    line = raw.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    key, _, val = line.partition("=")
                    os.environ.setdefault(key.strip(), val.strip().strip('"').strip("'"))
            except Exception:
                pass
            break


def _gold_files(patch: str) -> list[str]:
    return re.findall(r"^diff --git a/(.+?) b/", patch, re.MULTILINE)


def _extract_hunks(patch: str) -> list[dict]:
    """Extract hunk line ranges from a patch (gold-safe: only line NUMBERS, not content)."""
    hunks = []
    for m in re.finditer(r"^@@ -(\d+),?\d* \+(\d+),?\d* @@(.*)$", patch, re.MULTILINE):
        hunks.append({"old_start": int(m.group(1)), "new_start": int(m.group(2)),
                       "context": m.group(3).strip()[:60]})
    return hunks


def _patch_change_count(patch: str) -> dict:
    """Count added/removed lines in a patch."""
    added = len(re.findall(r"^\+(?!\+\+)", patch, re.MULTILINE))
    removed = len(re.findall(r"^-(?!--)", patch, re.MULTILINE))
    return {"added": added, "removed": removed}


class Adapter(CapabilityAdapter):

    _cache = None

    def _load_dataset(self):
        if Adapter._cache is not None:
            return Adapter._cache
        from datasets import load_dataset
        ds = load_dataset("princeton-nlp/SWE-bench_Lite", split="test")
        Adapter._cache = {r["instance_id"]: r for r in ds if r["instance_id"] in SELECTED_IDS}
        return Adapter._cache

    def tasks(self, split: str) -> list[Task]:
        data = self._load_dataset()
        out = []
        for iid in SELECTED_IDS:
            row = data.get(iid)
            if not row:
                continue
            gold_patch = row["patch"]
            out.append(Task(
                id=iid,
                input=row["problem_statement"],
                metadata={
                    "repo": row["repo"],
                    "base_commit": row["base_commit"],
                    "hints_text": row.get("hints_text", ""),
                    "gold_files": _gold_files(gold_patch),
                    "gold_hunks": _extract_hunks(gold_patch),
                    "gold_line_count": _patch_change_count(gold_patch),
                },
            ))
        return out

    def run_target(self, task: Task, ctx, *, seed: int = 0) -> Rollout:
        candidate_dir = Path(ctx)
        skill_path = candidate_dir / "SKILL.md"
        if not skill_path.exists():
            return Rollout(task_id=task.id, error="No SKILL.md in candidate dir")

        skill_text = skill_path.read_text(encoding="utf-8")
        if skill_text.startswith("---"):
            parts = skill_text.split("---", 2)
            if len(parts) >= 3:
                skill_text = parts[2].strip()

        refs_dir = candidate_dir / "references"
        if refs_dir.is_dir():
            for rf in sorted(refs_dir.glob("*.md")):
                skill_text += "\n\n## Reference: " + rf.name + "\n" + rf.read_text(encoding="utf-8")

        user_prompt = (
            f"## Repository: {task.metadata.get('repo', '')}\n\n"
            f"## GitHub Issue\n{task.input}\n\n"
        )
        hints = task.metadata.get("hints_text", "")
        if hints and hints.strip():
            user_prompt += f"## Hints\n{hints}\n\n"
        user_prompt += (
            "Generate a unified diff patch that fixes this issue. "
            "Output ONLY the raw patch (starting with `diff --git`), no markdown fences, no explanation."
        )

        _load_env()
        try:
            import litellm
            litellm.drop_params = True
            response = litellm.completion(
                model="vertex_ai/claude-sonnet-4-6",
                messages=[
                    {"role": "system", "content": skill_text},
                    {"role": "user", "content": user_prompt},
                ],
                temperature=0.2,
                max_tokens=4096,
                vertex_project=os.environ.get("ANTHROPIC_VERTEX_PROJECT_ID"),
                vertex_location=os.environ.get("CLOUD_ML_REGION", "global"),
                seed=seed,
            )
            patch = response.choices[0].message.content or ""
            tokens = response.usage.total_tokens if response.usage else 0
            return Rollout(task_id=task.id, output=patch,
                           trace=[{"role": "assistant", "content": patch}], tokens=tokens)
        except Exception as e:
            return Rollout(task_id=task.id, error=f"LLM call failed: {e}")

    def score(self, task: Task, rollout: Rollout) -> Score:
        if rollout.error:
            return Score(task_id=task.id, reward=0.0,
                         feedback=f"Infrastructure error ({rollout.error}); not a skill defect.")
        patch = rollout.output or ""
        meta = task.metadata or {}
        reward, feedback = _score_patch(
            patch,
            gold_files=meta.get("gold_files", []),
            gold_hunks=meta.get("gold_hunks", []),
            gold_counts=meta.get("gold_line_count", {}),
        )
        return Score(task_id=task.id, reward=reward, feedback=feedback)


def _clean_patch(patch: str) -> str:
    clean = patch.strip()
    if clean.startswith("```"):
        lines = clean.split("\n")
        clean = "\n".join(lines[1:-1] if lines[-1].strip() == "```" else lines[1:])
    return clean


def _score_patch(patch: str, gold_files: list[str], gold_hunks: list[dict],
                 gold_counts: dict) -> tuple[float, str]:
    """Tighter patch scoring (no Docker). 5 dimensions:

    1. Valid diff format (0.15)
    2. Correct file targeting (0.25)
    3. Hunk structure present (0.10)
    4. Line range proximity — is the patch near the right area? (0.25)
    5. Change size similarity — not too big, not too small (0.25)
    """
    clean = _clean_patch(patch)
    issues = []
    points = 0.0

    has_diff = bool(re.search(r"^diff --git", clean, re.MULTILINE))
    has_minus = bool(re.search(r"^--- ", clean, re.MULTILINE))
    has_plus = bool(re.search(r"^\+\+\+ ", clean, re.MULTILINE))
    has_hunk = bool(re.search(r"^@@ ", clean, re.MULTILINE))

    if has_diff and has_minus and has_plus:
        points += 0.15
    elif has_minus and has_plus:
        points += 0.05
        issues.append("Missing 'diff --git' header.")
    else:
        return 0.0, "Not a valid unified diff. Must have 'diff --git', '---', '+++' lines."

    patch_files = re.findall(r"^diff --git a/(.+?) b/", clean, re.MULTILINE)
    if not patch_files:
        patch_files = re.findall(r"^\+\+\+ b/(.+)$", clean, re.MULTILINE)

    if gold_files and patch_files:
        matched = set(patch_files) & set(gold_files)
        if matched:
            points += 0.25 * len(matched) / len(gold_files)
        else:
            issues.append(f"Wrong file: patch targets {patch_files}, expected {gold_files}.")
    elif not patch_files:
        issues.append("Cannot detect target file(s).")
    else:
        points += 0.05

    if has_hunk:
        points += 0.10
    else:
        issues.append("No @@ hunk headers.")

    patch_hunks = _extract_hunks(clean)
    if gold_hunks and patch_hunks:
        gold_lines = {h["old_start"] for h in gold_hunks}
        patch_lines = {h["old_start"] for h in patch_hunks}
        if gold_lines & patch_lines:
            points += 0.25
        else:
            min_dist = min(
                abs(gl - pl) for gl in gold_lines for pl in patch_lines
            ) if gold_lines and patch_lines else 999
            if min_dist <= 10:
                points += 0.20
            elif min_dist <= 30:
                points += 0.10
                issues.append(f"Patch edits line ~{sorted(patch_lines)[0]} but fix is near line ~{sorted(gold_lines)[0]}.")
            else:
                issues.append(f"Patch edits line ~{sorted(patch_lines)[0]} but fix is near line ~{sorted(gold_lines)[0]} (off by {min_dist} lines).")
    elif gold_hunks and not patch_hunks:
        issues.append("Cannot determine which lines the patch edits.")

    patch_counts = _patch_change_count(clean)
    gold_added = gold_counts.get("added", 0) or 1
    gold_removed = gold_counts.get("removed", 0)
    gold_total = gold_added + gold_removed or 1
    patch_total = patch_counts["added"] + patch_counts["removed"]

    if patch_total == 0:
        issues.append("Patch has no actual changes (no +/- lines).")
    elif gold_total > 0:
        ratio = patch_total / gold_total
        if 0.5 <= ratio <= 2.0:
            points += 0.25
        elif 0.25 <= ratio <= 4.0:
            points += 0.15
            issues.append(f"Patch changes {patch_total} lines, expected ~{gold_total}.")
        else:
            points += 0.05
            issues.append(f"Patch changes {patch_total} lines, expected ~{gold_total} — likely over/under-editing.")

    reward = round(min(points, 1.0), 2)
    if not issues:
        feedback = f"Patch reward {reward:.2f}: correct file, correct area, correct scope."
    else:
        feedback = f"Patch reward {reward:.2f}. " + " ".join(issues)
    return reward, feedback
