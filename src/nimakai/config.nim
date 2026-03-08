## Configuration file handling for nimakai.
## Location: ~/.config/nimakai/config.json

import std/[json, os]
import ./types

proc defaultConfigPath*(): string =
  getHomeDir() / ".config" / "nimakai" / "config.json"

proc loadConfigFile*(path: string = ""): tuple[
    interval: int, timeout: int, models: seq[string],
    tierFilter: string, thresholds: Thresholds,
    favorites: seq[string]] =
  ## Load config from file. Returns defaults if file doesn't exist.
  result.interval = DefaultInterval
  result.timeout = DefaultTimeout
  result.models = @[]
  result.tierFilter = ""
  result.thresholds = DefaultThresholds
  result.favorites = @[]

  let p = if path.len > 0: path else: defaultConfigPath()
  if not fileExists(p): return

  try:
    let data = parseJson(readFile(p))
    if data.hasKey("interval"):
      result.interval = data["interval"].getInt(DefaultInterval)
    if data.hasKey("timeout"):
      result.timeout = data["timeout"].getInt(DefaultTimeout)
    if data.hasKey("models"):
      for m in data["models"]:
        result.models.add(m.getStr())
    if data.hasKey("tier_filter"):
      result.tierFilter = data["tier_filter"].getStr("")
    if data.hasKey("thresholds"):
      let th = data["thresholds"]
      result.thresholds.perfectAvg = th{"perfect_avg"}.getFloat(400.0)
      result.thresholds.perfectP95 = th{"perfect_p95"}.getFloat(800.0)
      result.thresholds.normalAvg = th{"normal_avg"}.getFloat(1000.0)
      result.thresholds.normalP95 = th{"normal_p95"}.getFloat(2000.0)
      result.thresholds.spikeMs = th{"spike_ms"}.getFloat(3000.0)
    if data.hasKey("favorites"):
      for f in data["favorites"]:
        result.favorites.add(f.getStr())
  except CatchableError:
    discard

proc saveConfigFile*(path: string = "", favorites: seq[string] = @[],
                     interval: int = DefaultInterval,
                     timeout: int = DefaultTimeout,
                     thresholds: Thresholds = DefaultThresholds) =
  ## Save config to file.
  let p = if path.len > 0: path else: defaultConfigPath()
  let dir = parentDir(p)
  if not dirExists(dir):
    createDir(dir)

  var favArr = newJArray()
  for f in favorites:
    favArr.add(newJString(f))

  let data = %*{
    "interval": interval,
    "timeout": timeout,
    "models": newJArray(),
    "tier_filter": newJNull(),
    "thresholds": {
      "perfect_avg": thresholds.perfectAvg,
      "perfect_p95": thresholds.perfectP95,
      "normal_avg": thresholds.normalAvg,
      "normal_p95": thresholds.normalP95,
      "spike_ms": thresholds.spikeMs,
    },
    "favorites": favArr,
  }
  writeFile(p, pretty(data))

proc saveFavorites*(path: string, favorites: seq[string]) =
  ## Update only the favorites field in the config file.
  let p = if path.len > 0: path else: defaultConfigPath()
  var data: JsonNode
  if fileExists(p):
    try:
      data = parseJson(readFile(p))
    except CatchableError:
      data = newJObject()
  else:
    data = newJObject()
    let dir = parentDir(p)
    if not dirExists(dir):
      createDir(dir)

  var favArr = newJArray()
  for f in favorites:
    favArr.add(newJString(f))
  data["favorites"] = favArr
  writeFile(p, pretty(data))
