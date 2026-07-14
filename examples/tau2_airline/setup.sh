#!/usr/bin/env bash
# Onboard tau2-bench airline as a NEW benchmark and prepare it for optimization.
#
# This is the executable transcript of the cap-evolve INTAKE / implement-and-check
# phase for this example, driven by PROMPT.md: a coding agent following RUN.md does
# exactly these steps. Run it directly to reproduce in one command:
#
#   bash examples/tau2_airline/setup.sh   # install cap-evolve + onboard tau2 + check
#   bash examples/tau2_airline/run.sh     # full run + live dashboard
#
set -uo pipefail

EX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$EX_DIR/../.." && pwd)"
TAU2_DIR="$(cd "$REPO/.." && pwd)/tau2-bench"
VENV="$REPO/.venv"
PY="$VENV/bin/python"
PIP_INDEX="${PIP_INDEX:-https://pypi.org/simple}"   # public PyPI (override if you have a mirror)
say(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\n\033[1;31mSETUP FAILED: %s\033[0m\n' "$*" >&2; exit 1; }

# tau2-bench requires Python >=3.12,<3.14 (see ../tau2-bench/pyproject.toml).
# Fedora's default python3 may be 3.14+ — pick 3.12/3.13 explicitly.
_py_minor() {
  "$1" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null
}
_py_ok_for_tau2() {
  local minor
  minor="$(_py_minor "$1")" || return 1
  case "$minor" in
    3.12|3.13) return 0 ;;
    *) return 1 ;;
  esac
}
_find_python_for_venv() {
  if [ -n "${PYTHON_BIN:-}" ] && _py_ok_for_tau2 "$PYTHON_BIN"; then
    echo "$PYTHON_BIN"
    return 0
  fi
  local cand
  for cand in python3.13 python3.12 python3; do
    command -v "$cand" >/dev/null 2>&1 || continue
    if _py_ok_for_tau2 "$cand"; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}
_ensure_venv() {
  local pybin
  pybin="$(_find_python_for_venv)" || die "need Python 3.12 or 3.13 for tau2-bench (found only 3.14+ or <3.12). Install python3.13 or set PYTHON_BIN=python3.13"
  if [ -x "$PY" ]; then
    if _py_ok_for_tau2 "$PY"; then
      echo "  using existing venv ($(_py_minor "$PY"))"
      return 0
    fi
    echo "  removing incompatible venv ($(_py_minor "$PY") — tau2 needs >=3.12,<3.14)"
    rm -rf "$VENV"
  fi
  echo "  creating venv with $pybin ($(_py_minor "$pybin"))"
  "$pybin" -m venv "$VENV" || die "could not create venv with $pybin"
}

# --- options: install the live dashboard server or not ---------------------
WITH_DASHBOARD="${WITH_DASHBOARD:-1}"   # default ON; env or flag can override
for arg in "$@"; do
  case "$arg" in
    --dashboard)    WITH_DASHBOARD=1 ;;
    --no-dashboard) WITH_DASHBOARD=0 ;;
    -h|--help) echo "usage: setup.sh [--dashboard|--no-dashboard]  (default: --dashboard)"; exit 0 ;;
    *) echo "unknown option: $arg  (use --dashboard | --no-dashboard)" >&2; exit 2 ;;
  esac
done

say "1/3  Install cap-evolve (Python venv + core CLI)"
_ensure_venv
"$PY" -m pip install -q --index-url "$PIP_INDEX" --upgrade pip
"$PY" -m pip install -q --index-url "$PIP_INDEX" -e "$REPO/core" || die "pip install ./core failed"
"$VENV/bin/cap-evolve" version || die "cap-evolve CLI not available"
# Live dashboard (recommended; toggle with --dashboard / --no-dashboard). The built
# frontend (dashboard/frontend/dist — the capybara UI) is committed, so no node is
# needed at runtime; this just installs the server that serves it. Non-fatal.
if [ "$WITH_DASHBOARD" = "1" ]; then
  "$PY" -m pip install -q --index-url "$PIP_INDEX" -e "$REPO/dashboard/backend" 2>/dev/null \
    && echo "  dashboard server installed (live capybara UI: cap-evolve run --dashboard auto)" \
    || echo "  (optional) dashboard server not installed — run still works with --dashboard off"
else
  echo "  dashboard install SKIPPED (--no-dashboard) — run with: CAPEVOLVE_DASHBOARD=off bash run.sh"
fi

say "2/3  INTAKE — onboard the tau2-bench benchmark (per PROMPT.md)"
# (a) Install the benchmark: clone tau2-bench (latest main) + pip install -e. Record the SHA.
if [ ! -d "$TAU2_DIR/.git" ]; then
  echo "  cloning tau2-bench (latest main) -> $TAU2_DIR"
  git clone --depth 1 https://github.com/sierra-research/tau2-bench "$TAU2_DIR" || die "git clone tau2-bench failed"
fi
"$PY" -m pip install -q --index-url "$PIP_INDEX" -e "$TAU2_DIR" || die "pip install tau2-bench failed"
# Python 3.13+ removed stdlib audioop; tau2 imports it at package load (voice utils).
if ! "$PY" -c "import audioop" >/dev/null 2>&1; then
  echo "  installing audioop-lts (stdlib audioop removed in Python 3.13+)"
  "$PY" -m pip install -q --index-url "$PIP_INDEX" audioop-lts \
    || die "pip install audioop-lts failed (required for tau2 on Python 3.13+)"
fi
TAU2_SHA="$(git -C "$TAU2_DIR" rev-parse HEAD)"
mkdir -p "$EX_DIR/run_full"; echo "$TAU2_SHA" > "$EX_DIR/run_full/TAU2_COMMIT.txt"
if ! "$PY" -c "import tau2" 2>"$EX_DIR/.tau2_import_err.txt"; then
  echo "  tau2 import error:" >&2
  cat "$EX_DIR/.tau2_import_err.txt" >&2
  die "tau2 import failed after install"
fi
rm -f "$EX_DIR/.tau2_import_err.txt"
echo "  tau2-bench installed @ $TAU2_SHA"
# (b) Scaffold the cap-evolve project (the intake script).
"$PY" "$REPO/skills/phases/intake/scripts/run.py" --base "$REPO/.capevolve" --workdir "$REPO" --force >/dev/null \
  || die "intake scaffold failed"
PROJECT="$REPO/.capevolve/project"
# (c) Wire the integration the agent authored: adapter + RITS shim + seed capability + spec.
mkdir -p "$PROJECT/adapters"
cp "$EX_DIR/adapters/adapter.py" "$EX_DIR/adapters/rits.py" \
   "$EX_DIR/adapters/claude_code_runner.py" "$EX_DIR/adapters/claude_code_agent.py" \
   "$EX_DIR/adapters/anthropic_user.py" "$EX_DIR/adapters/vertex_llm.py" "$PROJECT/adapters/"
rm -rf "$PROJECT/seed_capability"; cp -R "$EX_DIR/seed_capability" "$PROJECT/seed_capability"
cp "$EX_DIR/capevolve.yaml" "$EX_DIR/capevolve.smoke.yaml" \
   "$EX_DIR/capevolve.claude-agent.yaml" "$EX_DIR/capevolve.claude-agent.smoke.yaml" \
   "$EX_DIR/split_ids.json" "$EX_DIR/smoke_split.json" "$PROJECT/"
echo "  project scaffolded + integration wired at $PROJECT"

say "3/3  Hard gate — cap-evolve check (credentials + adapter contract)"
if [ -z "${RITS_API_KEY:-}" ] && ! grep -q '^RITS_API_KEY=' "$REPO/.env" 2>/dev/null; then
  echo "  WARNING: RITS_API_KEY not set — RITS mode needs it."
  echo "           For TAU2_AGENT_MODE=claude_code without RITS, configure ONE of:"
  echo "             Vertex: ANTHROPIC_VERTEX_PROJECT_ID + CLOUD_ML_REGION + GCP ADC"
  echo "             Direct: ANTHROPIC_API_KEY"
fi
if [ "${TAU2_AGENT_MODE:-}" = "claude_code" ]; then
  command -v claude >/dev/null 2>&1 || die "TAU2_AGENT_MODE=claude_code requires claude CLI on PATH"
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "  NOTE: ANTHROPIC_API_KEY not set — will use logged-in Claude Code session if available"
  fi
  echo "  Claude Code eval-agent mode: claude CLI found"
fi
PYTHONPATH="$PROJECT/adapters" "$VENV/bin/cap-evolve" check "$PROJECT" || die "cap-evolve check did not pass"

printf '\n\033[1;32mREADY.\033[0m  Next:\n  bash %s/run.sh                  # RITS agent + claude-code optimizer (default)\n  bash %s/smoke.sh                # RITS smoke\n  bash %s/smoke_claude_agent.sh   # Claude Code eval agent + optimizer smoke\n  bash %s/run_claude_agent.sh     # Claude Code eval agent + optimizer (staged)\n' "$EX_DIR" "$EX_DIR" "$EX_DIR" "$EX_DIR"
