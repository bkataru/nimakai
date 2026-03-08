import std/[strutils, unittest]
import nimakai/[types, display]

suite "padding":
  test "padRight pads correctly":
    check padRight("hi", 5) == "hi   "

  test "padRight truncates when too long":
    check padRight("hello world", 5) == "hello"

  test "padRight exact width":
    check padRight("hello", 5) == "hello"

  test "padLeft pads correctly":
    check padLeft("hi", 5) == "   hi"

  test "padLeft truncates when too long":
    check padLeft("hello world", 5) == "hello"

suite "stripAnsi":
  test "plain string returns length":
    check stripAnsi("hello") == 5

  test "string with ANSI codes returns visible length":
    check stripAnsi("\e[32mUP\e[0m") == 2

  test "empty string returns 0":
    check stripAnsi("") == 0

  test "multiple ANSI sequences":
    check stripAnsi("\e[1m\e[32mhi\e[0m") == 2

suite "padRightAnsi":
  test "pads based on visible width":
    let s = "\e[32mUP\e[0m"
    let padded = padRightAnsi(s, 10)
    check stripAnsi(padded) == 10

suite "padLeftAnsi":
  test "pads based on visible width":
    let s = "\e[32mUP\e[0m"
    let padded = padLeftAnsi(s, 10)
    check stripAnsi(padded) == 10

suite "colorLatency":
  test "green for < 500ms":
    let c = colorLatency(300.0)
    check "\e[32m" in c

  test "yellow for 500-1500ms":
    let c = colorLatency(800.0)
    check "\e[33m" in c

  test "red for >= 1500ms":
    let c = colorLatency(2000.0)
    check "\e[31m" in c

suite "healthIcon":
  test "UP is green":
    check "\e[32m" in healthIcon(hUp)

  test "TIMEOUT is yellow":
    check "\e[33m" in healthIcon(hTimeout)

  test "ERROR is red":
    check "\e[31m" in healthIcon(hError)

  test "PENDING is dim":
    check "\e[90m" in healthIcon(hPending)

suite "verdictColor":
  test "Perfect is green":
    check "\e[32m" in verdictColor(vPerfect)

  test "Normal is cyan":
    check "\e[36m" in verdictColor(vNormal)

  test "Unstable is bold red":
    check "\e[31;1m" in verdictColor(vUnstable)

  test "Pending is dim":
    check "\e[90m" in verdictColor(vPending)
