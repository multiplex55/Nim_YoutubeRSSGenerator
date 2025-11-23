import std/[strutils, httpclient, osproc]

# --------------------------------------------------------------------
# PowerShell helper
# --------------------------------------------------------------------

proc runPowerShell(psCommand: string): string =
  ## Try to run a PowerShell / pwsh command and return its stdout.
  ## Throws OSError if both fail.
  let args = @["-NoProfile", "-Command", psCommand]

  for exe in ["powershell", "pwsh"]:
    echo "[DEBUG] Trying executable: ", exe
    try:
      let output = execProcess(exe, args = args, options = {poUsePath})
      echo "[DEBUG] ", exe, " succeeded."
      return output
    except OSError as e:
      echo "[DEBUG] ", exe, " failed: ", e.msg

  raise newException(OSError,
    "Neither 'powershell' nor 'pwsh' was found in PATH.")

# --------------------------------------------------------------------
# Clipboard helpers via PowerShell (with debug logging)
# --------------------------------------------------------------------

proc getClipboardText(): string =
  echo "[DEBUG] Attempting to read clipboard via PowerShell..."
  try:
    let clipText = runPowerShell("Get-Clipboard -Raw")
    echo "[DEBUG] Raw clipboard contents:"
    echo "-------- CLIPBOARD START --------"
    echo clipText
    echo "--------- CLIPBOARD END ---------"
    result = clipText
  except OSError as e:
    echo "[ERROR] Failed to read clipboard: ", e.msg
    result = ""

proc setClipboardText(text: string): bool =
  ## Write text to the Windows clipboard using PowerShell.
  var escaped = text.replace("'", "''")
  let psCommand = "Set-Clipboard -Value '" & escaped & "'"
  echo "[DEBUG] Running PowerShell to set clipboard:"
  echo psCommand
  try:
    discard runPowerShell(psCommand)
    echo "[DEBUG] Clipboard updated successfully."
    result = true
  except OSError as e:
    echo "[ERROR] Failed to write to clipboard: ", e.msg
    result = false

# --------------------------------------------------------------------
# YouTube helpers
# --------------------------------------------------------------------

proc isValidChannelId(id: string): bool =
  if id.len != 24 or not id.startsWith("UC"):
    return false
  for c in id:
    if not ((c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_'):
      return false
  result = true

proc normalizeUrl(url: string): string =
  var res = url.strip()
  if res.len == 0:
    return res
  if not (res.startsWith("http://") or res.startsWith("https://")):
    res = "https://" & res
  result = res

proc extractFromUrlDirect(url: string): string =
  echo "[DEBUG] Trying to extract channel ID directly from URL..."
  echo "[DEBUG] URL: ", url

  # 1) channel_id=UC....
  var p = url.find("channel_id=")
  if p != -1:
    let start = p + "channel_id=".len
    var endPos = start
    while endPos < url.len and url[endPos] notin {'?', '&', '#', '/', '"', '\''}:
      inc endPos
    if endPos > start:
      let candidate = url.substr(start, endPos - 1)
      echo "[DEBUG] Found channel_id= candidate: ", candidate
      if isValidChannelId(candidate):
        echo "[DEBUG] Candidate is a valid channel ID."
        return candidate
      else:
        echo "[DEBUG] Candidate is NOT a valid channel ID."

  # 2) /channel/UC....
  const channelPrefix = "/channel/"
  p = url.find(channelPrefix)
  if p != -1:
    let start = p + channelPrefix.len
    var endPos = start
    while endPos < url.len and url[endPos] notin {'?', '&', '#', '/', '"', '\''}:
      inc endPos
    if endPos > start:
      let candidate = url.substr(start, endPos - 1)
      echo "[DEBUG] Found /channel/ candidate: ", candidate
      if isValidChannelId(candidate):
        echo "[DEBUG] Candidate is a valid channel ID."
        return candidate
      else:
        echo "[DEBUG] Candidate is NOT a valid channel ID."

  echo "[DEBUG] No channel ID found directly in URL."
  result = ""

proc extractFromHtml(html: string): string =
  echo "[DEBUG] Trying to extract channel ID from HTML..."

  let marker = "channelId\":\"UC"
  var idx = html.find(marker)
  if idx != -1:
    let start = idx + "channelId\":\"".len
    if start + 24 <= html.len:
      let candidate = html.substr(start, start + 23)
      echo "[DEBUG] Found marker-based candidate: ", candidate
      if isValidChannelId(candidate):
        echo "[DEBUG] Marker-based candidate valid."
        return candidate
      else:
        echo "[DEBUG] Marker-based candidate NOT valid."

  # Fallback scan
  if html.len >= 24:
    for i in 0 ..< (html.len - 23):
      if html[i] == 'U' and html[i + 1] == 'C':
        let candidate = html.substr(i, i + 23)
        if isValidChannelId(candidate):
          echo "[DEBUG] Fallback scan found candidate: ", candidate
          return candidate

  echo "[DEBUG] No channel ID found in HTML."
  result = ""

proc extractChannelId(url: string): string =
  echo "[DEBUG] === extractChannelId ==="
  echo "[DEBUG] Input URL: ", url

  result = extractFromUrlDirect(url)
  if result.len > 0:
    echo "[DEBUG] Got channel ID from URL directly: ", result
    return

  echo "[DEBUG] No direct channel ID, downloading page..."
  try:
    var client = newHttpClient()
    client.headers = newHttpHeaders({
      "User-Agent": "Mozilla/5.0 (Nim YouTube RSS helper)"
    })
    let html = client.getContent(url)
    echo "[DEBUG] Downloaded HTML, length = ", html.len
    result = extractFromHtml(html)
    if result.len > 0:
      echo "[DEBUG] Got channel ID from HTML: ", result
    else:
      echo "[DEBUG] Still no channel ID after parsing HTML."
  except CatchableError as e:
    echo "[ERROR] Failed to download YouTube page: ", e.msg
    result = ""

proc channelIdToPlaylistId(channelId: string): string =
  echo "[DEBUG] Converting channel ID to playlist ID: ", channelId
  if not isValidChannelId(channelId):
    echo "[ERROR] Invalid channel ID format."
    return ""
  result = "UULF" & channelId.substr(2)
  echo "[DEBUG] Playlist ID: ", result

# --------------------------------------------------------------------
# Main
# --------------------------------------------------------------------

when isMainModule:
  echo "[DEBUG] Program start."

  let originalClip = getClipboardText()
  echo "[DEBUG] Clipboard (original): '", originalClip, "'"

  let clip = originalClip.strip()
  echo "[DEBUG] Clipboard (trimmed):  '", clip, "'"

  let lower = clip.toLowerAscii()
  if clip.len == 0:
    echo "[INFO] Clipboard is empty or whitespace. Exiting without changes."
    quit(0)

  if (not lower.contains("youtube.com") and
      not lower.contains("youtu.be")):
    echo "[INFO] Clipboard does not contain a YouTube URL. Exiting without changes."
    quit(0)

  echo "[DEBUG] Clipboard looks like a YouTube URL."

  let url = normalizeUrl(clip)
  echo "[DEBUG] Normalized URL: ", url

  let channelId = extractChannelId(url)

  if channelId.len == 0:
    echo "[ERROR] Could not determine YouTube channel ID from clipboard URL."
    quit(1)

  let playlistId = channelIdToPlaylistId(channelId)
  if playlistId.len == 0:
    echo "[ERROR] Failed to build playlist ID from channel ID."
    quit(1)

  let rssUrl =
    "https://www.youtube.com/feeds/videos.xml?playlist_id=" & playlistId

  echo "[DEBUG] Final RSS URL: ", rssUrl

  if not setClipboardText(rssUrl):
    echo "[ERROR] Failed to write result to clipboard."
    quit(1)

  echo "[INFO] Copied playlist RSS URL to clipboard:"
  echo rssUrl
