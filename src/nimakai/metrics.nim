## Pure metric calculation functions for nimakai.
## All procs are side-effect-free and operate on ModelStats data.

import std/[math, algorithm]
import ./types

proc avg*(stats: ModelStats): float =
  if stats.ringLen == 0: return 0.0
  var sum = 0.0
  for i in 0..<stats.ringLen:
    sum += stats.ring[i]
  sum / stats.ringLen.float

proc p50*(stats: ModelStats): float =
  if stats.ringLen == 0: return 0.0
  if stats.ringLen == 1: return stats.ring[0]
  var s = stats.samples()
  s.sort()
  let mid = s.len div 2
  if s.len mod 2 == 0:
    (s[mid - 1] + s[mid]) / 2.0
  else:
    s[mid].float

proc percentile(stats: ModelStats, pct: float): float =
  if stats.ringLen < 2: return stats.avg()
  var s = stats.samples()
  s.sort()
  let idx = min(int(ceil(s.len.float * pct)) - 1, s.len - 1)
  s[idx]

proc p95*(stats: ModelStats): float =
  stats.percentile(0.95)

proc p99*(stats: ModelStats): float =
  stats.percentile(0.99)

proc minMs*(stats: ModelStats): float =
  if stats.ringLen == 0: return 0.0
  result = stats.ring[0]
  for i in 1..<stats.ringLen:
    if stats.ring[i] < result: result = stats.ring[i]

proc maxMs*(stats: ModelStats): float =
  if stats.ringLen == 0: return 0.0
  result = stats.ring[0]
  for i in 1..<stats.ringLen:
    if stats.ring[i] > result: result = stats.ring[i]

proc jitter*(stats: ModelStats): float =
  if stats.ringLen < 2: return 0.0
  let mean = stats.avg()
  var sumSq = 0.0
  for i in 0..<stats.ringLen:
    let d = stats.ring[i] - mean
    sumSq += d * d
  sqrt(sumSq / stats.ringLen.float)

proc uptime*(stats: ModelStats): float =
  if stats.totalPings == 0: return 0.0
  (stats.successPings.float / stats.totalPings.float) * 100.0

proc spikeRate*(stats: ModelStats, threshold: float = 3000.0): float =
  if stats.ringLen == 0: return 0.0
  var count = 0
  for i in 0..<stats.ringLen:
    if stats.ring[i] > threshold: inc count
  count.float / stats.ringLen.float

proc stabilityScore*(stats: ModelStats, th: Thresholds = DefaultThresholds): int =
  ## Composite stability score 0-100 (higher = more stable).
  ## Returns -1 when insufficient data.
  if stats.ringLen == 0: return -1
  let p95val = stats.p95()
  let jit = stats.jitter()
  let up = stats.uptime()
  let spikes = stats.spikeRate(th.spikeMs)

  let p95Score = clamp(100.0 * (1.0 - p95val / 5000.0), 0.0, 100.0)
  let jitScore = clamp(100.0 * (1.0 - jit / 2000.0), 0.0, 100.0)
  let spikeScore = clamp(100.0 * (1.0 - spikes), 0.0, 100.0)
  let reliScore = up

  let score = 0.30 * p95Score + 0.30 * jitScore + 0.20 * spikeScore + 0.20 * reliScore
  clamp(int(score), 0, 100)

proc verdict*(stats: ModelStats, th: Thresholds = DefaultThresholds): Verdict =
  if stats.totalPings == 0: return vPending
  if stats.lastHealth == hNotFound: return vNotFound
  if stats.ringLen == 0:
    return vNotActive
  let a = stats.avg()
  let p = stats.p95()
  if a < th.perfectAvg and p < th.perfectP95: return vPerfect
  if a < th.normalAvg and p < th.normalP95: return vNormal
  if stats.ringLen >= 3 and p > a * 2.5: return vSpiky
  if a < 2000: return vSlow
  if a < 5000: return vVerySlow
  return vUnstable
