import std/[unittest, os, json]
import nimakai/opencode

suite "parseOpenCodeConfig":
  test "returns empty for nonexistent file":
    let models = parseOpenCodeConfig("/tmp/nonexistent-opencode.json")
    check models.len == 0

  test "parses NVIDIA models":
    let path = "/tmp/test-opencode.json"
    let data = %*{
      "provider": {
        "nvidia": {
          "npm": "@ai-sdk/openai-compatible",
          "models": {
            "qwen/qwen3.5-122b-a10b": {
              "name": "Qwen 3.5 122B",
              "limit": {
                "context": 262144,
                "output": 16384
              }
            },
            "z-ai/glm4.7": {
              "name": "GLM 4.7",
              "limit": {
                "context": 131072,
                "output": 131072
              }
            }
          }
        }
      }
    }
    writeFile(path, $data)
    defer: removeFile(path)

    let models = parseOpenCodeConfig(path)
    check models.len == 2

    var found122b = false
    var foundGlm = false
    for m in models:
      if m.id == "qwen/qwen3.5-122b-a10b":
        found122b = true
        check m.name == "Qwen 3.5 122B"
        check m.ctxSize == 262144
        check m.outputLimit == 16384
      if m.id == "z-ai/glm4.7":
        foundGlm = true
    check found122b
    check foundGlm

suite "parseOmoConfig":
  test "returns empty for nonexistent file":
    let omo = parseOmoConfig("/tmp/nonexistent-omo.json")
    check omo.agents.len == 0
    check omo.categories.len == 0

  test "parses agents and categories":
    let path = "/tmp/test-omo.json"
    let data = %*{
      "agents": {
        "sisyphus": {"model": "nvidia/qwen/qwen3.5-122b-a10b"},
        "oracle": {"model": "nvidia/qwen/qwen3.5-397b-a17b"}
      },
      "categories": {
        "quick": {"model": "nvidia/minimaxai/minimax-m2.1"},
        "deep": {"model": "nvidia/qwen/qwen3.5-397b-a17b"}
      }
    }
    writeFile(path, $data)
    defer: removeFile(path)

    let omo = parseOmoConfig(path)
    check omo.agents.len == 2
    check omo.categories.len == 2

    # Verify nvidia/ prefix is stripped
    var foundSisyphus = false
    for a in omo.agents:
      if a.name == "sisyphus":
        foundSisyphus = true
        check a.model == "qwen/qwen3.5-122b-a10b"
    check foundSisyphus

    var foundQuick = false
    for c in omo.categories:
      if c.name == "quick":
        foundQuick = true
        check c.model == "minimaxai/minimax-m2.1"
    check foundQuick

  test "handles models without nvidia prefix":
    let path = "/tmp/test-omo-noprefix.json"
    let data = %*{
      "agents": {
        "test": {"model": "some/model"}
      },
      "categories": {}
    }
    writeFile(path, $data)
    defer: removeFile(path)

    let omo = parseOmoConfig(path)
    check omo.agents[0].model == "some/model"
