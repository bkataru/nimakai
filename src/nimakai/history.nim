## JSONL persistence for benchmark history.
## Location: ~/.local/share/nimakai/history.jsonl

import std/[json, os, times, strutils, algorithm, math]
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

  var aggs: seq[tuple[id: string, agg: ModelAgg]] = @[]

  proc findOrAdd(id: string): int =
    for i in 0..<aggs.len:
      if aggs[i].id == id: return i
    aggs.add((id: id, agg: ModelAgg()))
    return aggs.len - 1

  for e in entries:
    for m in e.models:
      let idx = findOrAdd(m.id)
      aggs[idx].agg.totalRounds += 1
      aggs[idx].agg.sumAvg += m.avg
      aggs[idx].agg.sumP95 += m.p95
      aggs[idx].agg.sumStab += m.stability
      if m.health == "UP":
        aggs[idx].agg.upRounds += 1

  proc pad(s: string, w: int): string =
    if s.len >= w: s[0..<w] else: s & ' '.repeat(w - s.len)
  proc padL(s: string, w: int): string =
    if s.len >= w: s[0..<w] else: ' '.repeat(w - s.len) & s

  echo "\e[1;90m  " & pad("MODEL", 35) & padL("AVG", 10) & padL("P95", 10) &
       padL("STAB", 8) & padL("UP%", 8) & padL("ROUNDS", 8) & "\e[0m"
  echo "\e[90m  " & "-".repeat(79) & "\e[0m"

  for (id, a) in aggs:
    let avgAvg = if a.totalRounds > 0: a.sumAvg / a.totalRounds.float else: 0.0
    let avgP95 = if a.totalRounds > 0: a.sumP95 / a.totalRounds.float else: 0.0
    let avgStab = if a.totalRounds > 0: a.sumStab div a.totalRounds else: 0
    let upPct = if a.totalRounds > 0: (a.upRounds.float / a.totalRounds.float) * 100.0 else: 0.0

    echo "  " & pad(id, 35) &
      padL($int(avgAvg) & "ms", 10) &
      padL($int(avgP95) & "ms", 10) &
      padL($avgStab, 8) &
      padL($int(upPct) & "%", 8) &
      padL($a.totalRounds, 8)

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

  proc aggregate(window: seq[HistoryEntry]): seq[tuple[id: string, w: Window]] =
    for e in window:
      for m in e.models:
        var found = false
        for i in 0..<result.len:
          if result[i].id == m.id:
            result[i].w.sumAvg += m.avg
            result[i].w.sumP95 += m.p95
            result[i].w.sumStab += m.stability
            result[i].w.totalCount += 1
            if m.health == "UP": result[i].w.upCount += 1
            found = true
            break
        if not found:
          var w: Window
          w.sumAvg = m.avg
          w.sumP95 = m.p95
          w.sumStab = m.stability
          w.totalCount = 1
          if m.health == "UP": w.upCount = 1
          result.add((id: m.id, w: w))

  let olderAggs = aggregate(older)
  let recentAggs = aggregate(recent)

  for ra in recentAggs:
    var trend: ModelTrend
    trend.id = ra.id

    var olderW: Window
    var hasOlder = false
    for oa in olderAggs:
      if oa.id == ra.id:
        olderW = oa.w
        hasOlder = true
        break

    if not hasOlder or olderW.totalCount == 0:
      trend.direction = tdInsufficient
      result.add(trend)
      continue

    let recentAvg = ra.w.sumAvg / ra.w.totalCount.float
    let olderAvg = olderW.sumAvg / olderW.totalCount.float
    let recentStab = ra.w.sumStab div ra.w.totalCount
    let olderStab = olderW.sumStab div olderW.totalCount
    let recentUp = ra.w.upCount.float / ra.w.totalCount.float * 100.0
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

  proc pad(s: string, w: int): string =
    if s.len >= w: s[0..<w] else: s & ' '.repeat(w - s.len)
  proc padL(s: string, w: int): string =
    if s.len >= w: s[0..<w] else: ' '.repeat(w - s.len) & s

  echo "\e[1;90m  " & pad("MODEL", 35) & padL("TREND", 14) &
       padL("AVG CHG", 10) & padL("STAB CHG", 10) & padL("RECENT", 10) &
       padL("OLDER", 10) & "\e[0m"
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

    echo "  " & pad(t.id, 35) &
         dirColor & padL(dirIcon, 14) & "\e[0m" &
         padL(avgChg, 10) &
         padL(stabChg, 10) &
         padL($int(t.recentAvg) & "ms", 10) &
         padL($int(t.olderAvg) & "ms", 10)

  echo ""
