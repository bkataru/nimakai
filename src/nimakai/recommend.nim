## Recommendation engine for optimal model routing.
## Scores models based on latency metrics and model capabilities
## to suggest routing changes for oh-my-opencode categories.

import std/[strutils, strformat, json, options]
import ./[types, metrics, catalog, opencode]

type
  CategoryNeed* = enum
    cnSpeed
    cnQuality
    cnBalance
    cnVision
    cnReliability

  Recommendation* = object
    category*: string
    currentModel*: string
    recommendedModel*: string
    reason*: string
    currentScore*: float
    recommendedScore*: float

proc categorizeNeed*(name: string): CategoryNeed =
  case name
  of "quick", "unspecified-low": cnSpeed
  of "deep", "artistry": cnQuality
  of "ultrabrain": cnReliability
  of "visual-engineering": cnVision
  else: cnBalance

type Weights = object
  swe, speed, ctx, stability: float

proc weightsFor(need: CategoryNeed): Weights =
  case need
  of cnSpeed: Weights(swe: 0.15, speed: 0.55, ctx: 0.10, stability: 0.20)
  of cnQuality: Weights(swe: 0.45, speed: 0.10, ctx: 0.25, stability: 0.20)
  of cnReliability: Weights(swe: 0.25, speed: 0.20, ctx: 0.15, stability: 0.40)
  of cnVision: Weights(swe: 0.30, speed: 0.20, ctx: 0.20, stability: 0.30)
  of cnBalance: Weights(swe: 0.30, speed: 0.30, ctx: 0.15, stability: 0.25)

proc scoreModel*(stats: ModelStats, meta: ModelMeta, need: CategoryNeed,
                 th: Thresholds = DefaultThresholds): float =
  ## Score a model 0-100 for a given category need.
  let w = weightsFor(need)

  # SWE score (0-100, already in percent)
  let sweScore = meta.sweScore

  # Speed score (lower latency = higher score)
  let avgMs = stats.avg()
  let speedScore = if avgMs <= 0: 0.0
                   else: clamp(100.0 * (1.0 - avgMs / 5000.0), 0.0, 100.0)

  # Context score (larger = better, normalized to 256k baseline)
  let ctxScore = clamp(meta.ctxSize.float / 262144.0 * 100.0, 0.0, 100.0)

  # Stability score
  let stabScore = stats.stabilityScore(th).float
  let stabNorm = if stabScore < 0: 50.0 else: stabScore

  var score = w.swe * sweScore + w.speed * speedScore +
              w.ctx * ctxScore + w.stability * stabNorm

  # Vision penalty: non-multimodal models get 80% penalty for vision needs
  if need == cnVision and not meta.multimodal:
    score *= 0.20

  score

proc recommend*(stats: seq[ModelStats], cat: seq[ModelMeta],
                omo: OmoConfig,
                th: Thresholds = DefaultThresholds): seq[Recommendation] =
  ## Generate routing recommendations for each OMO category.
  for omocat in omo.categories:
    let need = categorizeNeed(omocat.name)
    var bestModel = ""
    var bestScore = -1.0
    var currentScore = -1.0

    for s in stats:
      let meta = cat.lookupMeta(s.id)
      if meta.isNone: continue
      if s.ringLen == 0: continue # no data

      let score = scoreModel(s, meta.get, need, th)

      if score > bestScore:
        bestScore = score
        bestModel = s.id

      if s.id == omocat.model:
        currentScore = score

    if bestModel.len == 0: continue

    var reason = ""
    if bestModel == omocat.model:
      reason = "already optimal"
    else:
      let currentMeta = cat.lookupMeta(omocat.model)
      let bestMeta = cat.lookupMeta(bestModel)
      var parts: seq[string] = @[]

      # Find the stats for both models
      var bestStats, curStats: ModelStats
      for s in stats:
        if s.id == bestModel: bestStats = s
        if s.id == omocat.model: curStats = s

      if bestStats.avg() > 0 and curStats.avg() > 0:
        let diff = ((curStats.avg() - bestStats.avg()) / curStats.avg() * 100).int
        if diff > 5:
          parts.add(&"{diff}% lower avg latency")
        elif diff < -5:
          parts.add(&"{-diff}% higher avg latency")

      if bestMeta.isSome and currentMeta.isSome:
        if bestMeta.get.tier != currentMeta.get.tier:
          parts.add(&"tier {bestMeta.get.tier} vs {currentMeta.get.tier}")
        elif bestMeta.get.tier == currentMeta.get.tier:
          parts.add(&"same {bestMeta.get.tier} tier")

      let bestStab = bestStats.stabilityScore(th)
      let curStab = curStats.stabilityScore(th)
      if bestStab >= 0 and curStab >= 0 and bestStab > curStab + 10:
        parts.add(&"stability {bestStab} vs {curStab}")

      reason = if parts.len > 0: parts.join(", ") else: "higher composite score"

    result.add(Recommendation(
      category: omocat.name,
      currentModel: omocat.model,
      recommendedModel: bestModel,
      reason: reason,
      currentScore: currentScore,
      recommendedScore: bestScore,
    ))

proc printRecommendations*(recs: seq[Recommendation], rounds: int) =
  echo ""
  echo &"\e[1m nimakai v{Version}\e[0m  \e[90mrecommendations based on {rounds} rounds\e[0m"
  echo ""

  proc pad(s: string, w: int): string =
    if s.len >= w: s[0..<w] else: s & ' '.repeat(w - s.len)

  echo "\e[1;90m  " & pad("CATEGORY", 22) & pad("CURRENT", 32) &
       pad("RECOMMENDED", 32) & pad("REASON", 40) & "\e[0m"
  echo "\e[90m  " & "-".repeat(126) & "\e[0m"

  for r in recs:
    let recDisplay = if r.recommendedModel == r.currentModel: "(no change)"
                     else: r.recommendedModel
    let recColor = if r.recommendedModel == r.currentModel: "\e[90m"
                   else: "\e[32m"
    echo "  " & pad(r.category, 22) &
         pad(r.currentModel, 32) &
         recColor & pad(recDisplay, 32) & "\e[0m" &
         "\e[90m" & r.reason & "\e[0m"

  echo ""

proc recommendationsToJson*(recs: seq[Recommendation]): JsonNode =
  var arr = newJArray()
  for r in recs:
    arr.add(%*{
      "category": r.category,
      "current_model": r.currentModel,
      "recommended_model": r.recommendedModel,
      "reason": r.reason,
      "current_score": r.currentScore,
      "recommended_score": r.recommendedScore,
    })
  %*{"recommendations": arr}
