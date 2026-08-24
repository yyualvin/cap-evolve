FROM python:3.12-slim

ARG OC_VERSION=4.16.13

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    nodejs \
    npm \
    tar \
    && rm -rf /var/lib/apt/lists/*

# claude-code is the EDIT PROPOSER for cap-evolve's optimizer step (hill-climb calls it
# directly inside this pod, not inside a Harbor sandbox — those install their own copy
# per task). Without it, every optimizer iteration fails with `cli_present: false` and
# silently reports best=seed (see ci/benchmarks/lib/ci_setup.sh for the same footgun in CI).
RUN npm install -g @anthropic-ai/claude-code

WORKDIR /app

# Install OpenShift CLI used by Harbor's openshift backend.
RUN curl -fsSL -o /tmp/oc.tar.gz \
    "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OC_VERSION}/openshift-client-linux-${OC_VERSION}.tar.gz" \
    && tar -C /usr/local/bin -xzf /tmp/oc.tar.gz oc kubectl \
    && chmod +x /usr/local/bin/oc /usr/local/bin/kubectl \
    && rm -f /tmp/oc.tar.gz

# Install cap-evolve core.
COPY core/ /app/core/
COPY capevolve_harbor/ /app/capevolve_harbor/
COPY dashboard/backend/ /app/dashboard/backend/

RUN pip install --no-cache-dir \
    /app/core \
    /app/capevolve_harbor \
    /app/dashboard/backend \
    harbor

# Install tau2-bench and litellm for benchmark evaluation
RUN git clone --depth 1 https://github.com/sierra-research/tau2-bench.git /app/tau2-bench && \
    pip install --no-cache-dir /app/tau2-bench litellm

# Copy skills and static dashboard frontend assets.
COPY skills/ /app/skills/
COPY dashboard/frontend/dist/ /app/dashboard/frontend/dist/

# Seed files copied into workspace by the container entrypoint.
COPY .capevolve/project/ /opt/cap-evolve-seed/.capevolve/project/
COPY openshift/run.sh /opt/cap-evolve-seed/openshift/run.sh
COPY openshift/task_ids_*.txt /opt/cap-evolve-seed/openshift/
COPY openshift/images/cap-evolve-runner/entrypoint.sh /usr/local/bin/cap-evolve-runner-entrypoint
RUN chmod +x /usr/local/bin/cap-evolve-runner-entrypoint

ENV PYTHONPATH="/app" \
    CAPEVOLVE_SKILLS_DIR="/app/skills" \
    TAU2_DATA_DIR="/app/tau2-bench/data" \
    GIT_EDITOR=true \
    HOME=/tmp

CMD ["/usr/local/bin/cap-evolve-runner-entrypoint"]
