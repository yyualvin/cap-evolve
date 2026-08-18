# All-in-one cap-evolve + Harbor orchestrator for OpenShift (ROSA internal registry).
# Build from repo root:
#   podman build -f openshift/images/cap-evolve-harbor-runner/Dockerfile .
# Or: openshift/images/cap-evolve-harbor-runner/build.sh

FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# Harbor OpenShift executor drives the cluster via oc.
RUN curl -fsSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
    | tar xzf - -C /usr/local/bin oc kubectl

WORKDIR /app

# cap-evolve core
COPY core/ /app/core/
RUN pip install --no-cache-dir /app/core

COPY skills/ /app/skills/

# Harbor CLI + capevolve_harbor adapter glue
RUN pip install --no-cache-dir "harbor>=0.20.0"
COPY capevolve_harbor/ /app/capevolve_harbor/
RUN pip install --no-cache-dir /app/capevolve_harbor

# Dashboard (web UI on port 7878)
COPY dashboard/frontend/ /app/dashboard/frontend/
RUN cd /app/dashboard/frontend && npm ci && npm run build
COPY dashboard/backend/ /app/dashboard/backend/
RUN pip install --no-cache-dir /app/dashboard/backend

# Optimizer (capevolve.yaml optimizer_skill: claude-code)
RUN npm install -g @anthropic-ai/claude-code

ENV PYTHONPATH="/app" \
    CAPEVOLVE_SKILLS_DIR="/app/skills" \
    GIT_EDITOR=true \
    HOME=/tmp \
    HARBOR_BIN=harbor

EXPOSE 7878

WORKDIR /workspace

CMD ["sleep", "infinity"]
