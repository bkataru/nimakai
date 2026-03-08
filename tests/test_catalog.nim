import std/[unittest, options, sets]
import nimakai/[types, catalog]

suite "BuiltinCatalog integrity":
  test "catalog has models":
    check BuiltinCatalog.len >= 40

  test "no duplicate model IDs":
    var ids: HashSet[string]
    for m in BuiltinCatalog:
      check m.id notin ids
      ids.incl(m.id)

  test "all models have non-empty ID and name":
    for m in BuiltinCatalog:
      check m.id.len > 0
      check m.name.len > 0

  test "SWE scores are in valid range":
    for m in BuiltinCatalog:
      check m.sweScore >= 0.0
      check m.sweScore <= 100.0

  test "context sizes are positive":
    for m in BuiltinCatalog:
      check m.ctxSize > 0

  test "tiers are ordered by SWE score ranges":
    for m in BuiltinCatalog:
      case m.tier
      of tSPlus: check m.sweScore >= 70.0
      of tS: check m.sweScore >= 60.0 and m.sweScore < 80.0
      of tAPlus: check m.sweScore >= 50.0 and m.sweScore < 70.0
      of tA: check m.sweScore >= 40.0 and m.sweScore < 60.0
      of tAMinus: check m.sweScore >= 35.0 and m.sweScore < 45.0
      of tBPlus: check m.sweScore >= 30.0 and m.sweScore < 40.0
      of tB: check m.sweScore >= 20.0 and m.sweScore < 35.0
      of tC: check m.sweScore < 20.0

suite "lookupMeta":
  test "finds existing model":
    let result = BuiltinCatalog.lookupMeta("z-ai/glm4.7")
    check result.isSome
    check result.get.name == "GLM 4.7"
    check result.get.tier == tSPlus

  test "returns none for unknown model":
    let result = BuiltinCatalog.lookupMeta("nonexistent/model")
    check result.isNone

suite "filterByTier":
  test "filter by S returns S+ and S models":
    let filtered = BuiltinCatalog.filterByTier("S")
    check filtered.len > 0
    for m in filtered:
      check m.tier in [tSPlus, tS]

  test "filter by A returns A+, A, A- models":
    let filtered = BuiltinCatalog.filterByTier("A")
    check filtered.len > 0
    for m in filtered:
      check m.tier in [tAPlus, tA, tAMinus]

  test "empty filter returns all":
    let filtered = BuiltinCatalog.filterByTier("")
    check filtered.len == BuiltinCatalog.len

suite "loadCatalog":
  test "returns at least builtin models":
    let cat = loadCatalog()
    check cat.len >= BuiltinCatalog.len

suite "catalogModelIds":
  test "returns all IDs":
    let ids = catalogModelIds(BuiltinCatalog)
    check ids.len == BuiltinCatalog.len
    check "z-ai/glm4.7" in ids
