import std/[unittest, os, json]
import nimakai/[types, config]

suite "loadConfigFile":
  test "returns defaults when file doesn't exist":
    let cfg = loadConfigFile("/tmp/nonexistent-nimakai-config.json")
    check cfg.interval == DefaultInterval
    check cfg.timeout == DefaultTimeout
    check cfg.models.len == 0
    check cfg.tierFilter == ""
    check cfg.thresholds == DefaultThresholds
    check cfg.favorites.len == 0

  test "loads config from file":
    let path = "/tmp/test-nimakai-config.json"
    let data = %*{
      "interval": 3,
      "timeout": 10,
      "models": ["model/a", "model/b"],
      "favorites": ["model/a"],
      "thresholds": {
        "perfect_avg": 300,
        "spike_ms": 2000,
      }
    }
    writeFile(path, $data)
    defer: removeFile(path)

    let cfg = loadConfigFile(path)
    check cfg.interval == 3
    check cfg.timeout == 10
    check cfg.models.len == 2
    check cfg.models[0] == "model/a"
    check cfg.favorites.len == 1
    check cfg.favorites[0] == "model/a"
    check cfg.thresholds.perfectAvg == 300.0
    check cfg.thresholds.spikeMs == 2000.0
    # Unset thresholds keep defaults
    check cfg.thresholds.perfectP95 == 800.0

suite "saveConfigFile":
  test "creates config file":
    let path = "/tmp/test-nimakai-save.json"
    defer:
      if fileExists(path): removeFile(path)
      let dir = parentDir(path)
      # Don't try to remove /tmp

    saveConfigFile(path, favorites = @["model/x"],
                   interval = 7, timeout = 20)
    check fileExists(path)

    let data = parseJson(readFile(path))
    check data["interval"].getInt() == 7
    check data["timeout"].getInt() == 20
    check data["favorites"][0].getStr() == "model/x"

suite "saveFavorites":
  test "updates favorites in existing config":
    let path = "/tmp/test-nimakai-favs.json"
    writeFile(path, $(%*{"interval": 5}))
    defer: removeFile(path)

    saveFavorites(path, @["model/a", "model/b"])

    let data = parseJson(readFile(path))
    check data["interval"].getInt() == 5 # preserved
    check data["favorites"].len == 2
    check data["favorites"][0].getStr() == "model/a"

  test "creates file if not exists":
    let path = "/tmp/test-nimakai-favs-new.json"
    defer:
      if fileExists(path): removeFile(path)

    saveFavorites(path, @["model/x"])

    check fileExists(path)
    let data = parseJson(readFile(path))
    check data["favorites"][0].getStr() == "model/x"
