## JSONL persistence for benchmark history.
## Location: ~/.local/share/nimakai/history.jsonl

import std/[json, os, times, strutils]
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
