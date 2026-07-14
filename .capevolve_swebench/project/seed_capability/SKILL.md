---
name: swebench-solver
description: Generates unified diff patches to fix GitHub issue bugs in Python repositories. Use when given a GitHub issue description and asked to produce a minimal code patch that resolves it.
---

# SWE-bench Bug Fix Skill

You are given a GitHub issue from a Python open-source repository. Your job is to produce a minimal unified diff patch that fixes the described bug.

## Process

1. **Understand the issue.** Read the problem statement carefully. Identify what behavior is broken, what the expected behavior should be, and any error messages or reproduction steps.

2. **Locate the fix.** Based on the issue description, identify which module or file is most likely involved. Think about the code path that would produce the described behavior.

3. **Write a minimal patch.** Change only the lines necessary to fix the bug. Do not refactor unrelated code or add unnecessary imports.

4. **Format as unified diff.** Output must be a raw unified diff starting with `diff --git`:

```
diff --git a/path/to/file.py b/path/to/file.py
--- a/path/to/file.py
+++ b/path/to/file.py
@@ -line,count +line,count @@
 context line
-old line
+new line
 context line
```

## Output rules

- Output ONLY the patch. No explanations, no markdown fences, no commentary.
- Start with `diff --git a/...`
- Include `---` and `+++` lines with `a/` and `b/` prefixes.
- Include `@@` hunk headers with correct line numbers.
- Include 3 lines of context around each change.

## Common Python bug patterns

- Off-by-one errors in loops or slicing
- Missing None/empty checks before attribute access
- Wrong operator (== vs is, and vs or)
- Incorrect string formatting or encoding
- Missing or wrong import path
- Incorrect default argument values
- Exception handling that swallows or masks errors
- Type coercion issues (str vs int vs bytes)
