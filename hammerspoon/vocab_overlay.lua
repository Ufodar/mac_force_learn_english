local M = {}

-- Allow a basic syntax check with plain Lua (outside Hammerspoon).
if not hs then
  return M
end

local json = require("hs.json")
local http = require("hs.http")
local fs = require("hs.fs")

local SETTINGS_KEYS = {
  userConfig = "vocabOverlay.userConfig",
  dnd = "vocabOverlay.dndEnabled",
  reviewMode = "vocabOverlay.reviewMode",
}

local function deepMerge(target, source)
  if type(target) ~= "table" or type(source) ~= "table" then
    return
  end
  for k, v in pairs(source) do
    if type(v) == "table" and type(target[k]) == "table" then
      deepMerge(target[k], v)
    else
      target[k] = v
    end
  end
end

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
    example = {
      avoidListSize = 12,
      maxRetries = 4,
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
    enabled = false, -- set true if you want global shortcuts
    showNow = { { "ctrl", "alt", "cmd" }, "V" },
    toggleTimer = { { "ctrl", "alt", "cmd" }, "T" },
    reloadData = { { "ctrl", "alt", "cmd" }, "I" },
  },

  ui = {
    menuBarTitle = "", -- keep empty to use icon-only (more likely to fit in a crowded menubar)
    menuBarHighlightSeconds = 6,
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

local userConfig = hs.settings.get(SETTINGS_KEYS.userConfig)
if type(userConfig) == "table" then
  deepMerge(config, userConfig)
end

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
  currentAutoHide = true,
  loading = false,
  pending = nil,
  dndEnabled = hs.settings.get(SETTINGS_KEYS.dnd) or false,
  reviewMode = hs.settings.get(SETTINGS_KEYS.reviewMode) or false,
  menuBar = nil,
  settingsView = nil,
  settingsController = nil,

  hideTimer = nil,
  intervalTimer = nil,
  screenWatcher = nil,

  lastKey = hs.settings.get("vocabOverlay.lastKey") or nil,
  newWordStreak = hs.settings.get("vocabOverlay.newWordStreak") or 0,
  needsRebuild = true,

  modal = nil,
  initialized = false,
}

local llmEnabled -- forward declaration; assigned later

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

local function normalizeExample(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local en = raw.en or raw.exampleEn or raw.example or raw[1]
  local zh = raw.zh or raw.exampleZh or raw.translation or raw[2]
  if type(en) ~= "string" then
    return nil
  end
  en = trim(en):gsub("%s+", " ")
  if en == "" then
    return nil
  end
  if type(zh) ~= "string" then
    zh = ""
  end
  zh = trim(zh)
  return {
    en = en,
    zh = zh,
    createdAt = tonumber(raw.createdAt) or 0,
    source = raw.source,
  }
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
        local examples = {}
        local exampleIndex = {}
        if type(raw.examples) == "table" then
          for _, ex in ipairs(raw.examples) do
            local normalized = normalizeExample(ex)
            if normalized then
              local keyEx = normalized.en:lower()
              if not exampleIndex[keyEx] then
                exampleIndex[keyEx] = true
                if normalized.createdAt <= 0 then
                  normalized.createdAt = nowSeconds()
                end
                table.insert(examples, normalized)
              end
            end
          end
        end

        local rec = {
          type = raw.type or "text",
          front = front,
          back = (type(back) == "string") and back or "",
          meta = (type(raw.meta) == "table") and raw.meta or nil,
          createdAt = tonumber(raw.createdAt) or 0,
          seenCount = tonumber(raw.seenCount) or 0,
          lastSeenAt = tonumber(raw.lastSeenAt) or 0,
          examples = examples,
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
          existing.examples = existing.examples or {}
          local existingExamplesIndex = {}
          for _, ex in ipairs(existing.examples) do
            if type(ex) == "table" and type(ex.en) == "string" then
              existingExamplesIndex[ex.en:lower()] = true
            end
          end
          for _, ex in ipairs(rec.examples or {}) do
            if type(ex) == "table" and type(ex.en) == "string" then
              local kex = ex.en:lower()
              if not existingExamplesIndex[kex] then
                existingExamplesIndex[kex] = true
                table.insert(existing.examples, ex)
              end
            end
          end
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
    existing.examples = existing.examples or {}
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
    examples = {},
  }

  state.storeIndex[key] = rec
  table.insert(state.store.items, rec)
  scheduleStoreSave()
  return rec
end

local function storeGetRecord(item)
  ensureStoreLoaded()
  if type(item) ~= "table" then
    return nil
  end
  local key = itemKey(item)
  return state.storeIndex[key]
end

local function storeAddExample(item, example, source)
  ensureStoreLoaded()
  if type(item) ~= "table" then
    return nil
  end
  local rec = storeUpsert(item, source)
  if not rec then
    return nil
  end
  rec.examples = rec.examples or {}

  local ex = normalizeExample(example)
  if not ex then
    return nil
  end
  ex.source = ex.source or source
  if ex.createdAt <= 0 then
    ex.createdAt = nowSeconds()
  end

  local kex = ex.en:lower()
  for _, existing in ipairs(rec.examples) do
    if type(existing) == "table" and type(existing.en) == "string" and existing.en:lower() == kex then
      if existing.zh == "" and ex.zh ~= "" then
        existing.zh = ex.zh
      end
      return existing
    end
  end

  table.insert(rec.examples, ex)
  scheduleStoreSave()
  return ex
end

local function storeLatestExample(item)
  local rec = storeGetRecord(item)
  if not rec or type(rec.examples) ~= "table" or #rec.examples == 0 then
    return nil
  end
  local best = rec.examples[1]
  for _, ex in ipairs(rec.examples) do
    if (tonumber(ex.createdAt) or 0) >= (tonumber(best.createdAt) or 0) then
      best = ex
    end
  end
  return best
end

local function extractExampleFromBack(back)
  if type(back) ~= "string" or back == "" then
    return nil
  end

  local en = back:match("[Ee]xample[:：]%s*(.-)\n") or back:match("例句[:：]%s*(.-)\n")
  if not en then
    en = back:match("[Ee]xample[:：]%s*(.+)$") or back:match("例句[:：]%s*(.+)$")
  end
  if type(en) == "string" then
    en = trim(en):gsub("%s+", " ")
  end
  if not en or en == "" then
    return nil
  end

  local zh = back:match("译[:：]%s*(.-)\n") or back:match("翻译[:：]%s*(.-)\n") or back:match("译[:：]%s*(.+)$")
    or back:match("翻译[:：]%s*(.+)$")
  if type(zh) == "string" then
    zh = trim(zh)
  else
    zh = ""
  end

  return { en = en, zh = zh }
end

local function storeMarkSeen(item, source)
  local rec = storeUpsert(item, source)
  if not rec then
    return nil
  end
  rec.seenCount = (tonumber(rec.seenCount) or 0) + 1
  rec.lastSeenAt = nowSeconds()

  -- If the item's back already contains an example, extract & store it.
  local extracted = extractExampleFromBack(item.back)
  if extracted then
    storeAddExample(item, extracted, source)
  end

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

local function backAlreadyContainsExample(back)
  if type(back) ~= "string" then
    return false
  end
  return back:find("[Ee]xample[:：]") ~= nil or back:find("例句[:：]") ~= nil
end

local function isExampleLoading(item)
  if type(item) ~= "table" then
    return false
  end
  if type(item.meta) ~= "table" then
    return false
  end
  local t = item.meta._transient
  return type(t) == "table" and t.exampleLoading == true
end

local function buildDisplayBack(item)
  local baseBack = (type(item) == "table" and type(item.back) == "string") and trim(item.back) or ""
  local ex = storeLatestExample(item)
  local loading = isExampleLoading(item)

  if (not ex or (ex.zh == "" and ex.en == "")) and not loading then
    return baseBack
  end

  if backAlreadyContainsExample(baseBack) then
    return baseBack
  end

  local parts = {}
  if baseBack ~= "" then
    table.insert(parts, baseBack)
  end

  if ex and type(ex.en) == "string" and ex.en ~= "" then
    table.insert(parts, "Example: " .. ex.en)
    if type(ex.zh) == "string" and ex.zh ~= "" then
      table.insert(parts, "译: " .. ex.zh)
    end
  elseif loading then
    table.insert(parts, "Example: (生成中...)")
  end

  return table.concat(parts, "\n")
end

local function setCanvasTexts(item)
  local front = item.front or ""
  local back = buildDisplayBack(item)

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

    local hint = showBack and "Space: 隐藏答案" or "Space: 显示答案"
    hint = hint .. "   N: 下一条"
    if llmEnabled() and isLikelyWord then
      hint = hint .. "   E: 新例句"
    end
    if state.dndEnabled then
      hint = hint .. "   DND: 开"
    end
    local escHint = state.reviewMode and "Esc: 退出复习" or "Esc: 关闭"
    canvas[c.hintIndex].text = badge .. hint .. "   " .. escHint
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
  -- macOS: canJoinAllSpaces and moveToActiveSpace are mutually exclusive.
  -- Prefer joining all spaces; fall back to moveToActiveSpace if needed.
  local ok = pcall(function()
    canvas:behavior({
      "canJoinAllSpaces",
      "transient",
      "fullScreenAuxiliary", -- ignored if unavailable
      "ignoresCycle",        -- ignored if unavailable
    })
  end)
  if not ok then
    pcall(function()
      canvas:behavior({
        "moveToActiveSpace",
        "transient",
        "fullScreenAuxiliary",
        "ignoresCycle",
      })
    end)
  end

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

function M.show(item, opts)
  cancelPending()
  if type(item) ~= "table" then
    return
  end
  if type(opts) ~= "table" then
    opts = {}
  end
  local autoHide = opts.autoHide
  if autoHide == nil then
    autoHide = true
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
  state.currentAutoHide = autoHide and true or false
  if state.currentAutoHide then
    startHideTimer(config.displaySeconds)
  end
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

llmEnabled = function()
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

local function parseExampleFromResponseBody(body)
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
    if type(data.example) == "table" then
      candidate = data.example
    elseif type(data.examples) == "table" and type(data.examples[1]) == "table" then
      candidate = data.examples[1]
    end
  end

  -- OpenAI-compatible: parse from choices[1].message.content / choices[1].text
  if not candidate and type(data) == "table" and type(data.choices) == "table" and type(data.choices[1]) == "table" then
    local content = (data.choices[1].message and data.choices[1].message.content) or data.choices[1].text
    local extracted = extractFirstJson(content or "")
    local decoded = decodeJsonMaybe(extracted or "")
    if decoded then
      candidate = decoded.example or (type(decoded.examples) == "table" and decoded.examples[1]) or decoded
    end
  end

  if not candidate then
    candidate = data
  end

  if type(candidate) == "string" then
    local inner = decodeJsonMaybe(candidate) or decodeJsonMaybe(extractFirstJson(candidate) or "")
    if inner then
      candidate = inner.example or (type(inner.examples) == "table" and inner.examples[1]) or inner
    end
  end

  if type(candidate) == "table" and type(candidate[1]) == "table" then
    candidate = candidate[1]
  end

  local ex = normalizeExample(candidate)
  if ex then
    return ex
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
  elseif mode == "example" then
    payload.item = baseItem
    payload.constraints = {
      avoidExamples = (type(opts) == "table" and opts.avoidExamples) or nil,
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

  if mode == "example" then
    local systemPrompt = table.concat({
      "You are a language tutor helping a Chinese learner memorize English words.",
      "Return STRICT JSON only. No markdown. No extra text.",
      'Schema: {"example":{"en":"...","zh":"..."}}',
      'The "en" must be a short natural English sentence and MUST contain the given word.',
      'The "zh" must be in ' .. language .. ".",
      "Keep it " .. style .. " and easy to review quickly.",
    }, "\n")

    local avoidLine = ""
    if type(opts) == "table" and type(opts.avoidExamples) == "table" and #opts.avoidExamples > 0 then
      avoidLine = "Avoid using any of these example sentences: " .. (json.encode(opts.avoidExamples) or "[]")
    end

    local word = (type(baseItem) == "table" and type(baseItem.front) == "string") and trim(baseItem.front) or ""
    local meaning = (type(baseItem) == "table" and type(baseItem.back) == "string") and trim(baseItem.back) or ""
    local meaningLine = (meaning ~= "") and ("Meaning/context (may be empty): " .. meaning) or ""

    local userPrompt = table.concat({
      "Generate ONE example sentence for spaced repetition.",
      'Target word: "' .. word .. '"',
      meaningLine,
      avoidLine,
      "",
      "Output JSON only.",
      '{"example":{"en":"...","zh":"..."}}',
    }, "\n")

    return {
      { role = "system", content = systemPrompt },
      { role = "user", content = userPrompt },
    }
  end

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

local function buildExampleAvoidList(item, extraExamples)
  local exCfg = config.llm and config.llm.example or {}
  local limit = tonumber(exCfg.avoidListSize) or 0
  if limit <= 0 then
    limit = 0
  end

  local out = {}
  local seen = {}
  local function add(v)
    if type(v) ~= "string" then
      return
    end
    v = trim(v):gsub("%s+", " ")
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

  if type(extraExamples) == "table" then
    for _, v in ipairs(extraExamples) do
      add(v)
      if limit > 0 and #out >= limit then
        return out
      end
    end
  end

  local rec = storeGetRecord(item)
  if rec and type(rec.examples) == "table" then
    for _, ex in ipairs(rec.examples) do
      if type(ex) == "table" and type(ex.en) == "string" then
        add(ex.en)
        if limit > 0 and #out >= limit then
          break
        end
      end
    end
  end

  return out
end

local function recordHasExample(item, en)
  if type(en) ~= "string" or en == "" then
    return false
  end
  local rec = storeGetRecord(item)
  if not rec or type(rec.examples) ~= "table" then
    return false
  end
  local target = en:lower()
  for _, ex in ipairs(rec.examples) do
    if type(ex) == "table" and type(ex.en) == "string" and ex.en:lower() == target then
      return true
    end
  end
  return false
end

local function exampleContainsWord(exampleEn, word)
  if type(exampleEn) ~= "string" or exampleEn == "" then
    return false
  end
  if type(word) ~= "string" or word == "" then
    return true
  end
  local hay = exampleEn:lower()
  local needle = trim(word):lower()
  if needle == "" then
    return true
  end
  return hay:find(needle, 1, true) ~= nil
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

local function clearCurrentExampleLoading(itemKeyExpected)
  local cur = state.currentItem
  if not cur or itemKey(cur) ~= itemKeyExpected then
    return
  end
  if type(cur.meta) ~= "table" or type(cur.meta._transient) ~= "table" then
    return
  end
  cur.meta._transient.exampleLoading = nil
  if next(cur.meta._transient) == nil then
    cur.meta._transient = nil
  end
end

local function requestExample(requestId, item, attempt, extraAvoidExamples, opts)
  local exCfg = config.llm and config.llm.example or {}
  local maxRetries = tonumber(exCfg.maxRetries) or 4
  local attemptN = tonumber(attempt) or 1
  local itemKeyExpected = itemKey(item)

  local reqOpts = {
    mode = "example",
    avoidExamples = buildExampleAvoidList(item, extraAvoidExamples),
  }

  llmRequest(item, reqOpts, function(code, body)
    if not state.pending or state.pending.id ~= requestId then
      return
    end

    if type(code) ~= "number" or code < 200 or code >= 300 then
      log(("llm example failed (attempt %d/%d): %s"):format(attemptN, maxRetries, tostring(code)))
      if attemptN < maxRetries then
        requestExample(requestId, item, attemptN + 1, extraAvoidExamples, opts)
      else
        local silent = type(opts) == "table" and opts.silent
        state.pending = nil
        clearCurrentExampleLoading(itemKeyExpected)
        if state.currentItem and itemKey(state.currentItem) == itemKeyExpected then
          setCanvasTexts(state.currentItem)
          if state.currentAutoHide then
            startHideTimer(config.displaySeconds)
          end
        end
        if not silent then
          hs.alert.show("例句生成失败", 1.8)
        end
      end
      return
    end

    local ex = parseExampleFromResponseBody(body)
    if not ex or not exampleContainsWord(ex.en, item.front) then
      log(("llm example invalid (attempt %d/%d)"):format(attemptN, maxRetries))
      local nextAvoid = extraAvoidExamples or {}
      if ex and type(ex.en) == "string" and ex.en ~= "" then
        table.insert(nextAvoid, ex.en)
      end
      if attemptN < maxRetries then
        requestExample(requestId, item, attemptN + 1, nextAvoid, opts)
      else
        local silent = type(opts) == "table" and opts.silent
        state.pending = nil
        clearCurrentExampleLoading(itemKeyExpected)
        if state.currentItem and itemKey(state.currentItem) == itemKeyExpected then
          setCanvasTexts(state.currentItem)
          if state.currentAutoHide then
            startHideTimer(config.displaySeconds)
          end
        end
        if not silent then
          hs.alert.show("例句生成无效", 1.8)
        end
      end
      return
    end

    if recordHasExample(item, ex.en) then
      local nextAvoid = extraAvoidExamples or {}
      table.insert(nextAvoid, ex.en)
      if attemptN < maxRetries then
        requestExample(requestId, item, attemptN + 1, nextAvoid, opts)
      else
        local silent = type(opts) == "table" and opts.silent
        state.pending = nil
        clearCurrentExampleLoading(itemKeyExpected)
        if state.currentItem and itemKey(state.currentItem) == itemKeyExpected then
          setCanvasTexts(state.currentItem)
          if state.currentAutoHide then
            startHideTimer(config.displaySeconds)
          end
        end
        if not silent then
          hs.alert.show("例句生成重复", 1.8)
        end
      end
      return
    end

    storeAddExample(item, ex, "llm")
    state.pending = nil
    clearCurrentExampleLoading(itemKeyExpected)

    local cur = state.currentItem
    if cur and itemKey(cur) == itemKeyExpected then
      local revealBack = type(opts) == "table" and opts.revealBack
      if revealBack then
        state.backRevealed = true
      end
      setCanvasTexts(cur)
      if state.currentAutoHide then
        startHideTimer(config.displaySeconds)
      end
    end
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

function M.generateExampleForCurrent(opts)
  if type(opts) ~= "table" then
    opts = {}
  end
  local item = state.currentItem
  if type(item) ~= "table" then
    return
  end

  local front = item.front or ""
  local isLikelyWord = item.type == "word" or (#front <= 20 and not front:find("%s"))
  if not isLikelyWord then
    return
  end

  if not llmEnabled() then
    if not opts.silent then
      hs.alert.show("请先在菜单栏 EN → 设置… 配置 LLM", 2.2)
    end
    return
  end

  local forceNew = opts.forceNew
  if forceNew == nil then
    forceNew = true
  end
  if not forceNew and storeLatestExample(item) then
    return
  end

  cancelPending()
  local requestId = (state.pending and state.pending.id or 0) + 1
  local key = itemKey(item)
  state.pending = { id = requestId, kind = "example", itemKey = key }

  local revealBack = opts.revealBack
  if revealBack == nil then
    revealBack = forceNew
  end
  local silent = opts.silent and true or false

  if revealBack then
    state.backRevealed = true
  end

  item.meta = item.meta or {}
  item.meta._transient = item.meta._transient or {}
  item.meta._transient.exampleLoading = true
  setCanvasTexts(item)

  if state.currentAutoHide then
    stopHideTimer()
  end

  state.pending.timeoutTimer = hs.timer.doAfter(tonumber(config.llm.timeoutSeconds) or 8, function()
    if not state.pending or state.pending.id ~= requestId then
      return
    end
    state.pending = nil
    clearCurrentExampleLoading(key)
    local cur = state.currentItem
    if cur and itemKey(cur) == key then
      setCanvasTexts(cur)
      if state.currentAutoHide then
        startHideTimer(config.displaySeconds)
      end
    end
    if not silent then
      hs.alert.show("例句生成超时", 1.8)
    end
  end)

  local baseItem = cloneItem(item)
  baseItem.meta = sanitizeMeta(baseItem.meta)
  requestExample(requestId, baseItem, 1, {}, { revealBack = revealBack, silent = silent })
end

function M.startTimer()
  if state.intervalTimer then
    return
  end
  state.intervalTimer = hs.timer.doEvery(config.intervalSeconds, function()
    if state.dndEnabled or state.reviewMode then
      return
    end
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

local function computeStats()
  ensureStoreLoaded()
  local stats = {
    words = 0,
    sentences = 0,
    totalSeen = 0,
    examples = 0,
  }

  for _, rec in ipairs(state.store.items or {}) do
    local seen = tonumber(rec.seenCount) or 0
    stats.totalSeen = stats.totalSeen + seen
    if rec.type == "word" then
      stats.words = stats.words + 1
    elseif rec.type == "sentence" then
      stats.sentences = stats.sentences + 1
    end
    if type(rec.examples) == "table" then
      stats.examples = stats.examples + #rec.examples
    end
  end

  stats.newWordStreak = tonumber(state.newWordStreak) or 0
  return stats
end

function M.showStats()
  local s = computeStats()
  local lines = {
    ("已学单词: %d"):format(s.words),
    ("已学句子: %d"):format(s.sentences),
    ("累计复习: %d"):format(s.totalSeen),
    ("例句数: %d"):format(s.examples),
  }
  hs.alert.show(table.concat(lines, "\n"), 3.0)
end

function M.setDndEnabled(enabled)
  state.dndEnabled = enabled and true or false
  hs.settings.set(SETTINGS_KEYS.dnd, state.dndEnabled)
end

function M.toggleDnd()
  M.setDndEnabled(not state.dndEnabled)
  hs.alert.show(state.dndEnabled and "勿扰模式：已开启" or "勿扰模式：已关闭", 1.8)
end

function M.reviewNext()
  local item = storePickReviewWord()
  if not item then
    hs.alert.show("暂无可复习旧词", 2.0)
    return
  end
  M.show(item, { autoHide = false })
  if llmEnabled() and item.type == "word" and not storeLatestExample(item) then
    hs.timer.doAfter(0.05, function()
      if state.currentItem and itemKey(state.currentItem) == itemKey(item) then
        M.generateExampleForCurrent({ forceNew = false, revealBack = false, silent = true })
      end
    end)
  end
end

function M.startReview()
  state.reviewMode = true
  hs.settings.set(SETTINGS_KEYS.reviewMode, true)
  M.reviewNext()
  hs.alert.show("复习：开始（N 下一条，Esc 退出）", 2.0)
end

function M.stopReview()
  state.reviewMode = false
  hs.settings.set(SETTINGS_KEYS.reviewMode, false)
  if state.visible then
    M.hide()
  end
  hs.alert.show("复习：已退出", 1.6)
end

function M.toggleReview()
  if state.reviewMode then
    M.stopReview()
  else
    M.startReview()
  end
end

local function userConfigTable()
  local uc = hs.settings.get(SETTINGS_KEYS.userConfig)
  if type(uc) ~= "table" then
    uc = {}
  end
  return uc
end

local function setNestedValue(tbl, path, value)
  if type(tbl) ~= "table" or type(path) ~= "table" or #path == 0 then
    return
  end
  local cur = tbl
  for i = 1, #path - 1 do
    local k = path[i]
    if type(cur[k]) ~= "table" then
      cur[k] = {}
    end
    cur = cur[k]
  end
  cur[path[#path]] = value
end

local function persistConfigValue(path, value)
  local uc = userConfigTable()
  setNestedValue(uc, path, value)
  hs.settings.set(SETTINGS_KEYS.userConfig, uc)
  setNestedValue(config, path, value)
end

local function safeNumber(v)
  if type(v) == "number" then
    return v
  end
  if type(v) == "string" then
    return tonumber(v)
  end
  return nil
end

local function promptText(title, message, defaultValue)
  local ok, button, text = pcall(hs.dialog.textPrompt, title, message, defaultValue or "", "OK", "Cancel")
  if not ok then
    return nil
  end
  if button ~= "OK" then
    return nil
  end
  if type(text) ~= "string" then
    return nil
  end
  return text
end

local function promptNumber(title, message, defaultNumber)
  local defaultStr = ""
  if defaultNumber ~= nil then
    defaultStr = tostring(defaultNumber)
  end
  local text = promptText(title, message, defaultStr)
  if text == nil then
    return nil
  end
  local n = safeNumber(trim(text))
  if not n then
    hs.alert.show("请输入数字", 1.6)
    return nil
  end
  return n
end

local function maskSecret(v)
  if type(v) ~= "string" or v == "" then
    return "(未设置)"
  end
  return "(已设置)"
end

local function summarizePath(v)
  if type(v) ~= "string" then
    return ""
  end
  v = trim(v)
  if #v <= 48 then
    return v
  end
  return v:sub(1, 18) .. " … " .. v:sub(-24)
end

local function buildSettingsChoices()
  local llm = config.llm or {}
  local prefs = llm.preferences or {}
  local gen = llm.generate or {}

  local intervalMinutes = math.floor((tonumber(config.intervalSeconds) or 0) / 60 + 0.5)

  return {
    { id = "__group_llm", text = "—— LLM ——", subText = "配置后即可生成/补全" },
    { id = "llm_enabled", text = "LLM：启用/禁用", subText = llm.enabled and "已启用" or "未启用" },
    { id = "llm_protocol", text = "LLM：协议 (openai/simple)", subText = llm.protocol or "simple" },
    { id = "llm_mode", text = "LLM：模式 (generate/enrich)", subText = llm.mode or "generate" },
    { id = "llm_endpoint", text = "LLM：Endpoint", subText = summarizePath(llm.endpoint) },
    { id = "llm_model", text = "LLM：Model（openai 协议必填）", subText = llm.model or "" },
    { id = "llm_apiKey", text = "LLM：API Key", subText = maskSecret(llm.apiKey) .. " / env: " .. (llm.apiKeyEnv or "") },
    { id = "llm_timeout", text = "LLM：超时秒数", subText = tostring(llm.timeoutSeconds or 8) },
    { id = "llm_temperature", text = "LLM：temperature", subText = tostring(llm.temperature or 0.2) },
    { id = "llm_maxTokens", text = "LLM：maxTokens", subText = tostring(llm.maxTokens or "") },
    { id = "pref_language", text = "偏好：中文/英文解释", subText = prefs.language or "zh" },
    { id = "pref_style", text = "偏好：风格", subText = prefs.style or "concise" },
    { id = "pref_includeExample", text = "偏好：在 back 里包含例句", subText = (prefs.includeExample == false) and "否" or "是" },
    { id = "__group_timer", text = "—— 定时与弹窗 ——", subText = "" },
    { id = "intervalMinutes", text = "定时：间隔（分钟）", subText = tostring(intervalMinutes) },
    { id = "displaySeconds", text = "弹窗：停留（秒）", subText = tostring(config.displaySeconds or 8) },
    { id = "showBackByDefault", text = "弹窗：默认显示答案", subText = config.showBackByDefault and "是" or "否" },
    { id = "autoStart", text = "启动：自动开启定时弹出", subText = config.autoStart and "是" or "否" },
    { id = "newWordsBeforeReview", text = "复习：每 N 个新词插入 1 个旧词", subText = tostring(gen.newWordsBeforeReview or 3) },
    { id = "__group_misc", text = "—— 其它 ——", subText = "" },
    { id = "reloadConfig", text = "Reload Config", subText = "重载 Hammerspoon 配置" },
  }
end

local function handleSettingsChoice(id)
  if id:match("^__group_") then
    return true
  end
  if id == "llm_enabled" then
    persistConfigValue({ "llm", "enabled" }, not (config.llm and config.llm.enabled))
    return true
  end
  if id == "llm_protocol" then
    local cur = (config.llm and config.llm.protocol) or "simple"
    local next = (cur == "openai") and "simple" or "openai"
    persistConfigValue({ "llm", "protocol" }, next)
    return true
  end
  if id == "llm_mode" then
    local cur = (config.llm and config.llm.mode) or "generate"
    local next = (cur == "generate") and "enrich" or "generate"
    persistConfigValue({ "llm", "mode" }, next)
    return true
  end
  if id == "llm_endpoint" then
    local v = promptText("LLM Endpoint", "例如：http://127.0.0.1:1234/v1/chat/completions", (config.llm and config.llm.endpoint) or "")
    if v then
      persistConfigValue({ "llm", "endpoint" }, trim(v))
    end
    return true
  end
  if id == "llm_model" then
    local v = promptText("LLM Model", "openai 协议必填，例如：gpt-4o-mini / llama3", (config.llm and config.llm.model) or "")
    if v then
      persistConfigValue({ "llm", "model" }, trim(v))
    end
    return true
  end
  if id == "llm_apiKey" then
    local v = promptText("LLM API Key", "留空表示使用环境变量（例如 OPENAI_API_KEY）", (config.llm and config.llm.apiKey) or "")
    if v ~= nil then
      persistConfigValue({ "llm", "apiKey" }, trim(v))
    end
    return true
  end
  if id == "llm_timeout" then
    local n = promptNumber("LLM 超时（秒）", "建议 8~20", (config.llm and config.llm.timeoutSeconds) or 8)
    if n then
      persistConfigValue({ "llm", "timeoutSeconds" }, math.max(1, math.floor(n)))
    end
    return true
  end
  if id == "llm_temperature" then
    local n = promptNumber("LLM temperature", "建议 0.0~1.0", (config.llm and config.llm.temperature) or 0.2)
    if n then
      persistConfigValue({ "llm", "temperature" }, n)
    end
    return true
  end
  if id == "llm_maxTokens" then
    local n = promptNumber("LLM maxTokens", "建议 200~600（视模型而定）", (config.llm and config.llm.maxTokens) or 280)
    if n then
      persistConfigValue({ "llm", "maxTokens" }, math.floor(n))
    end
    return true
  end
  if id == "pref_language" then
    local cur = (config.llm and config.llm.preferences and config.llm.preferences.language) or "zh"
    local next = (cur == "zh") and "en" or "zh"
    persistConfigValue({ "llm", "preferences", "language" }, next)
    return true
  end
  if id == "pref_style" then
    local v = promptText("风格", "例如：concise / detailed", (config.llm and config.llm.preferences and config.llm.preferences.style) or "concise")
    if v then
      persistConfigValue({ "llm", "preferences", "style" }, trim(v))
    end
    return true
  end
  if id == "pref_includeExample" then
    local cur = (config.llm and config.llm.preferences and config.llm.preferences.includeExample)
    persistConfigValue({ "llm", "preferences", "includeExample" }, cur == false)
    return true
  end
  if id == "intervalMinutes" then
    local curMin = (tonumber(config.intervalSeconds) or 0) / 60
    local n = promptNumber("间隔（分钟）", "例如：20", math.floor(curMin + 0.5))
    if n then
      local seconds = math.max(10, math.floor(n * 60))
      persistConfigValue({ "intervalSeconds" }, seconds)
      if state.intervalTimer then
        M.stopTimer()
        if not state.dndEnabled and not state.reviewMode then
          M.startTimer()
        end
      end
    end
    return true
  end
  if id == "displaySeconds" then
    local n = promptNumber("停留（秒）", "例如：8", tonumber(config.displaySeconds) or 8)
    if n then
      persistConfigValue({ "displaySeconds" }, math.max(1, math.floor(n)))
    end
    return true
  end
  if id == "showBackByDefault" then
    persistConfigValue({ "showBackByDefault" }, not config.showBackByDefault)
    return true
  end
  if id == "autoStart" then
    persistConfigValue({ "autoStart" }, not config.autoStart)
    return true
  end
  if id == "newWordsBeforeReview" then
    local cur = (config.llm and config.llm.generate and config.llm.generate.newWordsBeforeReview) or 3
    local n = promptNumber("每 N 个新词插入 1 个旧词", "例如：3", cur)
    if n then
      persistConfigValue({ "llm", "generate", "newWordsBeforeReview" }, math.max(0, math.floor(n)))
    end
    return true
  end
  if id == "reloadConfig" then
    hs.reload()
    return false
  end
  return false
end

function M.openSettings()
  if not state.settingsController then
    local chooser = hs.chooser.new(function(choice)
      if not choice then
        return
      end
      local id = choice.id
      if type(id) ~= "string" or id == "" then
        return
      end
      local reopen = handleSettingsChoice(id)
      if reopen then
        hs.timer.doAfter(0.05, function()
          M.openSettings()
        end)
      end
    end)
    chooser:searchSubText(true)
    chooser:width(48)
    state.settingsController = chooser
  end

  state.settingsController:choices(buildSettingsChoices())
  state.settingsController:show()
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
  if not (config.hotkeys and config.hotkeys.enabled) then
    return
  end
  hs.hotkey.bind(config.hotkeys.showNow[1], config.hotkeys.showNow[2], function()
    M.showNext({ manual = true })
  end)
  hs.hotkey.bind(config.hotkeys.toggleTimer[1], config.hotkeys.toggleTimer[2], function()
    M.toggleTimer()
  end)
  hs.hotkey.bind(config.hotkeys.reloadData[1], config.hotkeys.reloadData[2], function()
    M.reload()
  end)
end

local function setupMenuBar()
  if state.menuBar then
    return
  end
  local mb = hs.menubar.new()
  if not mb then
    log("menubar creation failed")
    hs.alert.show("vocab_overlay：无法创建菜单栏按钮", 2.5)
    return
  end
  local title = (config.ui and config.ui.menuBarTitle)
  if type(title) ~= "string" then
    title = ""
  end

  -- Prefer a small icon so it survives a crowded/notched menubar.
  local icon = nil
  pcall(function()
    local image = require("hs.image")
    icon = image.imageFromName(image.systemImageNames.RevealFreestandingTemplate) or image.imageFromName("statusicon")
  end)
  if icon then
    pcall(function()
      mb:setIcon(icon, true)
    end)
  end

  mb:setTitle(title)
  mb:setTooltip("Vocab Overlay")
  mb:setMenu(function()
    local timerOn = state.intervalTimer ~= nil
    local stats = computeStats()
    local summary = ("已学 %d 词 / %d 句 · 复习 %d · 例句 %d"):format(
      stats.words,
      stats.sentences,
      stats.totalSeen,
      stats.examples
    )

    return {
      { title = summary, disabled = true },
      { title = ("新词连击: %d"):format(stats.newWordStreak or 0), disabled = true },
      { title = "-" },
      { title = "现在弹出", fn = function()
        M.showNext({ manual = true })
      end },
      { title = timerOn and "暂停定时弹出" or "开启定时弹出", fn = function()
        M.toggleTimer()
      end },
      { title = "勿扰模式", checked = state.dndEnabled and true or false, fn = function()
        M.toggleDnd()
      end },
      { title = "复习模式", checked = state.reviewMode and true or false, fn = function()
        M.toggleReview()
      end },
      { title = "查看统计", fn = function()
        M.showStats()
      end },
      { title = "-" },
      { title = "设置…", fn = function()
        if M.openSettings then
          M.openSettings()
        else
          hs.alert.show("设置界面未初始化", 1.6)
        end
      end },
      { title = "Reload Config", fn = function()
        hs.reload()
      end },
    }
  end)
  state.menuBar = mb

  local function highlightMenuBarOnce()
    local seconds = (config.ui and tonumber(config.ui.menuBarHighlightSeconds)) or 0
    if seconds <= 0 then
      return
    end
    hs.timer.doAfter(0.25, function()
      if not state.menuBar or not state.menuBar.frame then
        return
      end
      local frame = state.menuBar:frame()
      if not frame then
        hs.alert.show("VO：菜单栏按钮可能被隐藏（菜单栏太满 / Bartender/Hidden Bar）\n我已自动打开设置", 6.0)
        if M.openSettings then
          hs.timer.doAfter(0.1, function()
            M.openSettings()
          end)
        end
        return
      end

      local ok, drawing = pcall(require, "hs.drawing")
      if not ok or not drawing then
        return
      end
      local rect = drawing.rectangle(frame)
      rect:setStrokeColor({ red = 1, green = 0.2, blue = 0.2, alpha = 0.95 })
      rect:setFill(false)
      rect:setStrokeWidth(3)
      rect:setRoundedRectRadii(4, 4)
      rect:bringToFront(true)
      rect:show()
      hs.timer.doAfter(seconds, function()
        pcall(function()
          rect:delete()
        end)
      end)
    end)
  end

  if not hs.settings.get("vocabOverlay._firstRunShown") then
    hs.settings.set("vocabOverlay._firstRunShown", true)
    hs.alert.show("VO 已启动：点菜单栏右上角小图标 → 设置… / 现在弹出", 6.0)
    highlightMenuBarOnce()
  else
    -- If user still can't find the icon, highlight it after reload as well.
    if not hs.settings.get("vocabOverlay._highlightedOnce") then
      hs.settings.set("vocabOverlay._highlightedOnce", true)
      highlightMenuBarOnce()
    end
  end
end

local function setupModal()
  state.modal = hs.hotkey.modal.new(nil, nil)
  state.modal:bind({}, "escape", function()
    if state.reviewMode and M.stopReview then
      M.stopReview()
      return
    end
    M.hide()
  end)
  state.modal:bind({}, "space", function()
    M.toggleBack()
  end)
  state.modal:bind({}, "n", function()
    if state.reviewMode and M.reviewNext then
      M.reviewNext()
      return
    end
    M.showNext({ manual = true })
  end)
  state.modal:bind({}, "e", function()
    if M.generateExampleForCurrent then
      M.generateExampleForCurrent({ manual = true })
    end
  end)
  state.modal:bind({}, "d", function()
    if M.toggleDnd then
      M.toggleDnd()
    end
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
  setupMenuBar()
  watchScreens()

  if config.autoStart and not state.dndEnabled and not state.reviewMode then
    M.startTimer()
  end
  log("ready")
end

return M
