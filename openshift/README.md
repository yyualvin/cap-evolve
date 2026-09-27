# OpenShift Deployment

Deploy cap-evolve on OpenShift with GPU-accelerated model serving via [vLLM](https://github.com/vllm-project/vllm).

## Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│  OpenShift  (namespace: cap-evolve)                                 │
│                                                                     │
│  ┌─────────────────┐     egress      ┌──────────────────────────┐  │
│  │ LiteLLM proxy   │ ──────────────► │ OpenAI / Anthropic APIs   │  │
│  │ (CPU, :4000)    │                 └──────────────────────────┘  │
│  └────────┬────────┘                                               │
│           │  ANTHROPIC_BASE_URL (in-cluster)                        │
│           ├──────────────────► Harbor task pods (claude-code)       │
│           └──────────────────► cap-evolve runner (optimizer)        │
│                                                                     │
│  ┌─────────────────┐                                                │
│  │ vLLM Agent      │ ◄── optional: self-hosted open models on GPU   │
│  │ (7B, 1 GPU)     │                                                │
│  └─────────────────┘                                                │
└────────────────────────────────────────────────────────────────────┘
```

| Component | Role | Resources |
|-----------|------|-----------|
| **LiteLLM proxy** | Routes `claude-code` to OpenAI (direct API key) | CPU only |
| **vLLM Agent** | Optional: serves open-weight models on-cluster | 1+ GPUs |
| **Runner** | Runs the `cap-evolve` optimization loop | CPU only |
| **Optimizer CLI** | Coding agent that proposes skill edits (configured via `capevolve.yaml`) | Calls LiteLLM proxy or external API |

The agent model is served on-cluster via vLLM. The optimizer is a coding-agent CLI
(Claude Code, Codex, Gemini CLI, etc.) — see `skills/optimizers/registry.yaml` for
the full list. The optimizer needs its own credentials (e.g., `ANTHROPIC_API_KEY`
for `claude-code`).

## Prerequisites

- `oc` CLI logged into your cluster
- GPU nodes with the [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/index.html)
- Container registry ([Quay.io](https://quay.io), GHCR, or internal)
- [HuggingFace token](https://huggingface.co/settings/tokens) (for gated models)
- Optimizer credentials (e.g., `ANTHROPIC_API_KEY` for `claude-code`)

## Deploy

All commands run from the repo root. Replace `<your-org>` with your registry organization.

```bash
# 1. Namespace, RBAC, and PVC
oc apply -f openshift/manifests/namespace.yaml
oc apply -f openshift/manifests/service-account.yaml
oc apply -f openshift/manifests/pvc.yaml

# 2. Secrets
#    HuggingFace token (for gated model downloads):
oc create secret generic hf-token \
  --from-literal=HF_TOKEN=<YOUR_HF_TOKEN> \
  -n cap-evolve
#    Or edit and apply the template:
#    oc apply -f openshift/manifests/secrets.yaml

# 3a. LiteLLM proxy (cloud models for Harbor / claude-code — GPT Luna, etc.)
#     Edit openshift/litellm-proxy/config.yaml, then sync the ConfigMap in
#     openshift/manifests/litellm-proxy.yaml (or re-apply after editing the manifest).
oc apply -f openshift/manifests/litellm-proxy-secrets.yaml   # or oc create secret ...
oc apply -f openshift/manifests/litellm-proxy.yaml
oc get pods -n cap-evolve -l component=litellm-proxy -w

# 3b. vLLM model server (optional — self-hosted open models on GPU)
oc apply -f openshift/manifests/vllm-serving.yaml

# Wait for the model to load (5-15 min on first deploy)
oc get pods -n cap-evolve -l component=vllm -w

# 4. Build and push the runner image
podman login quay.io
podman build -t quay.io/<your-org>/cap-evolve-runner:latest \
  -f openshift/images/cap-evolve-runner/Dockerfile .
podman push quay.io/<your-org>/cap-evolve-runner:latest

# 5. Deploy the runner and copy your project config
#    (.capevolve/project/ is generated locally by the intake phase —
#    see docs/OPTIMIZE_YOUR_OWN.md)
oc apply -f openshift/manifests/cap-evolve-runner-deployment.yaml
POD=$(oc get pod -n cap-evolve -l app=cap-evolve-runner \
  -o jsonpath='{.items[0].metadata.name}' --field-selector=status.phase=Running)
oc cp .capevolve/project cap-evolve/$POD:/workspace/.capevolve/project

# 6. Run the optimizer (update image: in the manifest first)
oc apply -f openshift/manifests/cap-evolve-runner-job.yaml
oc logs -n cap-evolve job/cap-evolve-run -f

# 7. Get results
oc cp cap-evolve/$POD:/workspace/.capevolve ./results
cat results/run_*/report.md
```

> **Private registry?** Create a pull secret:
> ```bash
> oc create secret docker-registry registry-pull \
>   --docker-server=quay.io --docker-username=<user> --docker-password=<token> \
>   -n cap-evolve
> oc secrets link cap-evolve-runner registry-pull --for=pull -n cap-evolve
> ```

### Interactive mode

The persistent runner (deployed in step 5) can also be used interactively:

```bash
oc exec -n cap-evolve -it deployment/cap-evolve-runner -- bash

# inside the pod
cd /workspace
cap-evolve run \
  --spec .capevolve/project/capevolve.yaml \
  --project .capevolve/project \
  --run-ts run1 --dashboard off
```

## LiteLLM proxy

Deploy a **CPU-only** gateway in the `skill-optimization` namespace so Harbor task pods and the
cap-evolve optimizer can reach cloud models through `claude-code` (Anthropic Messages API
in, Azure/OpenAI out).

| File | Purpose |
|------|---------|
| `openshift/litellm-proxy/config.yaml` | Model routing (edit, then sync into the ConfigMap) |
| `openshift/manifests/litellm-proxy-secrets.yaml` | Secret template (`LITELLM_MASTER_KEY`, `OPENAI_API_KEY`) |
| `openshift/manifests/litellm-proxy.yaml` | Deployment + Service + Route |
| `openshift/scripts/test-litellm-proxy.sh` | Smoke test from outside the namespace |

### Wire Harbor / cap-evolve to the proxy

In-cluster URL (use this in `run.sh` for OpenShift Harbor runs):

```bash
export HARBOR_AGENT_BASE_URL="http://litellm-proxy.skill-optimization.svc:4000"
export HARBOR_AGENT_API_KEY="$LITELLM_MASTER_KEY"
export ANTHROPIC_API_KEY="$LITELLM_MASTER_KEY"
export HARBOR_MODEL="gpt-5.6-luna"   # must match model_name in config.yaml
```

Unset `CLAUDE_CODE_USE_VERTEX` when using the proxy.

### Test from outside the namespace

**Option 1 — port-forward** (laptop, no Route required):

```bash
oc port-forward -n skill-optimization svc/litellm-proxy 4000:4000
export LITELLM_MASTER_KEY='sk-litellm-...'
./openshift/scripts/test-litellm-proxy.sh http://localhost:4000
```

**Option 2 — OpenShift Route** (HTTPS URL, works from any network that can reach the cluster):

```bash
export LITELLM_MASTER_KEY='sk-litellm-...'
ROUTE=$(oc get route litellm-proxy -n skill-optimization -o jsonpath='{.spec.host}')
./openshift/scripts/test-litellm-proxy.sh "https://$ROUTE"
```

**Option 3 — from another namespace on the same cluster** (no Route, no port-forward):

```bash
# Run inside any pod that has curl, or from a debug pod in another namespace:
curl -s http://litellm-proxy.skill-optimization.svc.cluster.local:4000/health
```

Cross-namespace Service DNS works by default unless a NetworkPolicy blocks it.

Manual Anthropic probe (same API `claude-code` uses):

```bash
curl -s "$BASE_URL/v1/messages" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"gpt-5.6-luna","max_tokens":32,"messages":[{"role":"user","content":"ping"}]}'
```

## Configuration

### Agent model

The agent model is configured via the [`model_config.py` convention](../templates/adapters/model_config.py).
Set these env vars in the runner manifest:

| Variable | Example | Description |
|----------|---------|-------------|
| `MODEL` | `openai/qwen2.5-7b-instruct` | Agent model ([litellm](https://docs.litellm.ai/) format) |
| `OPENAI_API_BASE` | `http://vllm-agent:80/v1` | vLLM endpoint (cluster-internal Service) |
| `OPENAI_API_KEY` | `dummy` | vLLM accepts any value |
| `TAU2_MAX_CONCURRENCY` | `30` | Concurrent eval requests |

### Optimizer

The optimizer is a coding-agent CLI configured via `optimizer_skill` in `capevolve.yaml`.
It is **not** a raw LLM call — it runs a full agent (Claude Code, Codex, etc.) that
reads trajectories and edits skill files. Each agent needs its own credentials.

| `optimizer_skill` | Credentials needed |
|-------------------|--------------------|
| `claude-code` | `ANTHROPIC_API_KEY` |
| `codex` | `OPENAI_API_KEY` |
| `gemini-cli` | `GEMINI_API_KEY` |
| `generic` | `CAPEVOLVE_OPTIMIZER_CMD` (your own CLI) |

See `skills/optimizers/registry.yaml` for the full list.

**Fully self-hosted optimizer (no external API keys):**
To run the optimizer entirely on-cluster, deploy a larger model with
`vllm-optimizer.yaml` and use the `generic` optimizer skill pointed at a
CLI configured against the vLLM endpoint:

```yaml
# capevolve.yaml
optimizer_skill: generic
```
```bash
# In the runner manifest env:
CAPEVOLVE_OPTIMIZER_CMD="<your-agent-cli> --api-base http://vllm-optimizer:80/v1 --model qwen2.5-14b-instruct -p"
```

This requires an agent CLI that supports OpenAI-compatible endpoints. If your
optimizer CLI doesn't support this (e.g., `claude-code` requires Anthropic),
you'll still need an external API key for the optimizer while the agent runs
on-cluster via vLLM.

### Swapping agent models

Edit `vllm-serving.yaml` — change the model name, GPU count, and `--tensor-parallel-size`,
then update `MODEL` in the runner manifest.

| Size | GPUs | `--tensor-parallel-size` | Memory request |
|------|------|--------------------------|----------------|
| 7B | 1 | 1 (default) | 8 Gi |
| 14B | 2 | 2 | 32 Gi |
| 32B+ | 4 | 4 | 64 Gi |

> **Node selector:** The vLLM optimizer manifest uses `nodeSelector: gpu-pool-size: xlarge`
> for multi-GPU models. Match this to your cluster's GPU node labels
> (`oc get nodes --show-labels | grep gpu`).

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `cap-evolve check` passes but eval fails | Check `MODEL` and `OPENAI_API_BASE` — `check` is offline and won't catch wrong endpoints |

## Security notes

- The `anyuid` SCC binding grants broad UID permissions. For production, consider
  a custom SCC scoped to the specific UIDs your containers need.