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
PY_CREATE="$(_find_python_for_venv)" \
  || die "need Python 3.12 or 3.13 for tau2-bench (got system default incompatible with >=3.12,<3.14). Install one or set PYTHON_BIN=..."
# Recreate the venv if missing or built with an incompatible interpreter.
if [ -x "$PY" ] && ! _py_ok_for_tau2 "$PY"; then
  echo "  existing .venv is Python $(_py_minor "$PY") — recreating with $PY_CREATE"
  rm -rf "$VENV"
fi
[ -x "$PY" ] || "$PY_CREATE" -m venv "$VENV" || die "could not create venv with $PY_CREATE"
echo "  venv Python: $("$PY" -c 'import sys; print(sys.version.split()[0])') (from $PY_CREATE)"
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
# Default runner is Vertex Claude via litellm; needs the Vertex SDK (import vertexai).
"$PY" -m pip install -q --index-url "$PIP_INDEX" 'google-cloud-aiplatform>=1.38' \
  || die "pip install google-cloud-aiplatform failed (required for vertex_ai/ models)"
# Python 3.13+ removed stdlib audioop; tau2 still imports it via voice utils at load time.
case "$(_py_minor "$PY")" in
  3.13|3.14) "$PY" -m pip install -q --index-url "$PIP_INDEX" audioop-lts || die "pip install audioop-lts failed" ;;
esac
TAU2_SHA="$(git -C "$TAU2_DIR" rev-parse HEAD)"
mkdir -p "$EX_DIR/run_full"; echo "$TAU2_SHA" > "$EX_DIR/run_full/TAU2_COMMIT.txt"
if ! "$PY" -c "import tau2" 2>/tmp/tau2_import_err.$$; then
  cat /tmp/tau2_import_err.$$ >&2
  rm -f /tmp/tau2_import_err.$$
  die "tau2 import failed after install"
fi
rm -f /tmp/tau2_import_err.$$
echo "  tau2-bench installed @ $TAU2_SHA"
# (b) Scaffold the cap-evolve project (the intake script).
"$PY" "$REPO/skills/phases/intake/scripts/run.py" --base "$REPO/.capevolve" --workdir "$REPO" --force >/dev/null \
  || die "intake scaffold failed"
PROJECT="$REPO/.capevolve/project"
# (c) Wire the integration the agent authored: adapter + provider shim + seed capability + spec.
mkdir -p "$PROJECT/adapters"
cp "$EX_DIR/adapters/adapter.py" "$EX_DIR/adapters/rits.py" "$PROJECT/adapters/"
rm -rf "$PROJECT/seed_capability"; cp -R "$EX_DIR/seed_capability" "$PROJECT/seed_capability"
cp "$EX_DIR/capevolve.yaml" "$EX_DIR/capevolve.smoke.yaml" \
   "$EX_DIR/split_ids.json" "$EX_DIR/smoke_split.json" "$PROJECT/"
echo "  project scaffolded + integration wired at $PROJECT"

say "3/3  Hard gate — cap-evolve check (credentials + adapter contract)"
# Default agent/user = Vertex Claude (ADC). Override with TAU2_AGENT_MODEL / TAU2_USER_MODEL.
if [ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && ! command -v gcloud >/dev/null 2>&1; then
  echo "  WARNING: No GOOGLE_APPLICATION_CREDENTIALS and no gcloud — Vertex ADC may be missing."
  echo "           Run: gcloud auth application-default login"
  echo "           Optional: VERTEXAI_PROJECT / VERTEXAI_LOCATION (defaults: itpc-gcp-octo-eng-claude / global)."
fi
PYTHONPATH="$PROJECT/adapters" "$VENV/bin/cap-evolve" check "$PROJECT" || die "cap-evolve check did not pass"

printf '\n\033[1;32mREADY.\033[0m  Next:\n  bash %s/run.sh     # full run (10 iters · 50 tasks · 10 trials) + live dashboard\n  bash %s/smoke.sh   # 2-task autonomy smoke (cheap)\n' "$EX_DIR" "$EX_DIR"
