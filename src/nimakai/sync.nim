## Sync module: backup, apply, and rollback oh-my-opencode.json changes.

import std/[json, os, times, strutils, algorithm]
import ./[recommend, opencode]

proc backupOmo*(path: string = ""): string =
  ## Create a timestamped backup of oh-my-opencode.json.
  ## Returns the backup file path.
  let p = if path.len > 0: path else: defaultOmoPath()
  if not fileExists(p):
    raise newException(IOError, "oh-my-opencode.json not found at: " & p)

  let n = now()
  let ts = n.format("yyyyMMdd-HHmmss") & "-" & $(n.nanosecond div 1_000_000)
  let backupPath = p & ".bak." & ts
  copyFile(p, backupPath)
  backupPath

proc applyRecommendations*(recs: seq[Recommendation], path: string = "") =
  ## Apply routing recommendations to oh-my-opencode.json.
  ## Only modifies category model assignments.
  let p = if path.len > 0: path else: defaultOmoPath()
  if not fileExists(p):
    raise newException(IOError, "oh-my-opencode.json not found at: " & p)

  var data = parseJson(readFile(p))

  if not data.hasKey("categories"):
    data["categories"] = newJObject()

  var changes = 0
  for r in recs:
    if r.recommendedModel == r.currentModel: continue

    let fullModel = "nvidia/" & r.recommendedModel
    if data["categories"].hasKey(r.category):
      data["categories"][r.category]["model"] = newJString(fullModel)
    else:
      data["categories"][r.category] = %*{"model": fullModel}
    changes += 1

  if changes > 0:
    writeFile(p, pretty(data))

proc findLatestBackup*(path: string = ""): string =
  ## Find the most recent .bak.* file for oh-my-opencode.json.
  let p = if path.len > 0: path else: defaultOmoPath()
  let dir = parentDir(p)
  let base = extractFilename(p)

  var backups: seq[string] = @[]
  for kind, filepath in walkDir(dir):
    if kind == pcFile:
      let name = extractFilename(filepath)
      if name.startsWith(base & ".bak."):
        backups.add(filepath)

  if backups.len == 0: return ""
  backups.sort()
  backups[^1] # latest by timestamp sort

proc rollbackOmo*(path: string = ""): bool =
  ## Restore oh-my-opencode.json from the most recent backup.
  ## Returns true if rollback succeeded.
  let p = if path.len > 0: path else: defaultOmoPath()
  let backup = findLatestBackup(p)
  if backup.len == 0:
    stderr.writeLine "\e[31mNo backup found to rollback to.\e[0m"
    return false

  copyFile(backup, p)
  stderr.writeLine "\e[32mRolled back to: " & extractFilename(backup) & "\e[0m"
  return true

proc showDiff*(recs: seq[Recommendation]) =
  ## Show a colored diff of proposed changes.
  echo ""
  echo "\e[1mProposed changes to oh-my-opencode.json:\e[0m"
  echo ""

  var hasChanges = false
  for r in recs:
    if r.recommendedModel == r.currentModel: continue
    hasChanges = true
    echo "  \e[90m" & r.category & ":\e[0m"
    echo "    \e[31m- nvidia/" & r.currentModel & "\e[0m"
    echo "    \e[32m+ nvidia/" & r.recommendedModel & "\e[0m"

  if not hasChanges:
    echo "  \e[90m(no changes recommended)\e[0m"

  echo ""

proc syncRecommendations*(recs: seq[Recommendation], path: string = ""): bool =
  ## Full sync: backup → show diff → apply.
  ## Returns true if changes were applied.
  let p = if path.len > 0: path else: defaultOmoPath()

  # Check if there are any changes
  var hasChanges = false
  for r in recs:
    if r.recommendedModel != r.currentModel:
      hasChanges = true
      break

  if not hasChanges:
    echo "\e[90mNo routing changes recommended. Config is already optimal.\e[0m"
    return false

  # Show diff
  showDiff(recs)

  # Backup
  try:
    let backupPath = backupOmo(p)
    stderr.writeLine "\e[90mBackup created: " & extractFilename(backupPath) & "\e[0m"
  except CatchableError as e:
    stderr.writeLine "\e[31mFailed to create backup: " & e.msg & "\e[0m"
    return false

  # Apply
  try:
    applyRecommendations(recs, p)
    var changeCount = 0
    for r in recs:
      if r.recommendedModel != r.currentModel: inc changeCount
    echo "\e[32mApplied " & $changeCount & " routing change(s) to oh-my-opencode.json\e[0m"
    return true
  except CatchableError as e:
    stderr.writeLine "\e[31mFailed to apply changes: " & e.msg & "\e[0m"
    return false
