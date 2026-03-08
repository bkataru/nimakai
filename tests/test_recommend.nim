import std/[unittest, options]
import nimakai/[types, metrics, catalog, opencode, recommend]

proc makeStats(id: string, pings: openArray[float],
               total: int = -1, success: int = -1): ModelStats =
  result.id = id
  result.lastHealth = if pings.len > 0: hUp else: hTimeout
  for p in pings:
    result.addSample(p)
  result.totalPings = if total >= 0: total else: pings.len
  result.successPings = if success >= 0: success else: pings.len
  if pings.len > 0:
    result.lastMs = pings[^1]

suite "categorizeNeed":
  test "quick maps to Speed":
    check categorizeNeed("quick") == cnSpeed

  test "deep maps to Quality":
    check categorizeNeed("deep") == cnQuality

  test "ultrabrain maps to Reliability":
    check categorizeNeed("ultrabrain") == cnReliability

  test "visual-engineering maps to Vision":
    check categorizeNeed("visual-engineering") == cnVision

  test "writing maps to Balance":
    check categorizeNeed("writing") == cnBalance

  test "unknown maps to Balance":
    check categorizeNeed("something-else") == cnBalance

suite "scoreModel":
  test "fast model scores high for speed need":
    let stats = makeStats("fast/model", [100.0, 110.0, 105.0])
    let meta = ModelMeta(id: "fast/model", name: "Fast", tier: tS,
                         sweScore: 65.0, ctxSize: 131072)
    let score = scoreModel(stats, meta, cnSpeed)
    check score > 50

  test "high SWE model scores high for quality need":
    let stats = makeStats("quality/model", [500.0, 600.0, 550.0])
    let meta = ModelMeta(id: "quality/model", name: "Quality", tier: tSPlus,
                         sweScore: 78.0, ctxSize: 262144)
    let score = scoreModel(stats, meta, cnQuality)
    check score > 50

  test "non-multimodal model penalized for vision need":
    let stats = makeStats("text/model", [200.0, 210.0, 205.0])
    let textMeta = ModelMeta(id: "text/model", name: "Text", tier: tSPlus,
                             sweScore: 75.0, ctxSize: 131072, multimodal: false)
    let visionMeta = ModelMeta(id: "vision/model", name: "Vision", tier: tSPlus,
                               sweScore: 75.0, ctxSize: 131072, multimodal: true)

    let textScore = scoreModel(stats, textMeta, cnVision)
    let visionScore = scoreModel(stats, visionMeta, cnVision)
    check visionScore > textScore * 3 # 80% penalty = 5x difference

suite "recommend":
  test "recommends faster model for quick category":
    let cat = @[
      ModelMeta(id: "fast/model", name: "Fast", tier: tSPlus,
                sweScore: 72.0, ctxSize: 131072),
      ModelMeta(id: "slow/model", name: "Slow", tier: tSPlus,
                sweScore: 74.0, ctxSize: 131072),
    ]
    let stats = @[
      makeStats("fast/model", [100.0, 110.0, 105.0]),
      makeStats("slow/model", [2000.0, 2100.0, 2200.0]),
    ]
    let omo = OmoConfig(
      agents: @[],
      categories: @[OmoCategory(name: "quick", model: "slow/model")],
    )

    let recs = recommend(stats, cat, omo)
    check recs.len == 1
    check recs[0].recommendedModel == "fast/model"

  test "keeps optimal model":
    let cat = @[
      ModelMeta(id: "best/model", name: "Best", tier: tSPlus,
                sweScore: 78.0, ctxSize: 262144),
    ]
    let stats = @[
      makeStats("best/model", [200.0, 210.0, 205.0]),
    ]
    let omo = OmoConfig(
      agents: @[],
      categories: @[OmoCategory(name: "deep", model: "best/model")],
    )

    let recs = recommend(stats, cat, omo)
    check recs.len == 1
    check recs[0].recommendedModel == "best/model"
    check recs[0].reason == "already optimal"

  test "prefers multimodal for vision category":
    let cat = @[
      ModelMeta(id: "text/model", name: "Text", tier: tSPlus,
                sweScore: 78.0, ctxSize: 131072, multimodal: false),
      ModelMeta(id: "vision/model", name: "Vision", tier: tS,
                sweScore: 65.0, ctxSize: 131072, multimodal: true),
    ]
    let stats = @[
      makeStats("text/model", [100.0, 110.0]),
      makeStats("vision/model", [300.0, 310.0]),
    ]
    let omo = OmoConfig(
      agents: @[],
      categories: @[OmoCategory(name: "visual-engineering", model: "text/model")],
    )

    let recs = recommend(stats, cat, omo)
    check recs.len == 1
    check recs[0].recommendedModel == "vision/model"
