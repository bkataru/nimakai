import std/[httpclient, json, times, os, strformat, strutils, parseopt, math, algorithm, net]
import malebolgia

const
  Version = "0.1.0"
  BaseURL = "https://integrate.api.nvidia.com/v1/chat/completions"
  DefaultTimeout = 15 # seconds
  DefaultInterval = 5 # seconds

type
  Health = enum
    hPending = "PENDING"
    hUp = "UP"
    hTimeout = "TIMEOUT"
    hOverloaded = "OVERLOADED"
    hError = "ERROR"
    hNoKey = "NO_KEY"

  PingResult = object
    health: Health
    ms: float

  ModelStats = object
    id: string
    pings: seq[float]
    totalPings: int
    successPings: int
    lastMs: float
    lastHealth: Health

  Config = object
    models: seq[string]
    once: bool
    interval: int
    timeout: int
    jsonOutput: bool
    apiKey: string

const DefaultModels = @[
  "qwen/qwen3.5-122b-a10b",
  "qwen/qwen3.5-397b-a17b",
  "z-ai/glm4.7",
  "stepfun-ai/step-3.5-flash",
  "minimaxai/minimax-m2.5",
  "minimaxai/minimax-m2.1",
]

# --- Metrics ---

proc avg(stats: ModelStats): float =
  if stats.pings.len == 0: return 0.0
  var sum = 0.0
  for v in stats.pings: sum += v
  sum / stats.pings.len.float

proc p95(stats: ModelStats): float =
  if stats.pings.len < 2: return stats.avg()
  var sorted = stats.pings
  sorted.sort()
  let idx = min(int(ceil(sorted.len.float * 0.95)) - 1, sorted.len - 1)
  sorted[idx]

proc jitter(stats: ModelStats): float =
  if stats.pings.len < 2: return 0.0
  let mean = stats.avg()
  var sumSq = 0.0
  for v in stats.pings:
    let d = v - mean
    sumSq += d * d
  sqrt(sumSq / stats.pings.len.float)

proc uptime(stats: ModelStats): float =
  if stats.totalPings == 0: return 0.0
  (stats.successPings.float / stats.totalPings.float) * 100.0

proc verdict(stats: ModelStats): string =
  if stats.pings.len == 0: return "Pending"
  let a = stats.avg()
  let p = stats.p95()
  if a < 400 and p < 800: return "Perfect"
  if a < 1000 and p < 2000: return "Normal"
  if stats.pings.len >= 3 and p > a * 2.5: return "Spiky"
  if a < 2000: return "Slow"
  if a < 5000: return "Very Slow"
  return "Unstable"

# --- Ping (runs in worker thread) ---

proc doPing(apiKey, modelId: string, timeout: int): PingResult {.gcsafe.} =
  let payload = $(%*{
    "model": modelId,
    "messages": [{"role": "user", "content": "hi"}],
    "max_tokens": 1,
    "stream": false
  })

  let sslCtx = newContext(verifyMode = CVerifyPeer)
  let client = newHttpClient(timeout = timeout * 1000, sslContext = sslCtx)
  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Authorization": "Bearer " & apiKey
  })

  let t0 = epochTime()
  try:
    discard client.postContent(BaseURL, payload)
    let ms = (epochTime() - t0) * 1000.0
    client.close()
    result = PingResult(health: hUp, ms: ms)
  except CatchableError as e:
    let ms = (epochTime() - t0) * 1000.0
    try: client.close()
    except CatchableError: discard
    let msg = e.msg.toLowerAscii()
    if "timeout" in msg or "timed out" in msg:
      result = PingResult(health: hTimeout, ms: ms)
    elif "401" in msg or "403" in msg:
      result = PingResult(health: hNoKey, ms: ms)
    elif "429" in msg:
      result = PingResult(health: hOverloaded, ms: ms)
    else:
      result = PingResult(health: hError, ms: ms)

# --- Display ---

proc colorLatency(ms: float): string =
  let val = &"{ms:.0f}ms"
  if ms < 500: return "\e[32m" & val & "\e[0m"
  if ms < 1500: return "\e[33m" & val & "\e[0m"
  return "\e[31m" & val & "\e[0m"

proc healthIcon(h: Health): string =
  case h
  of hUp: "\e[32mUP\e[0m"
  of hTimeout: "\e[33mTIMEOUT\e[0m"
  of hOverloaded: "\e[31mOVERLOADED\e[0m"
  of hError: "\e[31mERROR\e[0m"
  of hNoKey: "\e[33mNO_KEY\e[0m"
  of hPending: "\e[90mPENDING\e[0m"

proc verdictColor(v: string): string =
  case v
  of "Perfect": "\e[32m" & v & "\e[0m"
  of "Normal": "\e[36m" & v & "\e[0m"
  of "Slow": "\e[33m" & v & "\e[0m"
  of "Spiky": "\e[35m" & v & "\e[0m"
  of "Very Slow": "\e[31m" & v & "\e[0m"
  of "Unstable": "\e[31;1m" & v & "\e[0m"
  else: "\e[90m" & v & "\e[0m"

proc padRight(s: string, width: int): string =
  if s.len >= width: s[0..<width]
  else: s & ' '.repeat(width - s.len)

proc padLeft(s: string, width: int): string =
  if s.len >= width: s[0..<width]
  else: ' '.repeat(width - s.len) & s

proc stripAnsi(s: string): int =
  var i = 0
  var count = 0
  while i < s.len:
    if s[i] == '\e':
      while i < s.len and s[i] != 'm': inc i
      inc i
    else:
      inc count
      inc i
  count

proc padRightAnsi(s: string, width: int): string =
  let visible = stripAnsi(s)
  if visible >= width: s
  else: s & ' '.repeat(width - visible)

proc padLeftAnsi(s: string, width: int): string =
  let visible = stripAnsi(s)
  if visible >= width: s
  else: ' '.repeat(width - visible) & s

proc printTable(stats: seq[ModelStats], round: int) =
  let hdr = &"\e[1m nimakai v{Version}\e[0m  \e[90mround {round} | NVIDIA NIM latency benchmark\e[0m"
  echo ""
  echo hdr
  echo ""

  let header = padRight("MODEL", 35) &
               padLeft("LATEST", 10) &
               padLeft("AVG", 10) &
               padLeft("P95", 10) &
               padLeft("JITTER", 10) &
               "  " & padRight("HEALTH", 12) &
               padRight("VERDICT", 12) &
               padLeft("UP%", 7)
  echo "\e[1;90m" & header & "\e[0m"
  echo "\e[90m" & "-".repeat(106) & "\e[0m"

  for s in stats:
    var line = padRight(s.id, 35)

    if s.pings.len > 0:
      line &= padLeftAnsi(colorLatency(s.lastMs), 10)
      line &= padLeftAnsi(colorLatency(s.avg()), 10)
      line &= padLeftAnsi(colorLatency(s.p95()), 10)
      line &= padLeftAnsi(&"\e[90m{s.jitter():.0f}ms\e[0m", 10)
    else:
      line &= padLeft("-", 10)
      line &= padLeft("-", 10)
      line &= padLeft("-", 10)
      line &= padLeft("-", 10)

    line &= "  " & padRightAnsi(healthIcon(s.lastHealth), 12)
    line &= padRightAnsi(verdictColor(s.verdict()), 12)

    let up = &"{s.uptime():.0f}%"
    if s.uptime() >= 90: line &= padLeft("\e[32m" & up & "\e[0m", 7)
    elif s.uptime() >= 50: line &= padLeft("\e[33m" & up & "\e[0m", 7)
    else: line &= padLeft("\e[31m" & up & "\e[0m", 7)

    echo line

  echo ""

proc printJson(stats: seq[ModelStats], round: int) =
  var results = newJArray()
  for s in stats:
    results.add(%*{
      "model": s.id,
      "latest_ms": if s.pings.len > 0: s.lastMs else: 0.0,
      "avg_ms": s.avg(),
      "p95_ms": s.p95(),
      "jitter_ms": s.jitter(),
      "health": $s.lastHealth,
      "verdict": s.verdict(),
      "uptime_pct": s.uptime(),
      "total_pings": s.totalPings,
      "success_pings": s.successPings
    })
  let output = %*{"round": round, "results": results}
  echo $output

# --- CLI ---

proc parseArgs(): Config =
  result = Config(
    models: @[],
    once: false,
    interval: DefaultInterval,
    timeout: DefaultTimeout,
    jsonOutput: false,
    apiKey: ""
  )

  result.apiKey = getEnv("NVIDIA_API_KEY", "")

  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "once", "1": result.once = true
      of "json", "j": result.jsonOutput = true
      of "models", "m":
        for m in p.val.split(','):
          let trimmed = m.strip()
          if trimmed.len > 0: result.models.add(trimmed)
      of "interval", "i":
        result.interval = parseInt(p.val)
      of "timeout", "t":
        result.timeout = parseInt(p.val)
      of "help", "h":
        echo &"""
nimakai v{Version} - NVIDIA NIM latency benchmarker

Usage: nimakai [options]

Options:
  --once, -1             Single round, then exit
  --models, -m <list>    Comma-separated model IDs
  --interval, -i <sec>   Ping interval (default: {DefaultInterval}s)
  --timeout, -t <sec>    Request timeout (default: {DefaultTimeout}s)
  --json, -j             Output JSON
  --help, -h             Show this help
  --version, -v          Show version

Environment:
  NVIDIA_API_KEY         API key for NVIDIA NIM

Examples:
  nimakai --once
  nimakai -m qwen/qwen3.5-122b-a10b,qwen/qwen3.5-397b-a17b
  nimakai --interval 3 --json
"""
        quit(0)
      of "version", "v":
        echo &"nimakai v{Version}"
        quit(0)
      else:
        echo &"Unknown option: {p.key}"
        quit(1)
    of cmdArgument:
      discard

  if result.models.len == 0:
    result.models = DefaultModels

# --- Main ---

proc main() =
  let cfg = parseArgs()

  if cfg.apiKey.len == 0:
    stderr.writeLine "\e[31mError: NVIDIA_API_KEY environment variable not set\e[0m"
    stderr.writeLine "Get your key at https://build.nvidia.com"
    quit(1)

  if not cfg.jsonOutput:
    stderr.writeLine &"\e[1m nimakai\e[0m v{Version}"
    stderr.writeLine &"\e[90m  {cfg.models.len} models | {cfg.interval}s interval | {cfg.timeout}s timeout | concurrent pings\e[0m"

  var stats: seq[ModelStats]
  for m in cfg.models:
    stats.add(ModelStats(id: m, lastHealth: hPending))

  var round = 0
  while true:
    inc round

    # Ping all models concurrently via malebolgia thread pool.
    # Each model gets its own thread — a slow model never blocks the others.
    var results = newSeq[PingResult](stats.len)
    # Initialize all results as pending so timed-out pings show TIMEOUT
    for i in 0..<results.len:
      results[i] = PingResult(health: hTimeout, ms: float(cfg.timeout * 1000))

    try:
      var m = createMaster(timeout = initDuration(seconds = cfg.timeout + 5))
      m.awaitAll:
        for i in 0..<stats.len:
          m.spawn doPing(cfg.apiKey, stats[i].id, cfg.timeout) -> results[i]
    except ValueError:
      discard # awaitAll timeout — use whatever results came back

    # Collect results
    for i in 0..<stats.len:
      let pr = results[i]
      stats[i].totalPings += 1
      stats[i].lastMs = pr.ms
      stats[i].lastHealth = pr.health

      if pr.health == hUp:
        stats[i].successPings += 1
        stats[i].pings.add(pr.ms)

    if cfg.jsonOutput:
      printJson(stats, round)
    else:
      if round > 1 or not cfg.once:
        stdout.write "\e[2J\e[H"
      printTable(stats, round)

    if cfg.once:
      break

    sleep(cfg.interval * 1000)

main()
