import std/[math, unittest]
import nimakai/[types, metrics]

proc makeStats(pings: openArray[float], totalPings: int = -1,
               successPings: int = -1, lastHealth: Health = hUp): ModelStats =
  result.id = "test/model"
  result.lastHealth = lastHealth
  for p in pings:
    result.addSample(p)
  result.totalPings = if totalPings >= 0: totalPings else: pings.len
  result.successPings = if successPings >= 0: successPings else: pings.len
  if pings.len > 0:
    result.lastMs = pings[^1]

suite "avg":
  test "empty stats returns 0":
    let s = makeStats([])
    check s.avg() == 0.0

  test "single ping":
    let s = makeStats([500.0])
    check s.avg() == 500.0

  test "multiple pings":
    let s = makeStats([100.0, 200.0, 300.0])
    check abs(s.avg() - 200.0) < 0.01

suite "p50 (median)":
  test "empty returns 0":
    let s = makeStats([])
    check s.p50() == 0.0

  test "single value":
    let s = makeStats([42.0])
    check s.p50() == 42.0

  test "odd number of values":
    let s = makeStats([10.0, 30.0, 20.0])
    check s.p50() == 20.0

  test "even number of values":
    let s = makeStats([10.0, 20.0, 30.0, 40.0])
    check s.p50() == 25.0

suite "p95":
  test "less than 2 pings falls back to avg":
    let s = makeStats([500.0])
    check s.p95() == 500.0

  test "correct percentile with 20 values":
    var pings: seq[float] = @[]
    for i in 1..20:
      pings.add(float(i * 100))
    let s = makeStats(pings)
    # 95th percentile of 100..2000
    check s.p95() >= 1900.0

suite "p99":
  test "less than 2 pings falls back to avg":
    let s = makeStats([500.0])
    check s.p99() == 500.0

  test "correct with many values":
    var pings: seq[float] = @[]
    for i in 1..100:
      pings.add(float(i))
    let s = makeStats(pings)
    check s.p99() >= 99.0

suite "minMs / maxMs":
  test "empty returns 0":
    let s = makeStats([])
    check s.minMs() == 0.0
    check s.maxMs() == 0.0

  test "single value":
    let s = makeStats([42.0])
    check s.minMs() == 42.0
    check s.maxMs() == 42.0

  test "multiple values":
    let s = makeStats([300.0, 100.0, 500.0, 200.0])
    check s.minMs() == 100.0
    check s.maxMs() == 500.0

suite "jitter":
  test "single ping returns 0":
    let s = makeStats([500.0])
    check s.jitter() == 0.0

  test "identical pings return 0":
    let s = makeStats([100.0, 100.0, 100.0])
    check s.jitter() == 0.0

  test "varied pings have positive jitter":
    let s = makeStats([100.0, 200.0, 300.0])
    check s.jitter() > 0.0

  test "higher variance means higher jitter":
    let low = makeStats([99.0, 100.0, 101.0])
    let high = makeStats([10.0, 100.0, 500.0])
    check high.jitter() > low.jitter()

suite "uptime":
  test "no pings returns 0":
    var s: ModelStats
    check s.uptime() == 0.0

  test "100% when all succeed":
    let s = makeStats([100.0, 200.0], totalPings = 2, successPings = 2)
    check s.uptime() == 100.0

  test "0% when none succeed":
    var s: ModelStats
    s.totalPings = 5
    s.successPings = 0
    check s.uptime() == 0.0

  test "partial uptime":
    var s: ModelStats
    s.totalPings = 10
    s.successPings = 7
    check abs(s.uptime() - 70.0) < 0.01

suite "spikeRate":
  test "empty returns 0":
    let s = makeStats([])
    check s.spikeRate() == 0.0

  test "no spikes":
    let s = makeStats([100.0, 200.0, 500.0])
    check s.spikeRate(3000.0) == 0.0

  test "all spikes":
    let s = makeStats([4000.0, 5000.0, 6000.0])
    check s.spikeRate(3000.0) == 1.0

  test "partial spikes":
    let s = makeStats([100.0, 200.0, 4000.0, 5000.0])
    check abs(s.spikeRate(3000.0) - 0.5) < 0.01

suite "stabilityScore":
  test "empty returns -1":
    let s = makeStats([])
    check s.stabilityScore() == -1

  test "fast stable pings give high score":
    let s = makeStats([100.0, 110.0, 105.0, 108.0, 102.0],
                      totalPings = 5, successPings = 5)
    let score = s.stabilityScore()
    check score >= 80

  test "slow erratic pings give low score":
    let s = makeStats([4000.0, 100.0, 4500.0, 200.0, 4800.0],
                      totalPings = 5, successPings = 5)
    let score = s.stabilityScore()
    check score < 50

  test "score is bounded 0-100":
    let fast = makeStats([10.0, 11.0, 12.0], totalPings = 3, successPings = 3)
    let slow = makeStats([4999.0, 4998.0, 4997.0], totalPings = 3, successPings = 3)
    check fast.stabilityScore() <= 100
    check slow.stabilityScore() >= 0

suite "verdict":
  test "Pending when no pings":
    var s: ModelStats
    check s.verdict() == vPending

  test "NotFound when last health is hNotFound":
    var s: ModelStats
    s.totalPings = 1
    s.lastHealth = hNotFound
    check s.verdict() == vNotFound

  test "NotActive when pings attempted but none succeeded":
    var s: ModelStats
    s.totalPings = 3
    s.successPings = 0
    s.lastHealth = hTimeout
    check s.verdict() == vNotActive

  test "Perfect when avg < 400 and p95 < 800":
    let s = makeStats([200.0, 250.0, 300.0, 280.0, 220.0])
    check s.verdict() == vPerfect

  test "Normal when avg < 1000 and p95 < 2000":
    let s = makeStats([800.0, 850.0, 900.0, 750.0, 820.0])
    check s.verdict() == vNormal

  test "Spiky when p95 >> avg with 3+ pings":
    let s = makeStats([100.0, 100.0, 100.0, 100.0, 4000.0])
    check s.verdict() == vSpiky

  test "Slow when avg < 2000":
    let s = makeStats([1500.0, 1600.0, 1700.0])
    check s.verdict() == vSlow

  test "Very Slow when avg < 5000":
    let s = makeStats([3000.0, 3500.0, 4000.0])
    check s.verdict() == vVerySlow

  test "Unstable when avg >= 5000":
    let s = makeStats([5000.0, 6000.0, 7000.0])
    check s.verdict() == vUnstable

  test "custom thresholds":
    let th = Thresholds(perfectAvg: 200, perfectP95: 400,
                        normalAvg: 500, normalP95: 1000, spikeMs: 2000)
    let s = makeStats([300.0, 350.0, 280.0])
    # avg ~310, p95 ~350 -> Normal with custom thresholds
    check s.verdict(th) == vNormal

suite "ring buffer wrapping":
  test "ring buffer correctly wraps and metrics still work":
    var s: ModelStats
    s.totalPings = MaxSamples + 20
    s.successPings = MaxSamples + 20
    # Fill ring with increasing values, wrapping
    for i in 0..<MaxSamples + 20:
      s.addSample(float(100 + i))
    s.lastMs = float(100 + MaxSamples + 19)
    s.lastHealth = hUp

    check s.ringLen == MaxSamples
    check s.avg() > 0
    check s.p95() > 0
    check s.jitter() > 0
    check s.minMs() > 0
    check s.maxMs() > s.minMs()
