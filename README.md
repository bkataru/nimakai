<p align="center">
  <img src="assets/logo.svg" width="128" height="128" alt="nimakai logo">
</p>

<h1 align="center">nimakai</h1>

<p align="center">
  <strong>NVIDIA NIM model latency benchmarker, written in Nim.</strong>
</p>

<p align="center">
  <em>nimakai (నిమ్మకాయి) = lemon in Telugu. NIM + Nim = nimakai.</em>
</p>

---

A focused, single-binary tool that continuously pings NVIDIA NIM models and reports latency metrics. Includes a 46-model tiered catalog, recommendation engine for [oh-my-opencode](https://github.com/bkataru/oh-my-opencode) routing, and full sync mode. No bloat, no TUI framework, no telemetry. Just latency numbers.

## Metrics

- **Latest** — most recent round-trip time
- **Avg** — rolling average (ring buffer, last 100 samples)
- **P50** — median latency
- **P95** — 95th percentile (tail spikes)
- **P99** — 99th percentile (worst case)
- **Jitter** — standard deviation (consistency)
- **Stability** — composite score 0-100 (P95 + jitter + spike rate + reliability)
- **Health** — UP / TIMEOUT / OVERLOADED / ERROR / NO_KEY / NOT_FOUND
- **Verdict** — Perfect / Normal / Slow / Spiky / Very Slow / Unstable / Not Active / Not Found
- **Up%** — uptime percentage
- **Tier** — S+ / S / A+ / A / A- / B+ / B / C (based on SWE-bench Verified scores)

## Install

```bash
git clone https://github.com/bkataru/nimakai.git
cd nimakai
nimble build
```

Requires Nim 2.0+ and OpenSSL.

## Usage

```bash
export NVIDIA_API_KEY="nvapi-..."

# Continuous monitoring (S+ and S tier models by default)
nimakai

# Single round, then exit
nimakai --once

# Specific models only
nimakai -m qwen/qwen3.5-122b-a10b,qwen/qwen3.5-397b-a17b

# Filter by tier
nimakai --tier A --once

# Sort by stability score
nimakai --sort stability

# Benchmark models from opencode.json
nimakai --opencode --once

# JSON output
nimakai --once --json
```

## Commands

```
nimakai                    Continuous benchmark (default)
nimakai catalog            List all 46 known models with tiers and metadata
nimakai recommend          Benchmark and recommend routing changes
nimakai history            Show historical benchmark data
nimakai opencode           Show models from opencode.json + OMO routing
```

## Recommendation Engine

nimakai can benchmark models and recommend optimal routing for oh-my-opencode categories:

```bash
# Advisory: show recommendations
nimakai recommend --rounds 3

# Full sync: backup -> diff -> apply to oh-my-opencode.json
nimakai recommend --rounds 5 --apply

# Rollback to previous config
nimakai recommend --rollback
```

Each OMO category is scored using weighted criteria:

| Category Need | SWE Weight | Speed Weight | Stability Weight |
|---------------|------------|--------------|------------------|
| Speed (quick) | 0.15 | 0.55 | 0.20 |
| Quality (deep, artistry) | 0.45 | 0.10 | 0.20 |
| Reliability (ultrabrain) | 0.25 | 0.20 | 0.40 |
| Vision (visual-engineering) | 0.30 | 0.20 | 0.30 |
| Balance (writing, default) | 0.30 | 0.30 | 0.25 |

## Interactive Keys (continuous mode)

| Key | Sort By |
|-----|---------|
| `A` | Average latency |
| `P` | P95 latency |
| `S` | Stability score |
| `T` | Tier |
| `N` | Model name |
| `U` | Uptime % |
| `Q` | Quit |

## Options

| Flag | Short | Description | Default |
|------|-------|-------------|---------|
| `--once` | `-1` | Single round, then exit | continuous |
| `--models` | `-m` | Comma-separated model IDs | S/S+ tier |
| `--interval` | `-i` | Ping interval in seconds | 5 |
| `--timeout` | `-t` | Request timeout in seconds | 15 |
| `--json` | `-j` | JSON output | table |
| `--tier` | | Filter by tier family (S, A, B, C) | |
| `--sort` | | Sort: avg, p95, stability, tier, name, uptime | avg |
| `--opencode` | | Use models from opencode.json | |
| `--rounds` | `-r` | Benchmark rounds for recommend | 3 |
| `--apply` | | Apply recommendations to oh-my-opencode.json | |
| `--rollback` | | Rollback oh-my-opencode.json from backup | |
| `--help` | `-h` | Show help | |
| `--version` | `-v` | Show version | |

## Configuration

Optional config at `~/.config/nimakai/config.json`:

```json
{
  "interval": 5,
  "timeout": 15,
  "thresholds": {
    "perfect_avg": 400,
    "perfect_p95": 800,
    "normal_avg": 1000,
    "normal_p95": 2000,
    "spike_ms": 3000
  },
  "favorites": []
}
```

Custom models can be added via `~/.config/nimakai/models.json` to extend the built-in catalog.

History is persisted to `~/.local/share/nimakai/history.jsonl` (30-day auto-prune).

## Architecture

```
src/
  nimakai.nim              Entry point, CLI parsing, main loop
  nimakai/
    types.nim              Types, enums, constants
    metrics.nim            Pure metric functions (avg, p50, p95, p99, jitter, stability)
    ping.nim               HTTP ping + status-code error classification
    catalog.nim            46-model catalog with SWE-bench tiers
    display.nim            Table/JSON rendering, ANSI helpers
    config.nim             Config file persistence
    history.nim            JSONL history persistence
    opencode.nim           OpenCode + oh-my-opencode integration
    recommend.nim          Recommendation engine with category scoring
    sync.nim               Backup, apply, rollback for OMO config
tests/
    test_types.nim         9 tests
    test_metrics.nim       37 tests
    test_display.nim       21 tests
    test_ping.nim          13 tests
    test_catalog.nim       13 tests
    test_config.nim        5 tests
    test_opencode.nim      5 tests
    test_recommend.nim     12 tests
```

## License

MIT
