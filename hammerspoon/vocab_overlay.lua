local M = {}

-- Allow a basic syntax check with plain Lua (outside Hammerspoon).
if not hs then
  return M
end

local json = require("hs.json")
local http = require("hs.http")
local fs = require("hs.fs")

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
    protocol = "simple", -- "simple" (custom endpoint) | "openai" (OpenAI-compatible /v1/chat/completions)
    mode = "generate", -- "generate" (ask LLM for a new item) | "enrich" (fill back for a picked item)
    endpoint = "",
    model = "", -- required when protocol == "openai"
    apiKey = "", -- optional (sent as `Authorization: Bearer ...`)
    apiKeyEnv = "OPENAI_API_KEY",
    timeoutSeconds = 8,
    temperature = 0.2,
    maxTokens = 280,
    generate = {
      wordWeight = 6,
      sentenceWeight = 2,
      newWordsBeforeReview = 3, -- after N new words, show 1 review word
      avoidListSize = 40,
      maxRetries = 6,
    },
    extraHeaders = {},
    preferences = {
      language = "zh",
      style = "concise",
      includeExample = true,
    },
  },

  storage = {
    storeFile = hs.configdir .. "/data/generated_store.json",
    saveDebounceSeconds = 0.4,
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
  store = nil,
  storeIndex = nil,
  storeSaveTimer = nil,
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
  newWordStreak = hs.settings.get("vocabOverlay.newWordStreak") or 0,
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

local function writeFile(path, content)
  local f, err = io.open(path, "w")
  if not f then
    return nil, err
  end
  f:write(content or "")
  f:close()
  return true
end

local function ensureDir(path)
  local attr = fs.attributes(path)
  if attr and attr.mode == "directory" then
    return true
  end
  local ok, err = fs.mkdir(path)
  if ok then
    return true
  end
  -- If it already exists, that's fine.
  local attr2 = fs.attributes(path)
  if attr2 and attr2.mode == "directory" then
    return true
  end
  return nil, err
end

local function nowSeconds()
  return os.time()
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
  front = trim(tostring(front)):gsub("%s+", " ")
  return (tostring(t) .. ":" .. front):lower()
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

local function sanitizeMeta(meta)
  if type(meta) ~= "table" then
    return nil
  end
  local out = {}
  for k, v in pairs(meta) do
    if k ~= "phase" and k ~= "_phase" and k ~= "_transient" and k ~= "reviewCount" then
      out[k] = v
    end
  end
  return out
end

local function ensureStoreLoaded()
  if state.store and state.storeIndex then
    return
  end

  ensureDir(hs.configdir .. "/data")

  local path = config.storage.storeFile
  local content = readFile(path)
  local decoded = nil
  if content and content ~= "" then
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then
      decoded = data
    end
  end

  local store = { version = 1, items = {} }
  if decoded and type(decoded.items) == "table" then
    store.version = tonumber(decoded.version) or 1
    store.items = decoded.items
  end

  local items = {}
  local index = {}
  for _, raw in ipairs(store.items or {}) do
    if type(raw) == "table" then
      local front = raw.front or raw.q or raw.word or raw.sentence or raw[1]
      local back = raw.back or raw.a or raw.meaning or raw.translation or raw[2]
      if type(front) == "string" and front ~= "" then
        local rec = {
          type = raw.type or "text",
          front = front,
          back = (type(back) == "string") and back or "",
          meta = (type(raw.meta) == "table") and raw.meta or nil,
          createdAt = tonumber(raw.createdAt) or 0,
          seenCount = tonumber(raw.seenCount) or 0,
          lastSeenAt = tonumber(raw.lastSeenAt) or 0,
        }
        if rec.createdAt <= 0 then
          rec.createdAt = nowSeconds()
        end
        local key = itemKey(rec)
        local existing = index[key]
        if existing then
          if (type(existing.back) ~= "string" or existing.back == "") and type(rec.back) == "string" then
            existing.back = rec.back
          end
          existing.seenCount = math.max(existing.seenCount or 0, rec.seenCount or 0)
          existing.lastSeenAt = math.max(existing.lastSeenAt or 0, rec.lastSeenAt or 0)
          existing.createdAt = math.min(existing.createdAt or rec.createdAt, rec.createdAt)
          existing.meta = existing.meta or rec.meta
        else
          index[key] = rec
          table.insert(items, rec)
        end
      end
    end
  end

  state.store = { version = store.version or 1, items = items }
  state.storeIndex = index
end

local function saveStoreNow()
  ensureStoreLoaded()
  local path = config.storage.storeFile
  local payload = {
    version = state.store.version or 1,
    items = state.store.items or {},
  }
  local encoded = json.encode(payload, true) or "{}"
  local ok, err = writeFile(path, encoded)
  if not ok then
    log("failed to save store: " .. tostring(err))
  end
end

local function scheduleStoreSave()
  if state.storeSaveTimer then
    return
  end
  local delay = tonumber(config.storage.saveDebounceSeconds) or 0
  if delay <= 0 then
    saveStoreNow()
    return
  end
  state.storeSaveTimer = hs.timer.doAfter(delay, function()
    state.storeSaveTimer = nil
    saveStoreNow()
  end)
end

local function storeHas(itemType, front)
  ensureStoreLoaded()
  local key = itemKey({ type = itemType, front = front })
  return state.storeIndex[key] ~= nil
end

local function storeUpsert(item, source)
  ensureStoreLoaded()
  if type(item) ~= "table" or type(item.front) ~= "string" or item.front == "" then
    return nil
  end

  local key = itemKey(item)
  local existing = state.storeIndex[key]
  if existing then
    if type(item.back) == "string" and item.back ~= "" then
      existing.back = item.back
    end
    local meta = sanitizeMeta(item.meta)
    if meta then
      existing.meta = existing.meta or {}
      for k, v in pairs(meta) do
        if existing.meta[k] == nil then
          existing.meta[k] = v
        end
      end
    end
    if source and source ~= "" then
      existing.meta = existing.meta or {}
      existing.meta.source = existing.meta.source or source
    end
    scheduleStoreSave()
    return existing
  end

  local meta = sanitizeMeta(item.meta)
  if source and source ~= "" then
    meta = meta or {}
    meta.source = meta.source or source
  end

  local rec = {
    type = item.type or "text",
    front = item.front,
    back = (type(item.back) == "string") and item.back or "",
    meta = meta,
    createdAt = nowSeconds(),
    seenCount = 0,
    lastSeenAt = 0,
  }

  state.storeIndex[key] = rec
  table.insert(state.store.items, rec)
  scheduleStoreSave()
  return rec
end

local function storeMarkSeen(item, source)
  local rec = storeUpsert(item, source)
  if not rec then
    return nil
  end
  rec.seenCount = (tonumber(rec.seenCount) or 0) + 1
  rec.lastSeenAt = nowSeconds()
  scheduleStoreSave()
  return rec
end

local function storeRecentFronts(itemType, limit)
  ensureStoreLoaded()
  local limitN = tonumber(limit) or 0
  if limitN <= 0 then
    return {}
  end

  local candidates = {}
  for _, rec in ipairs(state.store.items or {}) do
    if rec.type == itemType and type(rec.front) == "string" and rec.front ~= "" then
      table.insert(candidates, rec)
    end
  end
  table.sort(candidates, function(a, b)
    return (tonumber(a.createdAt) or 0) > (tonumber(b.createdAt) or 0)
  end)

  local out = {}
  for i = 1, math.min(limitN, #candidates) do
    table.insert(out, candidates[i].front)
  end
  return out
end

local function storePickReviewWord()
  ensureStoreLoaded()
  local best = nil
  local bestSeenAt = nil

  for _, rec in ipairs(state.store.items or {}) do
    if rec.type == "word" and (tonumber(rec.seenCount) or 0) > 0 then
      local key = itemKey(rec)
      if key ~= state.lastKey then
        local seenAt = tonumber(rec.lastSeenAt) or 0
        if not best or seenAt < (bestSeenAt or 0) then
          best = rec
          bestSeenAt = seenAt
        end
      end
    end
  end

  if not best then
    -- Allow repeating the last one if we only have one record.
    for _, rec in ipairs(state.store.items or {}) do
      if rec.type == "word" and (tonumber(rec.seenCount) or 0) > 0 then
        best = rec
        break
      end
    end
  end

  if not best then
    return nil
  end

  local item = cloneItem(best)
  item.meta = item.meta or {}
  item.meta._phase = "old"
  item.meta.reviewCount = tonumber(best.seenCount) or 0
  return item
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

  local badgeParts = {}
  if type(item.meta) == "table" then
    local phase = item.meta._phase or item.meta.phase
    if phase == "new" then
      table.insert(badgeParts, "新词")
    elseif phase == "old" then
      table.insert(badgeParts, "旧词")
    elseif phase == "new_sentence" then
      table.insert(badgeParts, "新句")
    end
    if type(item.meta.category) == "string" and item.meta.category ~= "" then
      table.insert(badgeParts, item.meta.category)
    end
    if type(item.meta.reviewCount) == "number" and item.meta.reviewCount > 0 then
      table.insert(badgeParts, ("复习%d次"):format(item.meta.reviewCount))
    end
  end
  local badge = ""
  if #badgeParts > 0 then
    badge = "【" .. table.concat(badgeParts, " ") .. "】 "
  end

  for _, c in ipairs(state.canvases) do
    local canvas = c.canvas
    canvas[c.frontIndex].text = front
    canvas[c.frontIndex].textSize = frontSize

    local showBack = state.backRevealed
    canvas[c.backIndex].text = showBack and back or ""

    canvas[c.hintIndex].text = badge
      .. (showBack and "Space: 隐藏答案   Esc: 关闭   点击背景: 关闭" or "Space: 显示答案   Esc: 关闭   点击背景: 关闭")
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
  if type(item) ~= "table" then
    return
  end

  state.lastKey = itemKey(item)
  hs.settings.set("vocabOverlay.lastKey", state.lastKey)

  if item.type == "word" and type(item.meta) == "table" then
    local phase = item.meta._phase or item.meta.phase
    if phase == "new" then
      state.newWordStreak = (tonumber(state.newWordStreak) or 0) + 1
      hs.settings.set("vocabOverlay.newWordStreak", state.newWordStreak)
    elseif phase == "old" then
      state.newWordStreak = 0
      hs.settings.set("vocabOverlay.newWordStreak", 0)
    end
  end

  local source = (type(item.meta) == "table" and item.meta.source) or "local"
  storeMarkSeen(item, source)

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
  if not (config.llm and config.llm.enabled) then
    return false
  end
  if type(config.llm.endpoint) ~= "string" or config.llm.endpoint == "" then
    return false
  end
  local protocol = config.llm.protocol or "simple"
  if protocol == "openai" and (type(config.llm.model) ~= "string" or config.llm.model == "") then
    return false
  end
  return true
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

local function collectCategoriesWithWeights()
  local out = {}
  local cats = config.sources and config.sources.wordlists and config.sources.wordlists.categories
  if type(cats) ~= "table" then
    return out
  end
  for _, cat in ipairs(cats) do
    if type(cat.id) == "string" and cat.id ~= "" then
      table.insert(out, { id = cat.id, weight = tonumber(cat.weight) or 1 })
    end
  end
  return out
end

local function chooseCategoryWeighted()
  local cats = collectCategoriesWithWeights()
  local opts = {}
  for _, cat in ipairs(cats) do
    if type(cat.id) == "string" and cat.id ~= "" then
      table.insert(opts, { weight = tonumber(cat.weight) or 1, value = cat.id })
    end
  end
  return weightedPick(opts)
end

local function chooseGenerateType()
  local gen = config.llm and config.llm.generate or {}
  local opts = {
    { weight = tonumber(gen.wordWeight) or 0, value = "word" },
    { weight = tonumber(gen.sentenceWeight) or 0, value = "sentence" },
  }
  local picked = weightedPick(opts)
  return picked or "word"
end

local function isValidGeneratedItem(item, desiredType)
  if type(item) ~= "table" then
    return false
  end
  if type(item.front) ~= "string" or trim(item.front) == "" then
    return false
  end
  if desiredType and item.type and item.type ~= desiredType then
    return false
  end

  local front = trim(item.front)
  if desiredType == "word" then
    if front:find("%s") then
      return false
    end
    if front:find("[\r\n\t]") then
      return false
    end
  elseif desiredType == "sentence" then
    if not front:find("%s") then
      return false
    end
  end

  return true
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

  local candidate = nil
  if type(data) == "table" then
    if data.item ~= nil then
      candidate = data.item
    elseif type(data.items) == "table" and data.items[1] ~= nil then
      candidate = data.items[1]
    end
  end

  -- OpenAI-compatible: parse from choices[1].message.content / choices[1].text
  if not candidate and type(data) == "table" and type(data.choices) == "table" and type(data.choices[1]) == "table" then
    local content = (data.choices[1].message and data.choices[1].message.content) or data.choices[1].text
    local extracted = extractFirstJson(content or "")
    local decoded = decodeJsonMaybe(extracted or "")
    if decoded then
      candidate = decoded.item or (type(decoded.items) == "table" and decoded.items[1]) or decoded
    end
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

  if type(candidate) ~= "table" then
    return nil
  end

  local item = normalizeItem(candidate)
  if item then
    return item
  end

  -- If we accidentally normalized the whole OpenAI response table, try choices as fallback.
  if type(data) == "table" and type(data.choices) == "table" and type(data.choices[1]) == "table" then
    local content = (data.choices[1].message and data.choices[1].message.content) or data.choices[1].text
    local extracted = extractFirstJson(content or "")
    local decoded = decodeJsonMaybe(extracted or "")
    if decoded then
      local cand2 = decoded.item or (type(decoded.items) == "table" and decoded.items[1]) or decoded
      if type(cand2) == "table" then
        return normalizeItem(cand2)
      end
    end
  end

  return nil
end

local function buildLlmHeaders()
  local headers = { ["Content-Type"] = "application/json" }
  for k, v in pairs(config.llm.extraHeaders or {}) do
    headers[k] = v
  end

  local apiKey = ""
  if type(config.llm.apiKey) == "string" and config.llm.apiKey ~= "" then
    apiKey = config.llm.apiKey
  else
    local envName = (type(config.llm.apiKeyEnv) == "string") and config.llm.apiKeyEnv or ""
    if envName ~= "" then
      apiKey = os.getenv(envName) or ""
    end
  end
  if apiKey ~= "" then
    headers["Authorization"] = "Bearer " .. apiKey
  end
  return headers
end

local function buildSimplePayload(baseItem, opts)
  local mode = (type(opts) == "table" and opts.mode) or config.llm.mode or "generate"
  local payload = {
    mode = mode,
    preferences = config.llm.preferences or {},
  }
  if mode == "generate" then
    payload.categories = collectCategoryIds()
    payload.constraints = {
      type = (type(opts) == "table" and opts.desiredType) or nil,
      category = (type(opts) == "table" and opts.desiredCategory) or nil,
      avoid = (type(opts) == "table" and opts.avoidFronts) or nil,
    }
  else
    payload.item = baseItem
  end
  return payload
end

local function buildOpenAiMessages(baseItem, opts)
  local prefs = config.llm.preferences or {}
  local language = (type(prefs.language) == "string" and prefs.language ~= "") and prefs.language or "zh"
  local style = (type(prefs.style) == "string" and prefs.style ~= "") and prefs.style or "concise"
  local includeExample = prefs.includeExample ~= false

  local mode = (type(opts) == "table" and opts.mode) or config.llm.mode or "generate"
  local desiredType = type(opts) == "table" and opts.desiredType or nil
  local desiredCategory = type(opts) == "table" and opts.desiredCategory or nil
  local avoidFronts = type(opts) == "table" and opts.avoidFronts or nil

  local systemPrompt = table.concat({
    "You are a language tutor helping a Chinese learner memorize English words and sentences.",
    "Return STRICT JSON only. No markdown. No extra text.",
    'Your JSON must be an object with key "item".',
    'Schema: {"item":{"type":"word|sentence","front":"...","back":"...","meta":{...}}}',
    'The "front" must be English. The "back" must be in ' .. language .. ".",
    'Keep it ' .. style .. " and easy to review quickly.",
    includeExample and 'If possible, include 1 short example sentence and its ' .. language .. " translation in back." or "No example sentence is required.",
  }, "\n")

  local userPrompt
  if mode == "generate" then
    local categories = collectCategoriesWithWeights()
    local desiredLine = ""
    if desiredType == "word" then
      desiredLine = "Type requirement: word (a single English word, no spaces)."
    elseif desiredType == "sentence" then
      desiredLine = "Type requirement: sentence (a short natural English sentence)."
    end

    local categoryLine = ""
    if type(desiredCategory) == "string" and desiredCategory ~= "" then
      categoryLine = "Target category: " .. desiredCategory .. " (put it into item.meta.category)."
    end

    local avoidLine = ""
    if type(avoidFronts) == "table" and #avoidFronts > 0 then
      avoidLine = "Avoid returning any of these item.front values: " .. (json.encode(avoidFronts) or "[]")
    end

    userPrompt = table.concat({
      "Generate ONE item for spaced repetition.",
      desiredLine,
      categoryLine ~= "" and categoryLine or "Choose exactly one category from the list below, and put it into item.meta.category.",
      "Categories (id, weight): " .. (json.encode(categories) or "[]"),
      avoidLine,
      "",
      'Output JSON only. Example:',
      '{"item":{"type":"word","front":"algorithm","back":"算法；…\\nExample: ...\\n译: ...","meta":{"category":"cs"}}}',
    }, "\n")
  else
    local input = {
      type = baseItem and baseItem.type or "word",
      front = baseItem and baseItem.front or "",
      back = baseItem and baseItem.back or "",
      meta = baseItem and baseItem.meta or nil,
    }
    userPrompt = table.concat({
      "Enrich the following item for quick memorization.",
      'Keep item.front unchanged. Put meaning/notes into item.back.',
      "Input: " .. (json.encode(input) or "{}"),
      "",
      'Output JSON only. Example:',
      '{"item":{"type":"word","front":"algorithm","back":"算法；…\\nExample: ...\\n译: ...","meta":{"category":"cs"}}}',
    }, "\n")
  end

  return {
    { role = "system", content = systemPrompt },
    { role = "user", content = userPrompt },
  }
end

local function buildOpenAiRequest(baseItem, opts)
  local req = {
    model = config.llm.model,
    messages = buildOpenAiMessages(baseItem, opts),
    temperature = tonumber(config.llm.temperature) or 0.2,
  }
  local maxTokens = tonumber(config.llm.maxTokens)
  if maxTokens and maxTokens > 0 then
    req.max_tokens = math.floor(maxTokens)
  end
  return req
end

local function buildLlmRequest(baseItem, opts)
  local protocol = config.llm.protocol or "simple"
  if protocol == "openai" then
    return buildOpenAiRequest(baseItem, opts)
  end
  return buildSimplePayload(baseItem, opts)
end

local function llmRequest(baseItem, opts, callback)
  local payload = buildLlmRequest(baseItem, opts)
  local body = json.encode(payload) or "{}"
  http.doAsyncRequest(config.llm.endpoint, "POST", body, buildLlmHeaders(), function(code, respBody)
    callback(code, respBody)
  end)
end

local function showFallback()
  local item = pickNextItem()
  if item then
    M.show(item)
    return true
  end
  local review = storePickReviewWord()
  if review then
    M.show(review)
    return true
  end
  return false
end

local function buildAvoidList(itemType, extraFronts)
  local gen = config.llm and config.llm.generate or {}
  local limit = tonumber(gen.avoidListSize) or 0
  if limit <= 0 then
    limit = 0
  end

  local base = storeRecentFronts(itemType, limit)
  local out = {}
  local seen = {}
  local function add(v)
    if type(v) ~= "string" then
      return
    end
    v = trim(v)
    if v == "" then
      return
    end
    local k = v:lower()
    if seen[k] then
      return
    end
    seen[k] = true
    table.insert(out, v)
  end

  if type(extraFronts) == "table" then
    for _, v in ipairs(extraFronts) do
      add(v)
      if limit > 0 and #out >= limit then
        return out
      end
    end
  end

  for _, v in ipairs(base) do
    add(v)
    if limit > 0 and #out >= limit then
      break
    end
  end
  return out
end

local function requestGenerate(requestId, desiredType, desiredCategory, attempt, extraAvoid)
  local gen = config.llm and config.llm.generate or {}
  local maxRetries = tonumber(gen.maxRetries) or 6
  local attemptN = tonumber(attempt) or 1

  local opts = {
    mode = "generate",
    desiredType = desiredType,
    desiredCategory = desiredCategory,
    avoidFronts = buildAvoidList(desiredType, extraAvoid),
  }

  llmRequest(nil, opts, function(code, body)
    if not state.pending or state.pending.id ~= requestId then
      return
    end

    if type(code) ~= "number" or code < 200 or code >= 300 then
      log(("llm generate failed (attempt %d/%d): %s"):format(attemptN, maxRetries, tostring(code)))
      if attemptN < maxRetries then
        requestGenerate(requestId, desiredType, desiredCategory, attemptN + 1, extraAvoid)
      else
        state.pending = nil
        if not showFallback() then
          hs.alert.show("vocab_overlay: LLM 失败且无本地数据")
        end
      end
      return
    end

    local item = parseItemFromResponseBody(body)
    if not isValidGeneratedItem(item, desiredType) then
      log(("llm generate invalid item (attempt %d/%d)"):format(attemptN, maxRetries))
      if attemptN < maxRetries then
        requestGenerate(requestId, desiredType, desiredCategory, attemptN + 1, extraAvoid)
      else
        state.pending = nil
        if not showFallback() then
          hs.alert.show("vocab_overlay: LLM 返回无效内容")
        end
      end
      return
    end

    item.type = desiredType
    item.front = trim(item.front):gsub("%s+", " ")

    if desiredType == "word" and not item.front:match("[%a]") then
      if attemptN < maxRetries then
        requestGenerate(requestId, desiredType, desiredCategory, attemptN + 1, extraAvoid)
      else
        state.pending = nil
        showFallback()
      end
      return
    end

    if storeHas(desiredType, item.front) then
      log(("duplicate generated, retrying: %s"):format(item.front))
      local nextAvoid = extraAvoid or {}
      table.insert(nextAvoid, item.front)
      if attemptN < maxRetries then
        requestGenerate(requestId, desiredType, desiredCategory, attemptN + 1, nextAvoid)
      else
        state.pending = nil
        showFallback()
      end
      return
    end

    item.meta = item.meta or {}
    item.meta.source = item.meta.source or "llm"
    if desiredType == "word" then
      item.meta.category = item.meta.category or desiredCategory
      item.meta._phase = "new"
    else
      item.meta._phase = "new_sentence"
    end

    M.show(item)
  end)
end

function M.showNext()
  local useLlm = llmEnabled()
  local mode = config.llm.mode or "generate"

  if not useLlm then
    local item = pickNextItem()
    if not item then
      hs.alert.show("vocab_overlay: 没有可用条目（检查 data/items.json / sentences.txt / wordlists/*.txt）")
      return
    end
    M.show(item)
    return
  end

  if mode ~= "generate" then
    local baseItem = pickNextItem()
    if not baseItem then
      hs.alert.show("vocab_overlay: 没有可用条目用于 enrich（请先准备本地词库/句库）")
      return
    end

    cancelPending()
    local requestId = (state.pending and state.pending.id or 0) + 1
    state.pending = { id = requestId }

    state.pending.timeoutTimer = hs.timer.doAfter(tonumber(config.llm.timeoutSeconds) or 8, function()
      if not state.pending or state.pending.id ~= requestId then
        return
      end
      state.pending = nil
      M.show(baseItem)
    end)

    llmRequest(baseItem, { mode = "enrich" }, function(code, body)
      if not state.pending or state.pending.id ~= requestId then
        return
      end
      if type(code) ~= "number" or code < 200 or code >= 300 then
        state.pending = nil
        M.show(baseItem)
        return
      end
      local item = parseItemFromResponseBody(body)
      if not item then
        state.pending = nil
        M.show(baseItem)
        return
      end
      if item.type == nil or item.type == "text" then
        item.type = baseItem.type
      end
      item.front = item.front or baseItem.front
      if type(item.back) ~= "string" or item.back == "" then
        item.back = baseItem.back or ""
      end
      item.meta = item.meta or baseItem.meta
      M.show(item)
    end)
    return
  end

  -- generate mode (live): generate first, then show. Also interleave old words.
  ensureStoreLoaded()

  local gen = config.llm and config.llm.generate or {}
  local reviewEvery = tonumber(gen.newWordsBeforeReview) or 0
  if reviewEvery > 0 and (tonumber(state.newWordStreak) or 0) >= reviewEvery then
    local review = storePickReviewWord()
    if review then
      M.show(review)
      return
    end
  end

  cancelPending()
  local requestId = (state.pending and state.pending.id or 0) + 1
  state.pending = { id = requestId }

  state.pending.timeoutTimer = hs.timer.doAfter(tonumber(config.llm.timeoutSeconds) or 8, function()
    if not state.pending or state.pending.id ~= requestId then
      return
    end
    log("llm request timeout; fallback")
    state.pending = nil
    showFallback()
  end)

  local desiredType = chooseGenerateType()
  local desiredCategory = nil
  if desiredType == "word" then
    desiredCategory = chooseCategoryWeighted()
  end

  requestGenerate(requestId, desiredType, desiredCategory, 1, {})
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
  if state.storeSaveTimer then
    state.storeSaveTimer:stop()
    state.storeSaveTimer = nil
    saveStoreNow()
  end
  state.store = nil
  state.storeIndex = nil
  ensureStoreLoaded()
  state.newWordStreak = hs.settings.get("vocabOverlay.newWordStreak") or 0
  hs.alert.show("vocab_overlay: 已重新加载本地数据与学习记录")
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
  ensureStoreLoaded()
  setupModal()
  bindHotkeys()
  watchScreens()

  if config.autoStart then
    M.startTimer()
  end
  log("ready")
end

return M
