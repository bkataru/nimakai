import std/[unittest, json, os, strutils, times]
import nimakai/[history, types, metrics]

proc testDir(): string =
  getTempDir() / "test_history_" & $getCurrentProcessId()

proc setup(): string =
  let d = testDir()
  if dirExists(d): removeDir(d)
  createDir(d)
  d

proc teardown(d: string) =
  if dirExists(d): removeDir(d)

proc makeStats(id: string, ms: float, health: Health = hUp,
               totalPings: int = 10, successPings: int = 9): ModelStats =
  result.id = id
  result.name = id
  result.lastMs = ms
  result.lastHealth = health
  result.totalPings = totalPings
  result.successPings = successPings
  result.addSample(ms)

# ---------- appendRound ----------

suite "appendRound":
  test "writes JSONL with correct format":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    let stats = @[makeStats("model/a", 250.0), makeStats("model/b", 800.0)]
    appendRound(stats, round = 1, path = p)

    check fileExists(p)
    let content = readFile(p).strip()
    let entry = parseJson(content)

    check entry.hasKey("ts")
    check entry.hasKey("round")
    check entry.hasKey("models")
    check entry["round"].getInt() == 1
    check entry["models"].len == 2
    check entry["models"][0]["id"].getStr() == "model/a"
    check entry["models"][1]["id"].getStr() == "model/b"
    check entry["models"][0]["ms"].getFloat() == 250.0
    check entry["models"][1]["ms"].getFloat() == 800.0
    check entry["models"][0]["health"].getStr() == "UP"

    # Verify timestamp is valid ISO 8601 UTC
    let ts = entry["ts"].getStr()
    check ts.endsWith("Z")
    check ts.len == 20 # "2026-03-08T12:34:56Z"

  test "each model entry has avg, p95, stability fields":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    let stats = @[makeStats("model/x", 300.0, totalPings = 5, successPings = 5)]
    appendRound(stats, round = 1, path = p)

    let entry = parseJson(readFile(p).strip())
    let m = entry["models"][0]
    check m.hasKey("avg")
    check m.hasKey("p95")
    check m.hasKey("stability")
    check m["avg"].getFloat() == 300.0
    check m["p95"].getFloat() == 300.0

  test "appends multiple rounds as separate JSONL lines":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    let s1 = @[makeStats("model/a", 200.0)]
    let s2 = @[makeStats("model/a", 400.0)]
    let s3 = @[makeStats("model/b", 600.0)]

    appendRound(s1, round = 1, path = p)
    appendRound(s2, round = 2, path = p)
    appendRound(s3, round = 3, path = p)

    var lineCount = 0
    for line in lines(p):
      if line.strip().len > 0:
        inc lineCount
        let entry = parseJson(line)
        check entry["round"].getInt() == lineCount
    check lineCount == 3

  test "creates parent directories if needed":
    let d = setup()
    defer: teardown(d)
    let p = d / "sub" / "dir" / "history.jsonl"

    appendRound(@[makeStats("m", 100.0)], round = 1, path = p)
    check fileExists(p)

  test "handles empty stats seq":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    appendRound(@[], round = 1, path = p)

    let entry = parseJson(readFile(p).strip())
    check entry["round"].getInt() == 1
    check entry["models"].len == 0

# ---------- pruneHistory ----------

suite "pruneHistory":
  test "removes entries older than specified days":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    let old = (now().utc - initDuration(days = 60)).format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    let recent = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

    let oldEntry = %*{"ts": old, "round": 1, "models": []}
    let recentEntry = %*{"ts": recent, "round": 2, "models": []}
    writeFile(p, $oldEntry & "\n" & $recentEntry & "\n")

    pruneHistory(days = 30, path = p)

    var kept: seq[string] = @[]
    for line in lines(p):
      if line.strip().len > 0:
        kept.add(line)
    check kept.len == 1
    check parseJson(kept[0])["round"].getInt() == 2

  test "keeps all entries when none are expired":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    let ts1 = (now().utc - initDuration(days = 5)).format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    let ts2 = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

    let e1 = %*{"ts": ts1, "round": 1, "models": []}
    let e2 = %*{"ts": ts2, "round": 2, "models": []}
    writeFile(p, $e1 & "\n" & $e2 & "\n")

    pruneHistory(days = 30, path = p)

    var count = 0
    for line in lines(p):
      if line.strip().len > 0: inc count
    check count == 2

  test "removes all entries when all are expired":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    let old1 = (now().utc - initDuration(days = 90)).format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    let old2 = (now().utc - initDuration(days = 60)).format("yyyy-MM-dd'T'HH:mm:ss'Z'")

    let e1 = %*{"ts": old1, "round": 1, "models": []}
    let e2 = %*{"ts": old2, "round": 2, "models": []}
    writeFile(p, $e1 & "\n" & $e2 & "\n")

    pruneHistory(days = 30, path = p)

    let content = readFile(p).strip()
    check content.len == 0

  test "handles nonexistent file gracefully":
    let d = setup()
    defer: teardown(d)
    let p = d / "nonexistent.jsonl"

    # Should not raise
    pruneHistory(days = 30, path = p)
    check not fileExists(p)

  test "keeps malformed lines":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    let recent = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    let good = %*{"ts": recent, "round": 1, "models": []}
    writeFile(p, "this is not json\n" & $good & "\n")

    pruneHistory(days = 30, path = p)

    var kept: seq[string] = @[]
    for line in lines(p):
      if line.strip().len > 0:
        kept.add(line)
    # Both the malformed line and the good entry should be kept
    check kept.len == 2
    check kept[0] == "this is not json"

  test "skips blank lines":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    let recent = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    let e = %*{"ts": recent, "round": 1, "models": []}
    writeFile(p, "\n\n" & $e & "\n\n")

    pruneHistory(days = 30, path = p)

    var count = 0
    for line in lines(p):
      if line.strip().len > 0: inc count
    check count == 1

  test "custom days parameter works":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    let ts10 = (now().utc - initDuration(days = 10)).format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    let ts3 = (now().utc - initDuration(days = 3)).format("yyyy-MM-dd'T'HH:mm:ss'Z'")

    let e1 = %*{"ts": ts10, "round": 1, "models": []}
    let e2 = %*{"ts": ts3, "round": 2, "models": []}
    writeFile(p, $e1 & "\n" & $e2 & "\n")

    # Prune with 7-day window: should remove 10-day-old entry
    pruneHistory(days = 7, path = p)

    var kept: seq[string] = @[]
    for line in lines(p):
      if line.strip().len > 0: kept.add(line)
    check kept.len == 1
    check parseJson(kept[0])["round"].getInt() == 2

# ---------- loadHistory ----------

suite "loadHistory":
  test "parses JSONL and returns structured data":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    let ts = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    let entry = %*{
      "ts": ts,
      "round": 5,
      "models": [
        {"id": "model/a", "ms": 250.0, "health": "UP",
         "avg": 250.0, "p95": 250.0, "stability": 85},
        {"id": "model/b", "ms": 800.0, "health": "TIMEOUT",
         "avg": 800.0, "p95": 800.0, "stability": 60}
      ]
    }
    writeFile(p, $entry & "\n")

    let entries = loadHistory(days = 30, path = p)
    check entries.len == 1
    check entries[0].ts == ts
    check entries[0].round == 5
    check entries[0].models.len == 2
    check entries[0].models[0].id == "model/a"
    check entries[0].models[0].ms == 250.0
    check entries[0].models[0].health == "UP"
    check entries[0].models[0].avg == 250.0
    check entries[0].models[0].p95 == 250.0
    check entries[0].models[0].stability == 85
    check entries[0].models[1].id == "model/b"
    check entries[0].models[1].health == "TIMEOUT"

  test "loads multiple entries":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    let ts1 = (now().utc - initDuration(days = 2)).format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    let ts2 = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

    let e1 = %*{"ts": ts1, "round": 1, "models": [
      {"id": "m1", "ms": 100.0, "health": "UP", "avg": 100.0, "p95": 100.0, "stability": 90}
    ]}
    let e2 = %*{"ts": ts2, "round": 2, "models": [
      {"id": "m2", "ms": 200.0, "health": "UP", "avg": 200.0, "p95": 200.0, "stability": 80}
    ]}
    writeFile(p, $e1 & "\n" & $e2 & "\n")

    let entries = loadHistory(days = 30, path = p)
    check entries.len == 2
    check entries[0].round == 1
    check entries[1].round == 2

  test "returns empty seq for empty file":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    writeFile(p, "")

    let entries = loadHistory(days = 30, path = p)
    check entries.len == 0

  test "returns empty seq for nonexistent file":
    let d = setup()
    defer: teardown(d)
    let p = d / "nonexistent.jsonl"

    let entries = loadHistory(days = 30, path = p)
    check entries.len == 0

  test "skips malformed lines gracefully":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    let ts = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    let good = %*{"ts": ts, "round": 1, "models": [
      {"id": "m1", "ms": 100.0, "health": "UP", "avg": 100.0, "p95": 100.0, "stability": 90}
    ]}
    writeFile(p, "not json at all\n" & $good & "\n{\"broken\n")

    let entries = loadHistory(days = 30, path = p)
    check entries.len == 1
    check entries[0].round == 1

  test "filters out entries older than days parameter":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    let old = (now().utc - initDuration(days = 60)).format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    let recent = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

    let e1 = %*{"ts": old, "round": 1, "models": []}
    let e2 = %*{"ts": recent, "round": 2, "models": []}
    writeFile(p, $e1 & "\n" & $e2 & "\n")

    let entries = loadHistory(days = 30, path = p)
    check entries.len == 1
    check entries[0].round == 2

  test "custom days parameter filters correctly":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    let ts5 = (now().utc - initDuration(days = 5)).format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    let ts15 = (now().utc - initDuration(days = 15)).format("yyyy-MM-dd'T'HH:mm:ss'Z'")

    let e1 = %*{"ts": ts15, "round": 1, "models": []}
    let e2 = %*{"ts": ts5, "round": 2, "models": []}
    writeFile(p, $e1 & "\n" & $e2 & "\n")

    # 7-day window: only the 5-day-old entry should load
    let entries = loadHistory(days = 7, path = p)
    check entries.len == 1
    check entries[0].round == 2

    # 30-day window: both entries should load
    let all = loadHistory(days = 30, path = p)
    check all.len == 2

  test "skips blank lines in file":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    let ts = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    let e = %*{"ts": ts, "round": 1, "models": []}
    writeFile(p, "\n\n" & $e & "\n\n")

    let entries = loadHistory(days = 30, path = p)
    check entries.len == 1

# ---------- integration: appendRound + loadHistory ----------

suite "appendRound + loadHistory integration":
  test "round-trip: append then load":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    var s = makeStats("nvidia/llama-3.1-8b", 350.0, hUp,
                      totalPings = 20, successPings = 18)
    # Add a few more samples for meaningful p95/stability
    s.addSample(400.0)
    s.addSample(500.0)

    appendRound(@[s], round = 1, path = p)
    appendRound(@[s], round = 2, path = p)

    let entries = loadHistory(days = 30, path = p)
    check entries.len == 2
    check entries[0].round == 1
    check entries[1].round == 2
    check entries[0].models[0].id == "nvidia/llama-3.1-8b"
    check entries[0].models[0].ms == 350.0
    check entries[0].models[0].health == "UP"
    # avg and p95 should be computed from the ring buffer
    check entries[0].models[0].avg > 0.0
    check entries[0].models[0].p95 > 0.0

  test "round-trip: append, prune, load":
    let d = setup()
    defer: teardown(d)
    let p = d / "history.jsonl"

    # Write an old entry manually, then append a fresh one
    let old = (now().utc - initDuration(days = 60)).format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    let oldEntry = %*{"ts": old, "round": 1, "models": [
      {"id": "old/model", "ms": 100.0, "health": "UP",
       "avg": 100.0, "p95": 100.0, "stability": 90}
    ]}
    writeFile(p, $oldEntry & "\n")

    appendRound(@[makeStats("new/model", 200.0)], round = 2, path = p)

    # Before prune: loadHistory with large window should see both
    let before = loadHistory(days = 90, path = p)
    check before.len == 2

    # Prune at 30 days
    pruneHistory(days = 30, path = p)

    # After prune: only the fresh entry remains
    let after = loadHistory(days = 90, path = p)
    check after.len == 1
    check after[0].round == 2
    check after[0].models[0].id == "new/model"

# ---------- detectTrends ----------

suite "detectTrends":
  test "returns empty with insufficient data":
    let entries: seq[HistoryEntry] = @[]
    check detectTrends(entries).len == 0

    # Less than 6 rounds
    var few: seq[HistoryEntry] = @[]
    for i in 1..5:
      few.add(HistoryEntry(ts: "2026-03-08T00:00:00Z", round: i, models: @[]))
    check detectTrends(few).len == 0

  test "detects stable model":
    var entries: seq[HistoryEntry] = @[]
    for i in 1..10:
      entries.add(HistoryEntry(
        ts: "2026-03-08T00:00:00Z",
        round: i,
        models: @[(id: "test/model", ms: 300.0, health: "UP",
                   avg: 300.0, p95: 350.0, stability: 85)],
      ))
    let trends = detectTrends(entries)
    check trends.len == 1
    check trends[0].id == "test/model"
    check trends[0].direction == tdStable
    check abs(trends[0].avgChange) < 10.0

  test "detects degrading model":
    var entries: seq[HistoryEntry] = @[]
    # First half: fast
    for i in 1..5:
      entries.add(HistoryEntry(
        ts: "2026-03-08T00:00:00Z",
        round: i,
        models: @[(id: "test/model", ms: 200.0, health: "UP",
                   avg: 200.0, p95: 250.0, stability: 90)],
      ))
    # Second half: slow (>10% increase)
    for i in 6..10:
      entries.add(HistoryEntry(
        ts: "2026-03-08T00:00:00Z",
        round: i,
        models: @[(id: "test/model", ms: 500.0, health: "UP",
                   avg: 500.0, p95: 600.0, stability: 70)],
      ))
    let trends = detectTrends(entries)
    check trends.len == 1
    check trends[0].direction == tdDegrading
    check trends[0].avgChange > 10.0

  test "detects improving model":
    var entries: seq[HistoryEntry] = @[]
    # First half: slow
    for i in 1..5:
      entries.add(HistoryEntry(
        ts: "2026-03-08T00:00:00Z",
        round: i,
        models: @[(id: "test/model", ms: 800.0, health: "UP",
                   avg: 800.0, p95: 900.0, stability: 60)],
      ))
    # Second half: fast (>10% decrease)
    for i in 6..10:
      entries.add(HistoryEntry(
        ts: "2026-03-08T00:00:00Z",
        round: i,
        models: @[(id: "test/model", ms: 300.0, health: "UP",
                   avg: 300.0, p95: 350.0, stability: 90)],
      ))
    let trends = detectTrends(entries)
    check trends.len == 1
    check trends[0].direction == tdImproving
    check trends[0].avgChange < -10.0

  test "tracks multiple models independently":
    var entries: seq[HistoryEntry] = @[]
    for i in 1..5:
      entries.add(HistoryEntry(
        ts: "2026-03-08T00:00:00Z",
        round: i,
        models: @[
          (id: "fast/model", ms: 200.0, health: "UP",
           avg: 200.0, p95: 250.0, stability: 90),
          (id: "slow/model", ms: 500.0, health: "UP",
           avg: 500.0, p95: 600.0, stability: 70),
        ],
      ))
    for i in 6..10:
      entries.add(HistoryEntry(
        ts: "2026-03-08T00:00:00Z",
        round: i,
        models: @[
          (id: "fast/model", ms: 200.0, health: "UP",
           avg: 200.0, p95: 250.0, stability: 90),
          (id: "slow/model", ms: 1500.0, health: "UP",
           avg: 1500.0, p95: 1800.0, stability: 40),
        ],
      ))
    let trends = detectTrends(entries)
    check trends.len == 2
    # fast/model should be stable
    var fastTrend, slowTrend: ModelTrend
    for t in trends:
      if t.id == "fast/model": fastTrend = t
      if t.id == "slow/model": slowTrend = t
    check fastTrend.direction == tdStable
    check slowTrend.direction == tdDegrading

  test "model only in recent window gets insufficient":
    var entries: seq[HistoryEntry] = @[]
    # First half: only model A
    for i in 1..5:
      entries.add(HistoryEntry(
        ts: "2026-03-08T00:00:00Z",
        round: i,
        models: @[(id: "old/model", ms: 300.0, health: "UP",
                   avg: 300.0, p95: 350.0, stability: 85)],
      ))
    # Second half: model A + new model B
    for i in 6..10:
      entries.add(HistoryEntry(
        ts: "2026-03-08T00:00:00Z",
        round: i,
        models: @[
          (id: "old/model", ms: 300.0, health: "UP",
           avg: 300.0, p95: 350.0, stability: 85),
          (id: "new/model", ms: 400.0, health: "UP",
           avg: 400.0, p95: 450.0, stability: 80),
        ],
      ))
    let trends = detectTrends(entries)
    var newTrend: ModelTrend
    for t in trends:
      if t.id == "new/model": newTrend = t
    check newTrend.direction == tdInsufficient
