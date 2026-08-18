RUN_NAME="RHSWEBENCH-TESTRUN"

# Harbor Binary
export HARBOR_BIN="$HOME/.local/bin/harbor" && \

# Harbor Dataset
export HARBOR_DATASET="rounakbende10/rh-swe-bench" && \

# AI Agent and Model
export HARBOR_AGENT="claude-code" && \
export HARBOR_MODEL="claude-sonnet-4-6" && \

# This is equivalent of -n in openshift
export HARBOR_PARALLEL=8 && \

# Timeout in seconds
export HARBOR_TIMEOUT=1800 && \

# We run this in Openshift
export HARBOR_EXTRA_FLAGS="-e openshift" && \

# Task list (one ID per line). Override before sourcing, e.g.:
#   HARBOR_TASK_IDS_FILE=.capevolve/project/adapters/task_ids.txt ./envs.sh
export HARBOR_TASK_IDS_FILE="${HARBOR_TASK_IDS_FILE:-.capevolve/project/adapters/task_ids_pilot.txt}" && \
export HARBOR_TASK_IDS="$(tr '\n' ',' < "$HARBOR_TASK_IDS_FILE" | sed 's/,$//')" && \

# Our Claude Code stuff
export CLAUDE_CODE_USE_VERTEX=1 && \
export CLOUD_ML_REGION=global && \
export ANTHROPIC_VERTEX_PROJECT_ID="${ANTHROPIC_VERTEX_PROJECT_ID}" && \
export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.config/gcloud/application_default_credentials.json" && \

export PYTHONPATH=".capevolve/project/adapters/adapters.py" && \
export CAPEVOLVE_SKILLS_DIR="$PWD/skills" && \
export GIT_EDITOR=true && \
.venv/bin/cap-evolve run \
 --spec .capevolve/project/adapters/capevolve.yaml \
 --project .capevolve/project \
 --run-ts $RUN_NAME \
 --dashboard auto