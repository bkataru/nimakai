## JSONL persistence for benchmark history.
## Location: ~/.local/share/nimakai/history.jsonl

import std/[json, os, times, strutils, algorithm, math, tables]
import ./[types, metrics]

proc defaultHistoryPath*(): string =
  getHomeDir() / ".local" / "share" / "nimakai" / "history.jsonl"

proc appendRound*(stats: seq[ModelStats], round: int, path: string = "") =
  ## Append one benchmark round to the history file.
  let p = if path.len > 0: path else: defaultHistoryPath()
  let dir = parentDir(p)
  if not dirExists(dir):
    createDir(dir)

  var models = newJArray()
  for s in stats:
    models.add(%*{
      "id": s.id,
      "ms": s.lastMs,
      "health": $s.lastHealth,
      "avg": s.avg(),
      "p95": s.p95(),
      "stability": s.stabilityScore(),
    })

  let entry = %*{
    "ts": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "round": round,
    "models": models,
  }

  let f = open(p, fmAppend)
  f.writeLine($entry)
  f.close()

proc pruneHistory*(days: int = 30, path: string = "") =
  ## Remove entries older than `days` from the history file.
  let p = if path.len > 0: path else: defaultHistoryPath()
  if not fileExists(p): return

  let cutoff = now().utc - initDuration(days = days)
  let cutoffStr = cutoff.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

  var kept: seq[string] = @[]
  try:
    for line in lines(p):
      if line.strip().len == 0: continue
      try:
        let entry = parseJson(line)
        let ts = entry["ts"].getStr()
        if ts >= cutoffStr:
          kept.add(line)
      except CatchableError:
        kept.add(line) # keep unparseable lines
    writeFile(p, kept.join("\n") & (if kept.len > 0: "\n" else: ""))
  except CatchableError:
    discard

type HistoryEntry* = object
  ts*: string
  round*: int
  models*: seq[tuple[id: string, ms: float, health: string,
                      avg: float, p95: float, stability: int]]

proc loadHistory*(days: int = 30, path: string = ""): seq[HistoryEntry] =
  ## Load history entries from the last `days` days.
  let p = if path.len > 0: path else: defaultHistoryPath()
  if not fileExists(p): return @[]

  let cutoff = now().utc - initDuration(days = days)
  let cutoffStr = cutoff.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

  try:
    for line in lines(p):
      if line.strip().len == 0: continue
      try:
        let entry = parseJson(line)
        let ts = entry["ts"].getStr()
        if ts >= cutoffStr:
          var he: HistoryEntry
          he.ts = ts
          he.round = entry["round"].getInt()
          for m in entry["models"]:
            he.models.add((
              id: m["id"].getStr(),
              ms: m["ms"].getFloat(),
              health: m["health"].getStr(),
              avg: m["avg"].getFloat(),
              p95: m["p95"].getFloat(),
              stability: m["stability"].getInt(),
            ))
          result.add(he)
      except CatchableError:
        discard
  except CatchableError:
    discard

proc printHistory*(days: int = 7, path: string = "") =
  ## Print a summary of historical benchmark data.
  let entries = loadHistory(days, path)
  if entries.len == 0:
    echo "No history data found."
    return

  echo ""
  echo "\e[1m nimakai v" & Version & "\e[0m  \e[90mhistory | last " & $days & " days | " & $entries.len & " rounds\e[0m"
  echo ""

  # Aggregate per model
  type ModelAgg = object
    totalRounds: int
    sumAvg: float
    sumP95: float
    sumStab: int
    upRounds: int

  var aggTable = initTable[string, ModelAgg]()
  var modelOrder: seq[string] = @[]  # preserve insertion order

  for e in entries:
    for m in e.models:
      if m.id notin aggTable:
        aggTable[m.id] = ModelAgg()
        modelOrder.add(m.id)
      aggTable[m.id].totalRounds += 1
      aggTable[m.id].sumAvg += m.avg
      aggTable[m.id].sumP95 += m.p95
      aggTable[m.id].sumStab += m.stability
      if m.health == "UP":
        aggTable[m.id].upRounds += 1

  echo "\e[1;90m  " & padRight("MODEL", 35) & padLeft("AVG", 10) & padLeft("P95", 10) &
       padLeft("STAB", 8) & padLeft("UP%", 8) & padLeft("ROUNDS", 8) & "\e[0m"
  echo "\e[90m  " & "-".repeat(79) & "\e[0m"

  for id in modelOrder:
    let a = aggTable[id]
    let avgAvg = if a.totalRounds > 0: a.sumAvg / a.totalRounds.float else: 0.0
    let avgP95 = if a.totalRounds > 0: a.sumP95 / a.totalRounds.float else: 0.0
    let avgStab = if a.totalRounds > 0: a.sumStab div a.totalRounds else: 0
    let upPct = if a.totalRounds > 0: (a.upRounds.float / a.totalRounds.float) * 100.0 else: 0.0

    echo "  " & padRight(id, 35) &
      padLeft($int(avgAvg) & "ms", 10) &
      padLeft($int(avgP95) & "ms", 10) &
      padLeft($avgStab, 8) &
      padLeft($int(upPct) & "%", 8) &
      padLeft($a.totalRounds, 8)

  echo ""

type
  TrendDirection* = enum
    tdImproving = "improving"
    tdDegrading = "degrading"
    tdStable = "stable"
    tdInsufficient = "insufficient data"

  ModelTrend* = object
    id*: string
    direction*: TrendDirection
    avgChange*: float       ## percentage change in avg latency (negative = faster)
    stabilityChange*: int   ## change in stability score
    uptimeChange*: float    ## change in uptime percentage
    recentAvg*: float       ## avg latency in recent window
    olderAvg*: float        ## avg latency in older window

proc detectTrends*(entries: seq[HistoryEntry], minRounds: int = 6): seq[ModelTrend] =
  ## Detect latency trends by comparing the first half vs second half of history.
  ## Requires at least `minRounds` entries to produce meaningful results.
  if entries.len < minRounds: return @[]

  let mid = entries.len div 2
  let older = entries[0..<mid]
  let recent = entries[mid..^1]

  type Window = object
    sumAvg, sumP95: float
    sumStab, upCount, totalCount: int

  proc aggregate(window: seq[HistoryEntry]): Table[string, Window] =
    result = initTable[string, Window]()
    for e in window:
      for m in e.models:
        if m.id notin result:
          result[m.id] = Window()
        result[m.id].sumAvg += m.avg
        result[m.id].sumP95 += m.p95
        result[m.id].sumStab += m.stability
        result[m.id].totalCount += 1
        if m.health == "UP": result[m.id].upCount += 1

  let olderAggs = aggregate(older)
  let recentAggs = aggregate(recent)

  for id, ra in recentAggs:
    var trend: ModelTrend
    trend.id = id

    let hasOlder = id in olderAggs
    let olderW = if hasOlder: olderAggs[id] else: Window()

    if not hasOlder or olderW.totalCount == 0:
      trend.direction = tdInsufficient
      result.add(trend)
      continue

    let recentAvg = ra.sumAvg / ra.totalCount.float
    let olderAvg = olderW.sumAvg / olderW.totalCount.float
    let recentStab = ra.sumStab div ra.totalCount
    let olderStab = olderW.sumStab div olderW.totalCount
    let recentUp = ra.upCount.float / ra.totalCount.float * 100.0
    let olderUp = olderW.upCount.float / olderW.totalCount.float * 100.0

    trend.recentAvg = recentAvg
    trend.olderAvg = olderAvg
    trend.stabilityChange = recentStab - olderStab
    trend.uptimeChange = recentUp - olderUp

    if olderAvg > 0:
      trend.avgChange = (recentAvg - olderAvg) / olderAvg * 100.0

    # Classify: improving if avg dropped >10% or stability improved >10
    # Degrading if avg increased >10% or stability dropped >10
    if trend.avgChange < -10.0 or trend.stabilityChange > 10:
      trend.direction = tdImproving
    elif trend.avgChange > 10.0 or trend.stabilityChange < -10:
      trend.direction = tdDegrading
    else:
      trend.direction = tdStable

    result.add(trend)

proc printTrends*(days: int = 7, path: string = "") =
  ## Print trend analysis from historical data.
  let entries = loadHistory(days, path)
  let trends = detectTrends(entries)

  echo ""
  echo "\e[1m nimakai v" & Version & "\e[0m  \e[90mtrends | last " & $days & " days | " & $entries.len & " rounds\e[0m"
  echo ""

  if trends.len == 0:
    echo "  \e[90mNot enough data for trend analysis (need 6+ rounds).\e[0m"
    echo ""
    return

  echo "\e[1;90m  " & padRight("MODEL", 35) & padLeft("TREND", 14) &
       padLeft("AVG CHG", 10) & padLeft("STAB CHG", 10) & padLeft("RECENT", 10) &
       padLeft("OLDER", 10) & "\e[0m"
  echo "\e[90m  " & "-".repeat(89) & "\e[0m"

  var sorted = trends
  sorted.sort proc(a, b: ModelTrend): int =
    let order = [tdImproving: 1, tdDegrading: 0, tdStable: 2, tdInsufficient: 3]
    result = order[a.direction] - order[b.direction]
    if result == 0:
      result = cmp(abs(b.avgChange), abs(a.avgChange))

  for t in sorted:
    let dirColor = case t.direction
      of tdImproving: "\e[32m"
      of tdDegrading: "\e[31m"
      of tdStable: "\e[90m"
      of tdInsufficient: "\e[90m"
    let dirIcon = case t.direction
      of tdImproving: "^ improving"
      of tdDegrading: "v degrading"
      of tdStable: "= stable"
      of tdInsufficient: "? no data"
    let avgChg = if t.avgChange > 0: "+" & $int(t.avgChange) & "%"
                 elif t.avgChange < 0: $int(t.avgChange) & "%"
                 else: "0%"
    let stabChg = if t.stabilityChange > 0: "+" & $t.stabilityChange
                  elif t.stabilityChange < 0: $t.stabilityChange
                  else: "0"

    echo "  " & padRight(t.id, 35) &
         dirColor & padLeft(dirIcon, 14) & "\e[0m" &
         padLeft(avgChg, 10) &
         padLeft(stabChg, 10) &
         padLeft($int(t.recentAvg) & "ms", 10) &
         padLeft($int(t.olderAvg) & "ms", 10)

  echo ""
