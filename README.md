# smart-coder-ops

Infrastructure and launch scripts for [smart-coder](../smart-coder) — the model
backends and the verify sandbox image. These are **environment/rig concerns**,
kept out of the application repo so swapping models or tuning the rig never
churns the source tree.

Nothing here compiles smart-coder's source. The pieces that *do* (the MCP server
image) stay in the main repo under `docker/mcp/`.

## Contents

### `compose.yaml` — llama.cpp backend launchers

Stock `ghcr.io/ggml-org/llama.cpp:server-cuda` (wrapped to add `curl` — see
`docker/llama/`) serving GGUF models on this box's two GPUs. smart-coder reaches
them over HTTP (OpenAI-compatible API); it has no knowledge of this file.

| Service (profile) | Backend | Endpoint |
|--------|---------|----------|
| `sc-coder30b` (`coder30b`) | `qwen3-coder-30b-a3b` MoE, split across both GPUs (`--tensor-split 12,8`) — the daily driver | `:11435` |
| `sc-qwen8b-pool` / `-pool2` (`pool8b`) | Two Qwen3-8B pools (one per GPU, `-np` slots) — the parallel MCP swarm fallback | `:11439`, `:11440` |
| `sc-tiel30b` (`tiel30b`) | `Tiel-Coder-35B-A3B` (`qwen35moe`) IQ4_XS, split across both GPUs — the 30B's replacement candidate | `:11436` |

Nothing starts without a **profile**. All three backends compete for the same
VRAM — run exactly one profile at a time, never two.

```powershell
# 30B daily driver — --wait blocks until the model is loaded and serving
docker compose --profile coder30b up --build --wait
docker compose --profile coder30b down

# Both 8B pools (5 concurrent agents total)
docker compose --profile pool8b up --build --wait
docker compose --profile pool8b down

# Tiel-Coder-35B — same A3B shape as the 30B, on :11436
docker compose --profile tiel30b up --build --wait
docker compose --profile tiel30b down
```

**Quant choice on this rig matters.** ~21.4GB free across both cards with the
desktop idle: Tiel's `IQ4_XS` (16.9GB) fits, `Q4_K_S` (19.9GB) does not. The
model card's SWE-bench-Live 12/25 was measured on the 22.4GB `Q4_K_XL`, which
this box cannot hold — treat that number as an upper bound, not a prediction.

**Close games before starting `tiel30b`.** Measured on an idle desktop it runs
**117 tok/s** eval / 268 tok/s prompt (11.5GB Ti + 7.3GB 3080) — comfortably
matching the 30B. With Space Engineers up, the weights overflow to host RAM and
every token crosses the PCIe-4x link: **1.8 tok/s**, a 66x cliff with no graceful
middle ground. The 30B (`q3_k_m`, 14GB) has the slack to share a card; this does
not. If a game was running when the container started, restart it afterwards —
llama.cpp will not re-place the weights on its own.

`--wait` returns when the in-container healthcheck passes (curl hits `/v1/models`),
i.e. the moment the model finishes loading — no host-side polling. `--build` is a
~5s no-op once the wrapper image is cached.

**VRAM glance** (host-side — a container can't see the whole rig):

```powershell
nvidia-smi --query-gpu=index,memory.used,memory.free,memory.total --format=csv,noheader
```

**8B pools** round-robin behind the MCP — point it at both with:

```
SC_BASE_URLS=http://host.docker.internal:11439/v1,http://host.docker.internal:11440/v1
```

> **First-run note:** compose requests GPUs via `deploy.resources` (the documented
> equivalent of `--gpus all`); the pools additionally pin one card via
> `CUDA_VISIBLE_DEVICES`. Verify GPU passthrough on your Docker Desktop / WSL2 setup
> the first time — `nvidia-smi` inside the container, or just watch the load succeed.

### `docker/llama/` — the healthcheck-capable llama.cpp image

Three lines: `FROM` the stock llama.cpp server image + `apt-get install curl`, so
compose's healthcheck can poll the model from inside the container. Built
automatically by `docker compose --build`.

### `docker/pyenv/` — the verify sandbox image

A pinned Python toolkit (pytest + deps) that smart-coder runs generated code in,
so a build can't depend on or pollute the host. smart-coder references it **by
image name** (`smart-coder-pyenv`), so it just needs to exist in the local Docker
daemon — build it once:

```powershell
docker build -t smart-coder-pyenv docker/pyenv
```

## Relationship to smart-coder

- **Backends** (`compose.yaml`): decoupled — HTTP only. The endpoint/model smart-coder
  talks to lives in `%APPDATA%\smart-coder\config.json` (or `SC_BASE_URL`/`SC_MODEL`),
  not in either repo.
- **Verify image** (`docker/pyenv/`): decoupled — referenced by name.
- **MCP server image**: NOT here. It lives in `smart-coder/docker/mcp/` because it
  `COPY . .` + `cargo build`s the workspace — it must be built with smart-coder as
  the Docker context, so it belongs with the code.
