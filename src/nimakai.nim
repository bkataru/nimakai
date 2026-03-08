## nimakai — NVIDIA NIM model latency benchmarker
## https://github.com/bkataru/nimakai

import std/[os, strformat, strutils, parseopt, times, options, json]
import std/posix
import posix/termios as term_mod
import malebolgia
import nimakai/[types, ping, catalog, display, config, history,
                opencode, recommend, sync]

proc parseArgs(): Config =
  result = Config(
    models: @[],
    once: false,
    interval: DefaultInterval,
    timeout: DefaultTimeout,
    jsonOutput: false,
    apiKey: "",
    subcommand: smBenchmark,
    tierFilter: "",
    sortColumn: scAvg,
    useOpencode: false,
    rounds: 3,
    applySync: false,
    rollback: false,
    thresholds: DefaultThresholds,
  )

  result.apiKey = getEnv("NVIDIA_API_KEY", "")

  # Load config file defaults
  let fileCfg = loadConfigFile()
  if fileCfg.interval != DefaultInterval: result.interval = fileCfg.interval
  if fileCfg.timeout != DefaultTimeout: result.timeout = fileCfg.timeout
  if fileCfg.models.len > 0: result.models = fileCfg.models
  if fileCfg.tierFilter.len > 0: result.tierFilter = fileCfg.tierFilter
  result.thresholds = fileCfg.thresholds

  let params = commandLineParams()

  # Check for subcommands (first non-flag argument)
  if params.len > 0:
    case params[0]
    of "catalog":
      result.subcommand = smCatalog
      return
    of "recommend":
      result.subcommand = smRecommend
    of "history":
      result.subcommand = smHistory
      return
    of "trends":
      result.subcommand = smTrends
      return
    of "opencode":
      result.subcommand = smOpencode
      return
    else: discard

  var p = initOptParser(params)
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "once", "1": result.once = true
      of "json", "j": result.jsonOutput = true
      of "models", "m":
        result.models = @[]
        for m in p.val.split(','):
          let trimmed = m.strip()
          if trimmed.len > 0: result.models.add(trimmed)
      of "interval", "i":
        try: result.interval = parseInt(p.val)
        except ValueError: discard
      of "timeout", "t":
        try: result.timeout = parseInt(p.val)
        except ValueError: discard
      of "tier":
        result.tierFilter = p.val
      of "sort":
        case p.val.toLowerAscii()
        of "avg", "a": result.sortColumn = scAvg
        of "p95", "p": result.sortColumn = scP95
        of "stability", "s": result.sortColumn = scStability
        of "tier", "t": result.sortColumn = scTier
        of "name", "n": result.sortColumn = scName
        of "uptime", "u": result.sortColumn = scUptime
        else: discard
      of "opencode": result.useOpencode = true
      of "rounds", "r":
        try: result.rounds = parseInt(p.val)
        except ValueError: discard
      of "apply": result.applySync = true
      of "rollback": result.rollback = true
      of "help", "h":
        echo &"""
nimakai v{Version} - NVIDIA NIM latency benchmarker

Usage: nimakai [command] [options]

Commands:
  (default)              Continuous benchmark
  catalog                List all known models with metadata
  recommend              Benchmark and recommend routing changes
  history                Show historical benchmark data
  trends                 Show latency trend analysis
  opencode               Show models from opencode.json

Options:
  --once, -1             Single round, then exit
  --models, -m <list>    Comma-separated model IDs
  --interval, -i <sec>   Ping interval (default: {DefaultInterval}s)
  --timeout, -t <sec>    Request timeout (default: {DefaultTimeout}s)
  --json, -j             Output JSON
  --tier <S|A|B|C>       Filter models by tier family
  --sort <col>           Sort: avg, p95, stability, tier, name, uptime
  --opencode             Use models from opencode.json
  --rounds, -r <n>       Benchmark rounds for recommend (default: 3)
  --apply                Apply recommendations to oh-my-opencode.json
  --rollback             Rollback oh-my-opencode.json from backup
  --help, -h             Show this help
  --version, -v          Show version

Interactive keys (continuous mode):
  A/P/S/T/N/U            Sort by avg/p95/stability/tier/name/uptime
  1-9                    Toggle favorite on Nth model
  Q                      Quit

Environment:
  NVIDIA_API_KEY         API key for NVIDIA NIM

Examples:
  nimakai --once
  nimakai catalog --tier S
  nimakai -m qwen/qwen3.5-122b-a10b,qwen/qwen3.5-397b-a17b
  nimakai recommend --rounds 5 --apply
  nimakai --opencode --json
"""
        quit(0)
      of "version", "v":
        echo &"nimakai v{Version}"
        quit(0)
      else:
        stderr.writeLine &"Unknown option: {p.key}"
        quit(1)
    of cmdArgument:
      # Skip subcommand arg (already handled above)
      discard

# --- Terminal raw mode for interactive sorting ---

var origTermios: Termios
var rawModeEnabled = false

proc enableRawMode() =
  discard tcGetAttr(0.cint, addr origTermios)
  var raw = origTermios
  raw.c_lflag = raw.c_lflag and not (ICANON or ECHO)
  raw.c_cc[VMIN] = '\0'
  raw.c_cc[VTIME] = '\0'
  discard tcSetAttr(0.cint, TCSANOW, addr raw)
  rawModeEnabled = true

proc disableRawMode() =
  if rawModeEnabled:
    discard tcSetAttr(0.cint, TCSANOW, addr origTermios)
    rawModeEnabled = false

proc tryReadKey(): char =
  var buf: array[1, char]
  let n = read(0.cint, addr buf[0], 1)
  if n > 0: buf[0] else: '\0'

# --- Main ---

proc runBenchmark(cfg: Config, cat: seq[ModelMeta], favorites: seq[string]) =
  var stats: seq[ModelStats] = @[]
  for m in cfg.models:
    let meta = cat.lookupMeta(m)
    let name = if meta.isSome: meta.get.name else: m
    var s = ModelStats(id: m, name: name, lastHealth: hPending)
    if m in favorites: s.favorite = true
    stats.add(s)

  var sortCol = cfg.sortColumn
  var round = 0
  let interactive = not cfg.once and not cfg.jsonOutput and isatty(0.cint) != 0

  if interactive:
    enableRawMode()

  try:
    while true:
      inc round

      var results = newSeq[PingResult](stats.len)
      for i in 0..<results.len:
        results[i] = PingResult(health: hTimeout, ms: float(cfg.timeout * 1000))

      try:
        var m = createMaster(timeout = initDuration(seconds = cfg.timeout + 5))
        m.awaitAll:
          for i in 0..<stats.len:
            m.spawn doPing(cfg.apiKey, stats[i].id, cfg.timeout) -> results[i]
      except ValueError:
        discard

      for i in 0..<stats.len:
        let pr = results[i]
        stats[i].totalPings += 1
        stats[i].lastMs = pr.ms
        stats[i].lastHealth = pr.health
        if pr.health == hUp:
          stats[i].successPings += 1
          stats[i].addSample(pr.ms)

      # Sort before display
      sortStats(stats, sortCol, cat, cfg.thresholds)

      if cfg.jsonOutput:
        printJson(stats, round, cat, cfg.thresholds)
      else:
        if round > 1 or not cfg.once:
          stdout.write "\e[2J\e[H"
        printTable(stats, round, cat, sortCol, cfg.thresholds)

      # Persist to history
      appendRound(stats, round)

      if cfg.once:
        break

      # Wait for interval, checking for interactive input
      let deadline = epochTime() + cfg.interval.float
      while epochTime() < deadline:
        if interactive:
          let key = tryReadKey()
          case key
          of 'a', 'A': sortCol = scAvg
          of 'p', 'P': sortCol = scP95
          of 's', 'S': sortCol = scStability
          of 't', 'T': sortCol = scTier
          of 'n', 'N': sortCol = scName
          of 'u', 'U': sortCol = scUptime
          of '1'..'9':
            let idx = ord(key) - ord('1')
            if idx < stats.len:
              stats[idx].favorite = not stats[idx].favorite
              # Persist favorites
              var favs: seq[string] = @[]
              for s in stats:
                if s.favorite: favs.add(s.id)
              saveFavorites("", favs)
          of 'q', 'Q':
            disableRawMode()
            quit(0)
          else: discard
        sleep(50)
  finally:
    disableRawMode()

proc runRecommend(cfg: Config, cat: seq[ModelMeta]) =
  if cfg.rollback:
    discard rollbackOmo()
    return

  if cfg.apiKey.len == 0:
    stderr.writeLine "\e[31mError: NVIDIA_API_KEY required for benchmarking\e[0m"
    quit(1)

  # Determine models to benchmark from OMO config
  let omo = parseOmoConfig()
  var modelSet: seq[string] = @[]
  for c in omo.categories:
    if c.model notin modelSet:
      modelSet.add(c.model)
  # Also benchmark all catalog models that could be alternatives
  for m in cat:
    if m.id notin modelSet:
      modelSet.add(m.id)

  if not cfg.jsonOutput:
    stderr.writeLine &"\e[1m nimakai\e[0m v{Version}"
    stderr.writeLine &"\e[90m  recommend mode | {cfg.rounds} rounds | {modelSet.len} models\e[0m"

  var stats: seq[ModelStats] = @[]
  for m in modelSet:
    let meta = cat.lookupMeta(m)
    let name = if meta.isSome: meta.get.name else: m
    stats.add(ModelStats(id: m, name: name, lastHealth: hPending))

  # Run benchmark rounds
  for round in 1..cfg.rounds:
    if not cfg.jsonOutput:
      stderr.write &"\r\e[90m  round {round}/{cfg.rounds}...\e[0m"

    var results = newSeq[PingResult](stats.len)
    for i in 0..<results.len:
      results[i] = PingResult(health: hTimeout, ms: float(cfg.timeout * 1000))

    try:
      var m = createMaster(timeout = initDuration(seconds = cfg.timeout + 5))
      m.awaitAll:
        for i in 0..<stats.len:
          m.spawn doPing(cfg.apiKey, stats[i].id, cfg.timeout) -> results[i]
    except ValueError:
      discard

    for i in 0..<stats.len:
      let pr = results[i]
      stats[i].totalPings += 1
      stats[i].lastMs = pr.ms
      stats[i].lastHealth = pr.health
      if pr.health == hUp:
        stats[i].successPings += 1
        stats[i].addSample(pr.ms)

    if round < cfg.rounds:
      sleep(2000) # brief pause between rounds

  if not cfg.jsonOutput:
    stderr.writeLine "\r\e[90m  benchmarking complete.     \e[0m"

  let recs = recommend(stats, cat, omo, cfg.thresholds)

  if cfg.jsonOutput:
    echo $recommendationsToJson(recs)
  elif cfg.applySync:
    printRecommendations(recs, cfg.rounds)
    discard syncRecommendations(recs)
  else:
    printRecommendations(recs, cfg.rounds)

proc main() =
  let cfg = parseArgs()
  let cat = loadCatalog()

  case cfg.subcommand
  of smCatalog:
    var filtered = cat
    if cfg.tierFilter.len > 0:
      filtered = filterByTier(cat, cfg.tierFilter)
    printCatalog(filtered)
    return

  of smHistory:
    printHistory()
    return

  of smTrends:
    printTrends()
    return

  of smOpencode:
    let models = parseOpenCodeConfig()
    printOpenCodeModels(models)
    let omo = parseOmoConfig()
    printOmoRouting(omo)
    return

  of smRecommend:
    runRecommend(cfg, cat)
    return

  of smBenchmark:
    if cfg.apiKey.len == 0:
      stderr.writeLine "\e[31mError: NVIDIA_API_KEY environment variable not set\e[0m"
      stderr.writeLine "Get your key at https://build.nvidia.com"
      quit(1)

    # Determine model list
    var models = cfg.models
    if cfg.useOpencode:
      let ocModels = parseOpenCodeConfig()
      models = @[]
      for m in ocModels:
        models.add(m.id)
    if models.len == 0:
      # Default: use catalog models filtered by tier
      if cfg.tierFilter.len > 0:
        let filtered = filterByTier(cat, cfg.tierFilter)
        models = catalogModelIds(filtered)
      else:
        # Default subset: S+ and S tier only
        let filtered = filterByTier(cat, "S")
        models = catalogModelIds(filtered)

    var runCfg = cfg
    runCfg.models = models

    if not cfg.jsonOutput:
      stderr.writeLine &"\e[1m nimakai\e[0m v{Version}"
      stderr.writeLine &"\e[90m  {models.len} models | {cfg.interval}s interval | {cfg.timeout}s timeout | concurrent pings\e[0m"

    # Prune old history on startup
    pruneHistory()

    let fileCfg = loadConfigFile()
    runBenchmark(runCfg, cat, fileCfg.favorites)

main()
