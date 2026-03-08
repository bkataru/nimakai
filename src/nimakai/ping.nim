## HTTP ping and error classification for nimakai.

import std/[httpclient, json, times, strutils, net]
import ./types

proc classifyHealth*(statusCode: int, msg: string): Health =
  ## Classify a ping result into a Health state based on HTTP status code
  ## or exception message.
  if statusCode == 200: return hUp
  if statusCode in [401, 403]: return hNoKey
  if statusCode in [404, 410]: return hNotFound
  if statusCode == 429: return hOverloaded
  if statusCode in [502, 503]: return hOverloaded
  if statusCode >= 400 and statusCode < 600: return hError
  # Connection-level errors (statusCode == 0)
  let lower = msg.toLowerAscii()
  if "timeout" in lower or "timed out" in lower:
    return hTimeout
  return hError

proc doPing*(apiKey, modelId: string, timeout: int): PingResult {.gcsafe.} =
  ## Send a minimal chat completion request to measure latency.
  let payload = $(%*{
    "model": modelId,
    "messages": [{"role": "user", "content": "hi"}],
    "max_tokens": 1,
    "stream": false
  })

  let sslCtx = newContext(verifyMode = CVerifyPeer)
  let client = newHttpClient(timeout = timeout * 1000, sslContext = sslCtx)
  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Authorization": "Bearer " & apiKey
  })

  let t0 = epochTime()
  try:
    let resp = client.post(BaseURL, payload)
    let ms = (epochTime() - t0) * 1000.0
    let code = parseInt($resp.code)
    client.close()
    result = PingResult(
      health: classifyHealth(code, ""),
      ms: ms,
      statusCode: code,
      timestamp: t0,
    )
  except CatchableError as e:
    let ms = (epochTime() - t0) * 1000.0
    try: client.close()
    except CatchableError: discard
    result = PingResult(
      health: classifyHealth(0, e.msg),
      ms: ms,
      statusCode: 0,
      errorMsg: e.msg,
      timestamp: t0,
    )
