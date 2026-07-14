# Unified Diff Format Reference

## Required structure

Every patch must follow this exact format:

```
diff --git a/<filepath> b/<filepath>
index <hash>..<hash> <mode>
--- a/<filepath>
+++ b/<filepath>
@@ -<old_start>,<old_count> +<new_start>,<new_count> @@
 <context line>
-<removed line>
+<added line>
 <context line>
```

## Rules

1. The `diff --git` line uses the SAME path for both `a/` and `b/` (unless renaming).
2. `---` and `+++` lines must have the `a/` and `b/` prefix.
3. `@@` hunk headers: `old_start` is the 1-based line number in the original file. `old_count` and `new_count` are the number of lines in each version of the hunk (including context).
4. Context lines (unchanged) start with a space character.
5. Removed lines start with `-`.
6. Added lines start with `+`.
7. Include 3 lines of context before and after each change.
8. For multiple changes in the same file, use multiple `@@` hunks under one `diff --git` header.
9. For changes across multiple files, use separate `diff --git` blocks.

## Common mistakes

- Wrapping the diff in markdown code fences (```diff ... ```) — output raw diff only.
- Using `--- file.py` instead of `--- a/file.py` — always include the `a/` and `b/` prefix.
- Wrong line numbers in `@@` headers — count carefully from the original file.
- Missing the space prefix on context lines — every unchanged line needs a leading space.
