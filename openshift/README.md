# OpenShift Deployment

Deploy cap-evolve on OpenShift with GPU-accelerated model serving via [vLLM](https://github.com/vllm-project/vllm).

## Architecture

```
┌───────────────────────────────────────────────────────────┐
│  OpenShift  (namespace: skill-optimization)              │
│                                                            │
│  vLLM Agent (7B, 1 GPU) ◄── cap-evolve Runner (CPU)       │
│                               │                            │
│                               └─► Optimizer CLI            │
│                                   (claude-code / codex /   │
│                                    gemini-cli / …)         │
└───────────────────────────────────────────────────────────┘
```

| Component | Role | Resources |
|-----------|------|-----------|
| **vLLM Agent** | Executes benchmark tasks (the model being optimized) | 1+ GPUs |
| **Runner** | Runs the `cap-evolve` optimization loop | CPU only |
| **Optimizer CLI** | Coding agent that proposes skill edits (configured via `capevolve.yaml`) | External API key or self-hosted |

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
oc apply -f openshift/manifests/harbor-rbac.yaml
oc apply -f openshift/manifests/pvc.yaml

# 2. Secrets — driven by ONE local env file (never committed; see .gitignore)
cp openshift/.env.example openshift/.env   # first time only, then fill in real values
set -a; source openshift/.env; set +a

#    Runtime config secret (ANTHROPIC_VERTEX_PROJECT_ID, etc.) — the Deployment
#    picks these up automatically via envFrom, no YAML editing needed:
oc create secret generic cap-evolve-runner-env \
  -n skill-optimization \
  --from-literal=ANTHROPIC_VERTEX_PROJECT_ID="$ANTHROPIC_VERTEX_PROJECT_ID" \
  --dry-run=client -o yaml | oc apply -f -

#    GCP Vertex credentials file (required by openshift/run.sh):
oc create secret generic gcp-vertex-credentials \
  -n skill-optimization \
  --from-file=application_default_credentials.json="$GCP_ADC_JSON" \
  --dry-run=client -o yaml | oc apply -f -

#    Optional HuggingFace token (needed only if you also deploy vLLM):
#    oc create secret generic hf-token --from-literal=HF_TOKEN="$HF_TOKEN" -n skill-optimization

# 3. Build runner image on-cluster (internal registry)
oc new-build --binary --strategy=docker --name=cap-evolve-runner -n skill-optimization
oc start-build cap-evolve-runner --from-dir=. --follow -n skill-optimization

# 4. Deploy persistent runner pod
oc apply -f openshift/manifests/cap-evolve-runner-deployment.yaml

# 5. Watch run progress
oc logs -n skill-optimization -f deployment/cap-evolve-runner

# 6. Open live dashboard (in another terminal)
oc port-forward -n skill-optimization deployment/cap-evolve-runner 7878:7878

# Visit:
#   http://127.0.0.1:7878

# 7. Get results
POD=$(oc get pod -n skill-optimization -l app=cap-evolve-runner \
  -o jsonpath='{.items[0].metadata.name}' --field-selector=status.phase=Running)
oc cp skill-optimization/$POD:/workspace/.capevolve ./results
cat results/run_*/report.md
```

> **Cluster-admin prerequisite:** `openshift/manifests/harbor-rbac.yaml` contains a
> cluster-scoped SCC (`harbor-task-scc`). A cluster-admin (or equivalent) must apply it.
> Namespace-scoped RoleBindings can be applied by project admins.

> **Rotating/updating `openshift/.env` later?** Re-run the step 2 `oc create secret ...`
> commands, then restart the pod so it picks up the new values (env vars from Secrets
> are only read at container start, not hot-reloaded):
> ```bash
> oc rollout restart deployment/cap-evolve-runner -n skill-optimization
> ```

> **Private registry?** Create a pull secret:
> ```bash
> oc create secret docker-registry registry-pull \
>   --docker-server=quay.io --docker-username=<user> --docker-password=<token> \
>   -n skill-optimization
> oc secrets link cap-evolve-runner registry-pull --for=pull -n skill-optimization
> ```

### Interactive mode

The persistent runner (deployed in step 4) can also be used interactively:

```bash
oc exec -n skill-optimization -it deployment/cap-evolve-runner -- bash

# inside the pod
cd /workspace
bash ./openshift/run.sh
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