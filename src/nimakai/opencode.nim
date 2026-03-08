## OpenCode and Oh-My-OpenCode configuration integration.

import std/[json, os, strutils]
import ./types

type
  OpenCodeModel* = object
    id*: string
    name*: string
    ctxSize*: int
    outputLimit*: int

  OmoAgent* = object
    name*: string
    model*: string  # model ID without "nvidia/" prefix

  OmoCategory* = object
    name*: string
    model*: string  # model ID without "nvidia/" prefix

  OmoConfig* = object
    agents*: seq[OmoAgent]
    categories*: seq[OmoCategory]

proc defaultOpenCodePath*(): string =
  getHomeDir() / ".config" / "opencode" / "opencode.json"

proc defaultOmoPath*(): string =
  getHomeDir() / ".config" / "opencode" / "oh-my-opencode.json"

proc stripNvidiaPrefix(model: string): string =
  ## Strip "nvidia/" prefix from model IDs used in opencode/OMO configs.
  if model.startsWith("nvidia/"):
    model[7..^1]
  else:
    model

proc parseOpenCodeConfig*(path: string = ""): seq[OpenCodeModel] =
  ## Parse opencode.json to discover configured NVIDIA NIM models.
  let p = if path.len > 0: path else: defaultOpenCodePath()
  if not fileExists(p): return @[]

  try:
    let data = parseJson(readFile(p))
    if not data.hasKey("provider"): return @[]
    let providers = data["provider"]
    if not providers.hasKey("nvidia"): return @[]
    let nvidia = providers["nvidia"]
    if not nvidia.hasKey("models"): return @[]

    for modelId, modelCfg in nvidia["models"].pairs:
      var m: OpenCodeModel
      m.id = modelId
      m.name = modelCfg{"name"}.getStr(modelId)
      if modelCfg.hasKey("limit"):
        m.ctxSize = modelCfg["limit"]{"context"}.getInt(0)
        m.outputLimit = modelCfg["limit"]{"output"}.getInt(0)
      result.add(m)
  except CatchableError:
    discard

proc parseOmoConfig*(path: string = ""): OmoConfig =
  ## Parse oh-my-opencode.json for agent and category routing.
  let p = if path.len > 0: path else: defaultOmoPath()
  if not fileExists(p): return

  try:
    let data = parseJson(readFile(p))

    if data.hasKey("agents"):
      for name, cfg in data["agents"].pairs:
        let model = cfg{"model"}.getStr("")
        if model.len > 0:
          result.agents.add(OmoAgent(
            name: name,
            model: stripNvidiaPrefix(model),
          ))

    if data.hasKey("categories"):
      for name, cfg in data["categories"].pairs:
        let model = cfg{"model"}.getStr("")
        if model.len > 0:
          result.categories.add(OmoCategory(
            name: name,
            model: stripNvidiaPrefix(model),
          ))
  except CatchableError:
    discard

proc printOpenCodeModels*(models: seq[OpenCodeModel]) =
  echo ""
  echo "\e[1m nimakai v" & Version & "\e[0m  \e[90mmodels from opencode.json\e[0m"
  echo ""

  proc pad(s: string, w: int): string =
    if s.len >= w: s[0..<w] else: s & ' '.repeat(w - s.len)
  proc padL(s: string, w: int): string =
    if s.len >= w: s[0..<w] else: ' '.repeat(w - s.len) & s

  echo "\e[1;90m  " & pad("MODEL", 40) & padL("CTX", 10) & padL("OUTPUT", 10) &
       "  " & pad("ID", 40) & "\e[0m"
  echo "\e[90m  " & "-".repeat(100) & "\e[0m"

  for m in models:
    let ctxStr = if m.ctxSize >= 1048576: $(m.ctxSize div 1048576) & "M"
                 elif m.ctxSize >= 1024: $(m.ctxSize div 1024) & "k"
                 else: $m.ctxSize
    let outStr = if m.outputLimit >= 1024: $(m.outputLimit div 1024) & "k"
                 else: $m.outputLimit
    echo "  " & pad(m.name, 40) & padL(ctxStr, 10) & padL(outStr, 10) &
         "  \e[90m" & pad(m.id, 40) & "\e[0m"
  echo ""

proc printOmoRouting*(omo: OmoConfig) =
  echo ""
  echo "\e[1m nimakai v" & Version & "\e[0m  \e[90moh-my-opencode routing\e[0m"
  echo ""

  proc pad(s: string, w: int): string =
    if s.len >= w: s[0..<w] else: s & ' '.repeat(w - s.len)

  if omo.agents.len > 0:
    echo "\e[1;90m  AGENTS\e[0m"
    for a in omo.agents:
      echo "  " & pad(a.name, 25) & "\e[90m→\e[0m " & a.model

  if omo.categories.len > 0:
    echo ""
    echo "\e[1;90m  CATEGORIES\e[0m"
    for c in omo.categories:
      echo "  " & pad(c.name, 25) & "\e[90m→\e[0m " & c.model

  echo ""
