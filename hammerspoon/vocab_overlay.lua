local M = {}

-- Allow a basic syntax check with plain Lua (outside Hammerspoon).
if not hs then
  return M
end

local json = require("hs.json")
local http = require("hs.http")

local config = {
  intervalSeconds = 20 * 60, -- every 20 minutes
  displaySeconds = 8,        -- stay on screen for 8 seconds
  showBackByDefault = false,
  autoStart = true,
  hideDockIcon = true, -- required to appear above full-screen windows on macOS Sierra+

  sources = {
    itemsJsonFile = hs.configdir .. "/data/items.json",
    itemsWeight = 1,

    sentencesFile = hs.configdir .. "/data/sentences.txt",
    sentencesWeight = 1,

    wordsWeight = 3,
    wordlists = {
      enabled = true,
      categories = {
        { id = "cs", weight = 4, file = hs.configdir .. "/data/wordlists/cs.txt" },
        { id = "gaokao3500", weight = 3, file = hs.configdir .. "/data/wordlists/gaokao3500.txt" },
        { id = "cet4", weight = 2, file = hs.configdir .. "/data/wordlists/cet4.txt" },
        { id = "cet6", weight = 2, file = hs.configdir .. "/data/wordlists/cet6.txt" },
      },
    },
  },

  -- Optional: plug in your own LLM endpoint to generate/enrich items.
  -- Enable by setting `enabled = true` and `endpoint = "http(s)://..."`.
  -- Expected response (recommended): { "item": { "type": "word|sentence", "front": "...", "back": "..." } }
  llm = {
    enabled = false,
    mode = "enrich", -- "enrich" (fill back for a picked item) | "generate" (ask LLM for a new item)
    endpoint = "",
    apiKey = "", -- optional (sent as `Authorization: Bearer ...`)
    timeoutSeconds = 8,
    extraHeaders = {},
    preferences = {
      language = "zh",
      style = "concise",
      includeExample = true,
    },
  },

  hotkeys = {
    showNow = { { "ctrl", "alt", "cmd" }, "V" },
    toggleTimer = { { "ctrl", "alt", "cmd" }, "T" },
    reloadData = { { "ctrl", "alt", "cmd" }, "I" },
  },

  ui = {
    overlayColor = { white = 0, alpha = 0.38 },
    cardColor = { white = 1, alpha = 0.96 },
    cardStrokeColor = { white = 0, alpha = 0.08 },

    frontTextColor = { white = 0, alpha = 0.92 },
    backTextColor = { white = 0, alpha = 0.70 },
    hintTextColor = { white = 0, alpha = 0.42 },

    fontFront = nil, -- nil = system default
    fontBack = nil,
    fontHint = nil,

    fontSizeWord = 60,
    fontSizeSentence = 34,
    fontSizeBack = 24,
    fontSizeHint = 13,

    cardMaxWidth = 980,
    cardMaxHeight = 460,
    cardPadding = 46,
    cornerRadius = 18,

    fadeInSeconds = 0.10,
    fadeOutSeconds = 0.12,
  },
}

local state = {
  items = nil,
  sentences = nil,
  wordlists = nil,
  canvases = {},
  visible = false,
  backRevealed = false,
  currentItem = nil,
  loading = false,
  pending = nil,

  hideTimer = nil,
  intervalTimer = nil,
  screenWatcher = nil,

  lastKey = hs.settings.get("vocabOverlay.lastKey") or nil,
  needsRebuild = true,

  modal = nil,
  initialized = false,
}

local function log(msg)
  print("[vocab_overlay] " .. msg)
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

local function trim(s)
  if type(s) ~= "string" then
    return ""
  end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function splitNonEmptyLines(text)
  local lines = {}
  if type(text) ~= "string" then
    return lines
  end
  for line in text:gmatch("[^\r\n]+") do
    line = trim(line)
    if line ~= "" and not line:match("^#") then
      table.insert(lines, line)
    end
  end
  return lines
end

local function splitFrontBack(line)
  if type(line) ~= "string" then
    return "", ""
  end
  local a, b = line:match("^(.-)\t(.-)$")
  if a then
    return trim(a), trim(b)
  end
  local c, d = line:match("^(.-)%s*%|%|%s*(.-)$")
  if c then
    return trim(c), trim(d)
  end
  return trim(line), ""
end

local function loadTextItems(path, defaultType, meta)
  local content = readFile(path)
  if not content or content == "" then
    return {}
  end
  local out = {}
  for _, line in ipairs(splitNonEmptyLines(content)) do
    local front, back = splitFrontBack(line)
    if front ~= "" then
      local item = { type = defaultType, front = front, back = back or "" }
      if meta then
        item.meta = meta
      end
      table.insert(out, item)
    end
  end
  return out
end

local function defaultItems()
  return {
    { type = "word", front = "serendipity", back = "机缘巧合；意外发现美好事物" },
    { type = "word", front = "resilient", back = "有韧性的；能迅速恢复的" },
    { type = "word", front = "consolidate", back = "巩固；合并" },
    { type = "sentence", front = "Consistency beats intensity.", back = "持续胜过爆发。" },
    { type = "sentence", front = "Take it one step at a time.", back = "一步一步来。" },
    { type = "sentence", front = "Make it easy to start, hard to stop.", back = "让开始更容易，让停下更困难。" },
  }
end

local function normalizeItems(raw)
  if type(raw) ~= "table" then
    return {}
  end
  local out = {}
  for _, it in ipairs(raw) do
    if type(it) == "string" then
      table.insert(out, { type = "text", front = it, back = "" })
    elseif type(it) == "table" then
      local front = it.front or it.q or it.word or it.sentence or it[1]
      local back = it.back or it.a or it.meaning or it.translation or it[2]
      if type(front) == "string" and front ~= "" then
        table.insert(out, {
          type = it.type or "text",
          front = front,
          back = (type(back) == "string") and back or "",
          meta = (type(it.meta) == "table") and it.meta or nil,
        })
      end
    end
  end
  return out
end

local function loadItems()
  local path = config.sources.itemsJsonFile
  local content = readFile(path)
  if not content or content == "" then
    state.items = defaultItems()
    log("items.json missing/empty, using built-in sample list: " .. path)
    return
  end

  local ok, decoded = pcall(json.decode, content)
  if not ok then
    state.items = defaultItems()
    log("failed to parse items.json, using built-in sample list: " .. path)
    return
  end

  local items = normalizeItems(decoded)
  if #items == 0 then
    state.items = defaultItems()
    log("items.json parsed but yielded 0 items, using built-in sample list: " .. path)
    return
  end

  state.items = items
  log(("loaded %d items from %s"):format(#items, path))
end

local function loadSentences()
  local path = config.sources.sentencesFile
  local items = loadTextItems(path, "sentence")
  state.sentences = items
  if #items > 0 then
    log(("loaded %d sentences from %s"):format(#items, path))
  end
end

local function loadWordlists()
  if not (config.sources.wordlists and config.sources.wordlists.enabled) then
    state.wordlists = {}
    return
  end

  local categories = {}
  for _, cat in ipairs(config.sources.wordlists.categories or {}) do
    local items = loadTextItems(cat.file, "word", { category = cat.id })
    if #items > 0 then
      table.insert(categories, {
        id = cat.id,
        weight = tonumber(cat.weight) or 1,
        items = items,
      })
      log(("loaded %d words from %s (%s)"):format(#items, cat.file, cat.id))
    end
  end
  state.wordlists = categories
end

local function loadAllSources()
  loadItems()
  loadSentences()
  loadWordlists()
end

local function ensureSourcesLoaded()
  if state.items == nil then
    loadItems()
  end
  if state.sentences == nil then
    loadSentences()
  end
  if state.wordlists == nil then
    loadWordlists()
  end
end

local function weightedPick(options)
  local total = 0
  for _, opt in ipairs(options) do
    local w = tonumber(opt.weight) or 0
    if w > 0 then
      total = total + w
    end
  end
  if total <= 0 then
    return nil
  end

  local r = math.random() * total
  local acc = 0
  for _, opt in ipairs(options) do
    local w = tonumber(opt.weight) or 0
    if w > 0 then
      acc = acc + w
      if r <= acc then
        return opt.value
      end
    end
  end

  return options[#options].value
end

local function itemKey(item)
  local t = (type(item) == "table" and item.type) or "text"
  local front = (type(item) == "table" and item.front) or ""
  return tostring(t) .. ":" .. tostring(front)
end

local function cloneItem(item)
  if type(item) ~= "table" then
    return nil
  end
  local meta = nil
  if type(item.meta) == "table" then
    meta = {}
    for k, v in pairs(item.meta) do
      meta[k] = v
    end
  end
  return {
    type = item.type,
    front = item.front,
    back = item.back,
    meta = meta,
  }
end

local function pickFromList(list)
  if type(list) ~= "table" or #list == 0 then
    return nil
  end

  local picked = nil
  local attempts = 0
  repeat
    picked = list[math.random(#list)]
    attempts = attempts + 1
  until itemKey(picked) ~= state.lastKey or attempts >= 8

  if picked then
    state.lastKey = itemKey(picked)
    hs.settings.set("vocabOverlay.lastKey", state.lastKey)
    return cloneItem(picked)
  end

  return nil
end

local function pickFromWordlists()
  local categories = state.wordlists or {}
  if #categories == 0 then
    return nil
  end

  local opts = {}
  for _, cat in ipairs(categories) do
    if type(cat.items) == "table" and #cat.items > 0 then
      table.insert(opts, { weight = cat.weight or 1, value = cat })
    end
  end
  local chosen = weightedPick(opts)
  if not chosen then
    return nil
  end

  local item = pickFromList(chosen.items)
  if item then
    item.meta = item.meta or {}
    item.meta.category = item.meta.category or chosen.id
  end
  return item
end

local function pickNextItem()
  ensureSourcesLoaded()

  local groups = {}

  if state.wordlists and #state.wordlists > 0 and (tonumber(config.sources.wordsWeight) or 0) > 0 then
    table.insert(groups, { weight = config.sources.wordsWeight, value = "words" })
  end
  if state.sentences and #state.sentences > 0 and (tonumber(config.sources.sentencesWeight) or 0) > 0 then
    table.insert(groups, { weight = config.sources.sentencesWeight, value = "sentences" })
  end
  if state.items and #state.items > 0 and (tonumber(config.sources.itemsWeight) or 0) > 0 then
    table.insert(groups, { weight = config.sources.itemsWeight, value = "items" })
  end

  local chosenGroup = weightedPick(groups)
  if chosenGroup == "words" then
    return pickFromWordlists()
  elseif chosenGroup == "sentences" then
    return pickFromList(state.sentences)
  elseif chosenGroup == "items" then
    return pickFromList(state.items)
  end

  return nil
end

local function stopHideTimer()
  if state.hideTimer then
    state.hideTimer:stop()
    state.hideTimer = nil
  end
end

local function setCanvasTexts(item)
  local front = item.front or ""
  local back = item.back or ""

  local isLikelyWord = item.type == "word" or (#front <= 20 and not front:find("%s"))
  local frontSize = isLikelyWord and config.ui.fontSizeWord or config.ui.fontSizeSentence

  for _, c in ipairs(state.canvases) do
    local canvas = c.canvas
    canvas[c.frontIndex].text = front
    canvas[c.frontIndex].textSize = frontSize

    local showBack = state.backRevealed
    canvas[c.backIndex].text = showBack and back or ""

    if state.loading then
      canvas[c.hintIndex].text = "正在生成…   Esc: 关闭   点击背景: 关闭"
    else
      canvas[c.hintIndex].text = showBack and "Space: 隐藏答案   Esc: 关闭   点击背景: 关闭"
        or "Space: 显示答案   Esc: 关闭   点击背景: 关闭"
    end
  end
end

local function destroyCanvases()
  for _, c in ipairs(state.canvases) do
    pcall(function()
      c.canvas:delete(0)
    end)
  end
  state.canvases = {}
end

local function buildCanvasForScreen(screen)
  local frame = screen:fullFrame()
  local canvas = hs.canvas.new(frame)

  canvas:level("screenSaver")
  canvas:behavior({
    "canJoinAllSpaces",
    "moveToActiveSpace",
    "transient",
    "fullScreenAuxiliary", -- ignored if unavailable
    "ignoresCycle",        -- ignored if unavailable
  })

  local cardW = math.min(config.ui.cardMaxWidth, frame.w * 0.82)
  local cardH = math.min(config.ui.cardMaxHeight, frame.h * 0.50)
  local cardX = (frame.w - cardW) / 2
  local cardY = (frame.h - cardH) / 2

  local pad = config.ui.cardPadding
  local hintH = 26
  local backH = math.floor(cardH * 0.33)
  local frontH = cardH - pad * 2 - backH - hintH

  local overlayIndex = 1
  local cardIndex = 2
  local frontIndex = 3
  local backIndex = 4
  local hintIndex = 5

  canvas[overlayIndex] = {
    id = "overlay",
    type = "rectangle",
    action = "fill",
    fillColor = config.ui.overlayColor,
    frame = { x = "0%", y = "0%", w = "100%", h = "100%" },
    trackMouseDown = true,
  }

  canvas[cardIndex] = {
    id = "card",
    type = "rectangle",
    action = "strokeAndFill",
    fillColor = config.ui.cardColor,
    strokeColor = config.ui.cardStrokeColor,
    strokeWidth = 2,
    roundedRectRadii = { xRadius = config.ui.cornerRadius, yRadius = config.ui.cornerRadius },
    withShadow = true,
    shadow = { blurRadius = 22, color = { alpha = 0.28 }, offset = { h = 0, w = 0 } },
    frame = { x = cardX, y = cardY, w = cardW, h = cardH },
    trackMouseDown = true,
  }

  canvas[frontIndex] = {
    id = "frontText",
    type = "text",
    text = "",
    textColor = config.ui.frontTextColor,
    textFont = config.ui.fontFront,
    textSize = config.ui.fontSizeSentence,
    textAlignment = "center",
    textLineBreak = "wordWrap",
    frame = { x = cardX + pad, y = cardY + pad, w = cardW - pad * 2, h = frontH },
  }

  canvas[backIndex] = {
    id = "backText",
    type = "text",
    text = "",
    textColor = config.ui.backTextColor,
    textFont = config.ui.fontBack,
    textSize = config.ui.fontSizeBack,
    textAlignment = "center",
    textLineBreak = "wordWrap",
    frame = { x = cardX + pad, y = cardY + pad + frontH, w = cardW - pad * 2, h = backH },
  }

  canvas[hintIndex] = {
    id = "hintText",
    type = "text",
    text = "",
    textColor = config.ui.hintTextColor,
    textFont = config.ui.fontHint,
    textSize = config.ui.fontSizeHint,
    textAlignment = "center",
    textLineBreak = "truncateTail",
    frame = { x = cardX + pad, y = cardY + cardH - pad - hintH, w = cardW - pad * 2, h = hintH },
  }

  canvas:mouseCallback(function(_, msg, id)
    if msg ~= "mouseDown" then
      return
    end
    if id == "card" then
      M.toggleBack()
    else
      M.hide()
    end
  end)

  return {
    canvas = canvas,
    frontIndex = frontIndex,
    backIndex = backIndex,
    hintIndex = hintIndex,
  }
end

local function ensureCanvases()
  if not state.needsRebuild and #state.canvases > 0 then
    return
  end

  destroyCanvases()

  for _, screen in ipairs(hs.screen.allScreens()) do
    table.insert(state.canvases, buildCanvasForScreen(screen))
  end

  state.needsRebuild = false
end

local function enterModal()
  if not state.modal then
    return
  end
  state.modal:enter()
end

local function exitModal()
  if not state.modal then
    return
  end
  state.modal:exit()
end

local function cancelPending()
  if state.pending and state.pending.timeoutTimer then
    state.pending.timeoutTimer:stop()
  end
  state.pending = nil
  state.loading = false
end

local function startHideTimer(seconds)
  stopHideTimer()
  state.hideTimer = hs.timer.doAfter(seconds, function()
    M.hide()
  end)
end

local function showItemNoTimer(item)
  ensureCanvases()
  stopHideTimer()

  state.visible = true
  state.backRevealed = config.showBackByDefault
  state.currentItem = item

  setCanvasTexts(item)
  for _, c in ipairs(state.canvases) do
    c.canvas:show(config.ui.fadeInSeconds)
    c.canvas:bringToFront(true)
  end

  enterModal()
end

function M.show(item)
  cancelPending()
  showItemNoTimer(item)
  startHideTimer(config.displaySeconds)
end

function M.hide()
  if not state.visible then
    cancelPending()
    return
  end

  stopHideTimer()
  cancelPending()
  exitModal()

  for _, c in ipairs(state.canvases) do
    pcall(function()
      c.canvas:hide(config.ui.fadeOutSeconds)
    end)
  end

  state.visible = false
  state.backRevealed = false
  state.currentItem = nil
end

function M.toggleBack()
  if not state.visible then
    return
  end
  state.backRevealed = not state.backRevealed
  if state.currentItem then
    setCanvasTexts(state.currentItem)
  end
end

local function llmEnabled()
  return config.llm
    and config.llm.enabled
    and type(config.llm.endpoint) == "string"
    and config.llm.endpoint ~= ""
end

local function collectCategoryIds()
  local ids = {}
  local cats = config.sources and config.sources.wordlists and config.sources.wordlists.categories
  if type(cats) ~= "table" then
    return ids
  end
  for _, cat in ipairs(cats) do
    if type(cat.id) == "string" and cat.id ~= "" then
      table.insert(ids, cat.id)
    end
  end
  return ids
end

local function normalizeItem(raw)
  local out = normalizeItems({ raw })
  return out[1]
end

local function decodeJsonMaybe(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  local ok, decoded = pcall(json.decode, text)
  if ok then
    return decoded
  end
  return nil
end

local function extractFirstJson(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  local code = text:match("```json%s*(.-)%s*```") or text:match("```%s*(.-)%s*```") or text
  local obj = code:match("(%b{})")
  if obj then
    return obj
  end
  local arr = code:match("(%b[])")
  if arr then
    return arr
  end
  return nil
end

local function parseItemFromResponseBody(body)
  local data = decodeJsonMaybe(body)
  if not data then
    local extracted = extractFirstJson(body)
    if extracted then
      data = decodeJsonMaybe(extracted)
    end
  end
  if not data then
    return nil
  end

  local candidate = data.item
  if not candidate and type(data.items) == "table" then
    candidate = data.items[1]
  end
  if not candidate then
    candidate = data
  end

  if type(candidate) == "string" then
    local inner = decodeJsonMaybe(candidate) or decodeJsonMaybe(extractFirstJson(candidate) or "")
    if inner then
      candidate = inner.item or (type(inner.items) == "table" and inner.items[1]) or inner
    end
  end

  if type(candidate) ~= "table" and type(data.choices) == "table" and type(data.choices[1]) == "table" then
    local content = (data.choices[1].message and data.choices[1].message.content) or data.choices[1].text
    local extracted = extractFirstJson(content or "")
    local decoded = decodeJsonMaybe(extracted or "")
    if decoded then
      candidate = decoded.item or (type(decoded.items) == "table" and decoded.items[1]) or decoded
    end
  end

  if type(candidate) ~= "table" then
    return nil
  end
  return normalizeItem(candidate)
end

local function buildLlmHeaders()
  local headers = { ["Content-Type"] = "application/json" }
  for k, v in pairs(config.llm.extraHeaders or {}) do
    headers[k] = v
  end
  if type(config.llm.apiKey) == "string" and config.llm.apiKey ~= "" then
    headers["Authorization"] = "Bearer " .. config.llm.apiKey
  end
  return headers
end

local function buildLlmPayload(baseItem)
  local mode = config.llm.mode or "enrich"
  local payload = {
    mode = mode,
    preferences = config.llm.preferences or {},
  }
  if mode == "generate" then
    payload.categories = collectCategoryIds()
  else
    payload.item = baseItem
  end
  return payload
end

local function llmRequest(payload, callback)
  local body = json.encode(payload) or "{}"
  http.doAsyncRequest(config.llm.endpoint, "POST", body, buildLlmHeaders(), function(code, respBody)
    callback(code, respBody)
  end)
end

function M.showNext()
  local baseItem = pickNextItem()
  if not baseItem then
    hs.alert.show("vocab_overlay: 没有可用条目（检查 data/items.json / sentences.txt / wordlists/*.txt）")
    return
  end

  if not llmEnabled() then
    M.show(baseItem)
    return
  end

  cancelPending()
  state.loading = true

  local mode = config.llm.mode or "enrich"
  local timeoutSeconds = tonumber(config.llm.timeoutSeconds) or 8
  local requestId = (state.pending and state.pending.id or 0) + 1
  state.pending = { id = requestId }

  local fallbackItem = baseItem
  local provisionalItem
  if mode == "generate" then
    provisionalItem = { type = "text", front = "正在生成…", back = "" }
  else
    provisionalItem = cloneItem(baseItem) or baseItem
    provisionalItem.back = ""
  end

  showItemNoTimer(provisionalItem)

  local finalized = false
  local function finalize(finalItem)
    if finalized then
      return
    end
    finalized = true

    if state.pending and state.pending.timeoutTimer then
      state.pending.timeoutTimer:stop()
    end
    state.pending = nil
    state.loading = false

    local item = finalItem or fallbackItem
    if not item then
      M.hide()
      return
    end

    state.backRevealed = config.showBackByDefault
    state.currentItem = item
    setCanvasTexts(item)
    startHideTimer(config.displaySeconds)
  end

  state.pending.timeoutTimer = hs.timer.doAfter(timeoutSeconds, function()
    if not state.pending or state.pending.id ~= requestId then
      return
    end
    log("llm request timeout; fallback")
    finalize(fallbackItem)
  end)

  local payload = buildLlmPayload(baseItem)
  llmRequest(payload, function(code, body)
    if not state.pending or state.pending.id ~= requestId then
      return
    end

    if type(code) ~= "number" or code < 200 or code >= 300 then
      log("llm request failed: " .. tostring(code))
      finalize(fallbackItem)
      return
    end

    local item = parseItemFromResponseBody(body)
    if not item then
      log("llm response parse failed; fallback")
      finalize(fallbackItem)
      return
    end

    if mode == "enrich" and baseItem then
      if item.type == nil or item.type == "text" then
        item.type = baseItem.type
      end
      item.front = item.front or baseItem.front
      if type(item.back) ~= "string" or item.back == "" then
        item.back = baseItem.back or ""
      end
      item.meta = item.meta or baseItem.meta
    end

    finalize(item)
  end)
end

function M.startTimer()
  if state.intervalTimer then
    return
  end
  state.intervalTimer = hs.timer.doEvery(config.intervalSeconds, function()
    M.showNext()
  end)
  log("timer started")
end

function M.stopTimer()
  if not state.intervalTimer then
    return
  end
  state.intervalTimer:stop()
  state.intervalTimer = nil
  log("timer stopped")
end

function M.toggleTimer()
  if state.intervalTimer then
    M.stopTimer()
    hs.alert.show("单词弹窗：已暂停")
  else
    M.startTimer()
    hs.alert.show("单词弹窗：已开启")
  end
end

function M.reload()
  loadAllSources()
  hs.alert.show("vocab_overlay: 已重新加载本地数据")
end

local function bindHotkeys()
  hs.hotkey.bind(config.hotkeys.showNow[1], config.hotkeys.showNow[2], function()
    M.showNext()
  end)
  hs.hotkey.bind(config.hotkeys.toggleTimer[1], config.hotkeys.toggleTimer[2], function()
    M.toggleTimer()
  end)
  hs.hotkey.bind(config.hotkeys.reloadData[1], config.hotkeys.reloadData[2], function()
    M.reload()
  end)
end

local function setupModal()
  state.modal = hs.hotkey.modal.new(nil, nil)
  state.modal:bind({}, "escape", function()
    M.hide()
  end)
  state.modal:bind({}, "space", function()
    M.toggleBack()
  end)
end

local function watchScreens()
  local watcher = hs.screen.watcher.new(function()
    state.needsRebuild = true
  end)
  watcher:start()
  state.screenWatcher = watcher
end

function M.start()
  if state.initialized then
    return
  end
  state.initialized = true

  if config.hideDockIcon and hs.dockicon and hs.dockicon.hide then
    hs.dockicon.hide()
  end

  math.randomseed(os.time())
  loadAllSources()
  setupModal()
  bindHotkeys()
  watchScreens()

  if config.autoStart then
    M.startTimer()
  end
  log("ready")
end

return M
