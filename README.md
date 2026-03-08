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

A focused, single-binary tool that continuously pings NVIDIA NIM models and reports latency metrics. No bloat, no TUI framework, no telemetry. Just latency numbers.

## Metrics

- **Latest** — most recent round-trip time
- **Avg** — rolling average of all successful pings
- **P95** — 95th percentile latency (tail spikes)
- **Jitter** — standard deviation (consistency)
- **Health** — UP / TIMEOUT / OVERLOADED / ERROR / NO_KEY
- **Verdict** — Perfect / Normal / Slow / Spiky / Very Slow / Unstable
- **Up%** — uptime percentage

## Install

```bash
# Build from source
git clone https://github.com/bkataru/nimakai.git
cd nimakai
nimble build

# Or with nim directly
nim c -d:release -d:ssl src/nimakai.nim
```

Requires Nim 2.0+ and OpenSSL.

## Usage

```bash
export NVIDIA_API_KEY="nvapi-..."

# Continuous monitoring (all default models)
nimakai

# Single round, then exit
nimakai --once

# Specific models only
nimakai --models qwen/qwen3.5-122b-a10b,qwen/qwen3.5-397b-a17b

# Custom interval and timeout
nimakai --interval 3 --timeout 10

# JSON output (for piping/scripting)
nimakai --once --json
```

## Sample Output

```
 nimakai v0.1.0  round 5 | NVIDIA NIM latency benchmark

MODEL                                 LATEST       AVG       P95    JITTER  HEALTH      VERDICT        UP%
----------------------------------------------------------------------------------------------------------
qwen/qwen3.5-122b-a10b                 342ms     380ms     412ms     28ms  UP          Perfect       100%
qwen/qwen3.5-397b-a17b                2841ms    3102ms    4210ms    890ms  UP          Very Slow     100%
z-ai/glm4.7                            521ms     610ms     780ms    102ms  UP          Normal        100%
stepfun-ai/step-3.5-flash              445ms     490ms     620ms     65ms  UP          Normal        100%
minimaxai/minimax-m2.5                  380ms     420ms     510ms     42ms  UP          Perfect       100%
minimaxai/minimax-m2.1                  410ms     450ms     580ms     55ms  UP          Normal        100%
```

## Options

| Flag | Short | Description | Default |
|------|-------|-------------|---------|
| `--once` | `-1` | Single round, then exit | continuous |
| `--models` | `-m` | Comma-separated model IDs | all defaults |
| `--interval` | `-i` | Ping interval in seconds | 5 |
| `--timeout` | `-t` | Request timeout in seconds | 15 |
| `--json` | `-j` | JSON output | table |
| `--help` | `-h` | Show help | |
| `--version` | `-v` | Show version | |

## License

MIT
