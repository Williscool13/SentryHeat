-- SentryHeat 1.1.0 - heat, Machine War bonus and kills for Payday 3 sentries.
--
--   Style = world: data floats over each of your sentries.
--     Far  (> NearDistance): [icon] heat%  +bonus%
--     Near (<= NearDistance): [icon] HEAT / DMG / KILLS, grows as you get closer
--   Style = panel: each of your sentries gets a number tag (1, 2, 3...) and the
--     data is listed in a small HUD panel.
--   ShowMine / ShowTeammates pick what is shown (teammates: heat only by default).
--   An off-screen sentry of yours that is hot gets a red arrow at the screen edge.
--
--   Keys (settings.ini, none by default): markers on/off, switch style.
--   Settings: settings.ini in this mod's folder. Restart the game after editing
--   it by hand; changes made in ModMenu (the in-game settings menu) apply live.

---------------------------------------------------------------------------
-- Config (defaults; settings.ini overrides)
---------------------------------------------------------------------------
local function clampNum(x, a, b, default)
    if type(x) ~= "number" then return default end
    if x < a then return a elseif x > b then return b end
    return x
end
local NEAR_DIST     = 15      -- metres: switch between far line and near panel
local SCALE_CLOSE   = 1.2     -- near-panel scale at <= 3 m
local SCALE_FAR     = 0.85    -- near-panel scale at NEAR_DIST
local MARKER_CM     = 25      -- marker bottom edge, cm above the sentry origin
local MAX_MULT      = 1.5     -- Machine War cap (+50%)
local ICON_PATH     = "/Game/UI/Textures/InventoryIcons/SS_UI_Deployables_SentryTurret.SS_UI_Deployables_SentryTurret"
local TICK_EVERY    = 0.25    -- seconds between bookkeeping ticks (no object searches)
local STAT_EVERY    = 0.1     -- seconds between heat / bonus reads per sentry (10x a second)
local SENTRY_BP     = "/Game/Gameplay/SentryGun/BP_SentryGun.BP_SentryGun_C"
-- HUD widgets for your own / teammates' deployables. Their Blueprint events tell
-- us when a sentry may have been placed, so we search only then.
local HUD_HOOKS = {
    { cls = "/Game/UI/Widgets/HUD/WBP_UI_WidgetPlaceableStatus.WBP_UI_WidgetPlaceableStatus_C",
      fns = { "OnAmmoInventoryChanged", "OnIconChanged" }, label = "own", delay = 1.0 },
    { cls = "/Game/DLCs/00006-NEXTRELEASE/UI/HUD/PartyMember/WBP_PartyMember_PlaceableStatus.WBP_PartyMember_PlaceableStatus_C",
      fns = { "OnAmmoInventoryChanged", "OnPickUpAnimation", "OnIconChanged" }, label = "team", delay = 2.5 },
}
local PERF_LOG      = false   -- (undocumented) log the mod's time per frame every 10 s
local SHOW_MINE     = { heat = true, dmg = true, kills = true }    -- what your sentries show
local SHOW_TEAMF    = { heat = true, dmg = false, kills = false }  -- what teammates' sentries show
local TEAM_OPACITY  = 0.75    -- teammate markers are slightly faded
local HIDE_WHEN_PAUSED = true -- hide while paused or in cursor menus (camera views still show)
local ROW_PULL      = -5      -- px: tightens spacing between near-panel lines
local YELLOW_AT     = 0.60    -- heat fraction: green -> yellow
local RED_AT        = 0.80    -- heat fraction: yellow -> red (the game's smoke starts at 80%)
local PULSE_AT      = 0.90    -- heat fraction: number starts pulsing
local EDGE_WARN     = true    -- off-screen hot sentry -> red arrow at the screen edge
local EDGE_WARN_AT  = nil     -- heat fraction for the edge arrow (nil = same as RED_AT)
local EDGE_MARGIN   = 48      -- px from the screen edge
local TOGGLE_KEY    = "NONE"   -- no keys unless the player sets them
local STYLE_KEY     = "NONE"
local STYLE         = "world" -- "world" (data over each sentry) or "panel" (number tag + HUD panel)
local PANEL_X       = 0.985   -- panel right edge, fraction of screen width
local PANEL_Y       = 0.58    -- panel vertical centre, fraction of screen height
local FAR_ICON_PX   = 14      -- far-view sentry icon size (matches the 12pt text height)

local COL_GREEN  = { R = 0.35, G = 1.0,  B = 0.35, A = 1 }
local COL_YELLOW = { R = 1.0,  G = 0.85, B = 0.2,  A = 1 }
local COL_RED    = { R = 1.0,  G = 0.25, B = 0.2,  A = 1 }
local COL_WHITE  = { R = 1.0,  G = 1.0,  B = 1.0,  A = 1 }
local COL_CAPPED = { R = 0.35, G = 0.65, B = 1.0,  A = 1 }   -- blue: Machine War bonus at cap
local COL_GREY   = { R = 0.78, G = 0.78, B = 0.78, A = 1 }
local COL_LABEL  = { R = 0.65, G = 0.65, B = 0.65, A = 1 }

---------------------------------------------------------------------------
-- settings.ini (in the mod folder, next to Scripts\). Missing file/keys = defaults.
---------------------------------------------------------------------------
local SETTINGS_LOG = {}
local function hexColor(v)
    local h = tostring(v):gsub("^#", "")
    if not h:match("^%x%x%x%x%x%x$") then return nil end
    return { R = tonumber(h:sub(1, 2), 16) / 255, G = tonumber(h:sub(3, 4), 16) / 255,
             B = tonumber(h:sub(5, 6), 16) / 255, A = 1 }
end
local function toBool(v) v = tostring(v):lower(); return v == "true" or v == "1" or v == "yes" or v == "on" end
-- "heat, dmg, kills" -> field set (nil = invalid). "off"/"none" = nothing.
local function parseFields(v)
    local t = { heat = false, dmg = false, kills = false }
    local any = false
    for w in tostring(v):lower():gmatch("[%a]+") do
        if w == "heat" or w == "true" or w == "on" or w == "yes" then t.heat = true
        elseif w == "dmg" or w == "damage" or w == "bonus" then t.dmg = true
        elseif w == "kills" or w == "kill" then t.kills = true
        elseif w == "off" or w == "none" or w == "false" or w == "no" then -- nothing
        else return nil end
        any = true
    end
    if not any then return nil end
    return t
end
local function pct(v, cur) return clampNum(tonumber(v), 0, 100, (cur or 0) * 100) / 100 end
local function loadSettings()
    local src = (debug and debug.getinfo and debug.getinfo(1, "S").source) or ""
    local dir = src:gsub("^@", ""):gsub("[/\\]Scripts[/\\][^/\\]*$", "")
    local path = dir .. "\\settings.ini"
    local f = io and io.open(path, "r")
    if not f then SETTINGS_LOG[#SETTINGS_LOG + 1] = "no settings.ini found, using defaults" return end
    for rawLine in f:lines() do
        local line = rawLine:gsub(";.*$", "")
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and v ~= "" then
            local key = k:lower()
            local ok = true
            if key == "showteammates" or key == "showmine" then
                local t = parseFields(v)
                if not t then ok = false
                elseif key == "showmine" then SHOW_MINE = t
                else SHOW_TEAMF = t end
            elseif key == "teammateopacity" then TEAM_OPACITY = clampNum(tonumber(v), 0.1, 1, TEAM_OPACITY)
            elseif key == "neardistance" then NEAR_DIST = clampNum(tonumber(v), 0, 200, NEAR_DIST)
            elseif key == "markerheight" then MARKER_CM = clampNum(tonumber(v), -200, 500, MARKER_CM)
            elseif key == "hideinmenus" then HIDE_WHEN_PAUSED = toBool(v)
            elseif key == "yellowat" then YELLOW_AT = pct(v, YELLOW_AT)
            elseif key == "redat" then RED_AT = pct(v, RED_AT)
            elseif key == "edgewarning" then EDGE_WARN = toBool(v)
            elseif key == "edgewarningat" then EDGE_WARN_AT = pct(v, EDGE_WARN_AT or RED_AT)
            elseif key == "togglekey" then TOGGLE_KEY = v:upper()
            elseif key == "stylekey" then STYLE_KEY = v:upper()
            elseif key == "perflog" then PERF_LOG = toBool(v)
            elseif key == "style" then
                local st = v:lower()
                if st == "world" or st == "full" then STYLE = "world"
                elseif st == "panel" or st == "minimal" then STYLE = "panel"
                else ok = false end
            elseif key == "panelx" then PANEL_X = clampNum(tonumber(v), 0, 1, PANEL_X)
            elseif key == "panely" then PANEL_Y = clampNum(tonumber(v), 0, 1, PANEL_Y)
            elseif key == "cappedcolor" then COL_CAPPED = hexColor(v) or COL_CAPPED
            elseif key == "heatcolorlow" then COL_GREEN = hexColor(v) or COL_GREEN
            elseif key == "heatcolormid" then COL_YELLOW = hexColor(v) or COL_YELLOW
            elseif key == "heatcolorhigh" then COL_RED = hexColor(v) or COL_RED
            else ok = false end
            if not ok then SETTINGS_LOG[#SETTINGS_LOG + 1] = "settings.ini: unknown setting or value: " .. k end
        end
    end
    f:close()
end
do
    local ok, err = pcall(loadSettings)
    if not ok then SETTINGS_LOG[#SETTINGS_LOG + 1] = "settings.ini error: " .. tostring(err) end
    if YELLOW_AT > RED_AT then YELLOW_AT = RED_AT end
    if EDGE_WARN_AT == nil then EDGE_WARN_AT = RED_AT end
end
local function anyField(f) return f.heat or f.dmg or f.kills end
local SHOW_TEAM = anyField(SHOW_TEAMF)
-- Field sets as used per frame (near = may use the near panel).
local FIELDS_MINE = { heat = SHOW_MINE.heat, dmg = SHOW_MINE.dmg, kills = SHOW_MINE.kills, near = true }
local FIELDS_TEAM = { heat = SHOW_TEAMF.heat, dmg = SHOW_TEAMF.dmg, kills = SHOW_TEAMF.kills,
                      near = (SHOW_TEAMF.dmg or SHOW_TEAMF.kills) or false }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local TAG = "[SentryHeat] "
local function log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end
local loggedOnce = {}
local function logOnce(key, fmt, ...)
    if loggedOnce[key] then return end
    loggedOnce[key] = true
    log(fmt, ...)
end

local function safe(fn, default)
    local ok, v = pcall(fn)
    if ok then return v end
    return default
end
-- Hot-path helpers: pcall on fixed functions instead of a new closure per
-- call, so the per-frame path makes (almost) no Lua garbage.
local function _isValid(o) return o:IsValid() end
local function _addr(o) return o:GetAddress() end
local function _get(o, k) return o[k] end
local function _call(o, m, ...) return o[m](o, ...) end
local function _attr(set, name) return set[name].CurrentValue end
local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(_isValid, o)
    return ok and v == true
end
local function addr(o)
    local ok, v = pcall(_addr, o)
    if ok then return v end
    return 0
end
local function getp(o, k, default)          -- o[k], or default on error / nil
    local ok, v = pcall(_get, o, k)
    if ok and v ~= nil then return v end
    return default
end
local function callm(o, m, ...)             -- o:m(...), or nil on error
    local ok, v = pcall(_call, o, m, ...)
    if ok then return v end
    return nil
end
local function attr(set, name)
    local ok, v = pcall(_attr, set, name)
    if ok then return v end
    return nil
end
local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end
local function pctStr(h) return string.format("%d%%", math.floor(h * 100 + 0.5)) end
local function clearTable(t) for k in pairs(t) do t[k] = nil end end

-- StaticFindObject costs 6-25 ms in this UE4SS build when the object is NOT
-- loaded (measured in game; ~0 when it is). So a found object is kept, and an
-- unloaded one is only looked up when the caller's schedule allows it.
local foundObj = {}
local function findLoaded(path, allowLookup)
    local o = foundObj[path]
    if o ~= nil and valid(o) then return o end
    foundObj[path] = nil
    if not allowLookup then return nil end
    local ok, r = pcall(StaticFindObject, path)
    if ok and valid(r) then foundObj[path] = r; return r end
    return nil
end

-- Our own local PlayerController (not UEHelpers: it caches across level changes
-- and on a host can return another player's controller).
local pcCache = nil
local lastPCScan = -1
local deadPC = {}        -- addr -> true for controllers from a previous level
local function localPC()
    if pcCache and valid(pcCache) then return pcCache end
    pcCache = nil
    local now = os.clock()
    if now - lastPCScan < 1.0 then return nil end   -- don't rescan every frame (menus/loading)
    lastPCScan = now
    for _, c in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(c) and not deadPC[addr(c)] and callm(c, "IsLocalController") then
            pcCache = c
            break
        end
    end
    return pcCache
end

local function cameraLoc(pc)
    local cam = getp(pc, "PlayerCameraManager")
    if valid(cam) then
        local l = callm(cam, "GetCameraLocation")
        if l then return l end
    end
    local pawn = getp(pc, "Pawn")
    if valid(pawn) then return callm(pawn, "K2_GetActorLocation") end
    return nil
end

local function distM(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz) / 100
end

---------------------------------------------------------------------------
-- Widget construction (runtime UMG, no editor assets)
---------------------------------------------------------------------------
local classCache = {}
local function cls(path)
    local c = classCache[path]
    if not valid(c) then
        c = StaticFindObject(path)
        classCache[path] = c
    end
    return c
end

local nameN = 0
local function newObj(classPath, outer, base)
    nameN = nameN + 1
    return StaticConstructObject(cls(classPath), outer, FName(base .. "_" .. nameN))
end

local ui = { root = nil, tree = nil, canvas = nil, icon = nil }

local iconTryAt = -100
local function iconTexture()
    if valid(ui.icon) then return ui.icon end
    -- A missing icon is retried at most every 10 s (a failed lookup is slow).
    local now = os.clock()
    if now - iconTryAt < 10 then return nil end
    iconTryAt = now
    local o = safe(function() return StaticFindObject(ICON_PATH) end)
    if not valid(o) then o = safe(function() return LoadAsset(ICON_PATH) end) end
    if valid(o) then ui.icon = o else logOnce("icon", "sentry icon not found: %s", ICON_PATH) end
    return ui.icon
end

local function makeText(size, color)
    local t = newObj("/Script/UMG.TextBlock", ui.tree, "SH_Text")
    pcall(function() t.Font.Size = size end)
    pcall(function() t.Font.OutlineSettings.OutlineSize = 1 end)
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
    return t
end

local function setText(t, cache, key, s)
    if cache[key] == s then return end
    cache[key] = s
    cache.szDirty = 3          -- re-measure for a few frames (layout catches up)
    callm(t, "SetText", FText(s))
end

local function setColor(t, cache, key, c)
    if cache[key] == c then return end
    cache[key] = c
    callm(t, "SetColorAndOpacity", { SpecifiedColor = c, ColorUseRule = 0 })
end

local function setOpacity(w, cache, key, v)
    if cache[key] == v then return end
    cache[key] = v
    callm(w, "SetRenderOpacity", v)
end

local function makeIcon(px)
    local img = newObj("/Script/UMG.Image", ui.tree, "SH_Icon")
    local tex = iconTexture()
    if tex then pcall(function() img:SetBrushResourceObject(tex) end) end
    local ok = pcall(function() img:SetDesiredSizeOverride({ X = px, Y = px }) end)
    if not ok then pcall(function() img:SetBrushSize({ X = px, Y = px }) end) end
    return img
end

local function hAdd(box, child, padL, vCenter)
    local slot = box:AddChildToHorizontalBox(child)
    pcall(function() slot:SetPadding({ Left = padL or 0, Top = 0, Right = 0, Bottom = 0 }) end)
    if vCenter ~= false then pcall(function() slot:SetVerticalAlignment(2) end) end
    return slot
end

local function vAdd(box, child, padTop)
    local slot = box:AddChildToVerticalBox(child)
    if padTop and padTop ~= 0 then
        pcall(function() slot:SetPadding({ Left = 0, Top = padTop, Right = 0, Bottom = 0 }) end)
    end
    return slot
end

local function canvasAdd(child)
    local slot = ui.canvas:AddChildToCanvas(child)
    pcall(function() slot:SetAutoSize(true) end)
    pcall(function() slot:SetAlignment({ X = 0.5, Y = 1.0 }) end)
    return slot
end

local VIS_COLLAPSED, VIS_HITTEST_INVIS = 1, 3

local function ensureRoot()
    if valid(ui.root) and valid(ui.canvas) then
        if callm(ui.root, "IsInViewport") == false then callm(ui.root, "AddToViewport", 50) end
        return true
    end
    -- Creation failed recently: don't retry every frame.
    local now = os.clock()
    if ui.failAt and now - ui.failAt < 2 then return false end
    -- Remove leftover overlays from a previous level before making a new one
    -- (searches every widget: once per level only).
    if not ui.swept then
        ui.swept = true
        for _, old in ipairs(FindAllOf("UserWidget") or {}) do
            if valid(old) and old ~= ui.root then
                local n = safe(function() return old:GetFName():ToString() end, "")
                if n:find("^SentryHeatRoot") then pcall(function() old:RemoveFromParent() end) end
            end
        end
    end
    local ok, err = pcall(function()
        local world = localPC():GetWorld()
        local w = newObj("/Script/UMG.UserWidget", world, "SentryHeatRoot")
        local tree = newObj("/Script/UMG.WidgetTree", w, "SentryHeatTree")
        w.WidgetTree = tree
        local canvas = newObj("/Script/UMG.CanvasPanel", tree, "SentryHeatCanvas")
        tree.RootWidget = canvas
        ui.root, ui.tree, ui.canvas = w, tree, canvas
        ui.rootVis = VIS_HITTEST_INVIS
        ui.resetMarkers = true
        ui.panel = nil
        w:SetVisibility(VIS_HITTEST_INVIS)
        w:AddToViewport(50)
    end)
    if not ok then
        logOnce("root:" .. tostring(err), "UI creation failed: %s", tostring(err))
        ui.root, ui.tree, ui.canvas = nil, nil, nil
        ui.failAt = now
        return false
    end
    ui.failAt = nil
    return true
end

-- One marker = a far line, a near panel and an edge arrow, each its own canvas child.
local function createMarker(fields)
    local m = { cache = {} }

    local full = (STYLE ~= "panel")

    -- Far: world = [icon] heat  bonus ; panel = number tag
    local far = newObj("/Script/UMG.HorizontalBox", ui.tree, "SH_Far")
    m.farHeat  = makeText(12, COL_GREEN)
    m.farBonus = makeText(12, COL_WHITE)
    if full then
        m.farIcon = makeIcon(FAR_ICON_PX)
        hAdd(far, m.farIcon, 0)
        hAdd(far, m.farHeat, 4)
    else
        hAdd(far, m.farHeat, 0)
    end
    hAdd(far, m.farBonus, 7)

    -- Near: [icon] | HEAT 72% / DMG +35% / KILLS 8
    local near = newObj("/Script/UMG.HorizontalBox", ui.tree, "SH_Near")
    local col = newObj("/Script/UMG.VerticalBox", ui.tree, "SH_NearCol")
    local function row(label, valueText, base)
        local r = newObj("/Script/UMG.HorizontalBox", ui.tree, base)
        if full then
            local l = makeText(11, COL_LABEL); setText(l, m.cache, base, label)
            hAdd(r, l, 0)
            hAdd(r, valueText, 6)
        else
            hAdd(r, valueText, 0)
        end
        return r
    end
    m.nearHeat = makeText(13, COL_GREEN)
    m.nearBonus = makeText(13, COL_WHITE)
    m.nearKills = makeText(13, COL_GREY)
    local r1 = row("HEAT", m.nearHeat, "SH_R1")
    local r2 = row("DMG", m.nearBonus, "SH_R2")
    local r3 = row("KILLS", m.nearKills, "SH_R3")

    -- Only the selected rows; the first one shown gets no pull-up padding.
    local first = true
    for _, e in ipairs({ { r1, fields.heat }, { r2, fields.dmg }, { r3, fields.kills } }) do
        if e[2] then vAdd(col, e[1], first and 0 or ROW_PULL); first = false end
    end
    if full then
        m.nearIcon = makeIcon(34)
        hAdd(near, m.nearIcon, 0)
        hAdd(near, col, 6)
    else
        hAdd(near, col, 0)
    end

    -- Edge warning: [num][arrow][num]; only the inner-side number is filled.
    local edge = newObj("/Script/UMG.HorizontalBox", ui.tree, "SH_Edge")
    m.edgeL = makeText(14, COL_RED)
    m.edgeArrow = makeText(24, COL_RED)
    setText(m.edgeArrow, m.cache, "ea", ">")
    m.edgeR = makeText(14, COL_RED)
    hAdd(edge, m.edgeL, 0)
    hAdd(edge, m.edgeArrow, 3)
    hAdd(edge, m.edgeR, 3)

    m.far, m.near, m.edge = far, near, edge
    m.farSlot = canvasAdd(far)
    m.nearSlot = canvasAdd(near)
    m.edgeSlot = canvasAdd(edge)
    pcall(function() m.edgeSlot:SetAlignment({ X = 0.5, Y = 0.5 }) end)
    pcall(function() far:SetVisibility(VIS_COLLAPSED) end)
    pcall(function() near:SetVisibility(VIS_COLLAPSED) end)
    pcall(function() edge:SetVisibility(VIS_COLLAPSED) end)
    m.mode = "hidden"
    return m
end

-- HUD panel (Style = panel): "#  HEAT  DMG  KILLS" table for your sentries.
local PANEL_COLS = { 22, 52, 66, 44 }
local function sizeCell(textW, width)
    local sb = newObj("/Script/UMG.SizeBox", ui.tree, "SH_PCell")
    pcall(function() sb:SetWidthOverride(width) end)
    pcall(function() sb:AddChild(textW) end)
    return sb
end
local function makePanelRow(isHeader)
    local r = { cache = {} }
    r.box = newObj("/Script/UMG.HorizontalBox", ui.tree, "SH_PRow")
    r.cells = {}
    local labels = { "#", "HEAT", "DMG", "KILLS" }
    local want = { true, SHOW_MINE.heat, SHOW_MINE.dmg, SHOW_MINE.kills }
    for i = 1, 4 do
        local t = makeText(isHeader and 11 or 13, isHeader and COL_LABEL or COL_WHITE)
        if isHeader then setText(t, r.cache, "h" .. i, labels[i]) end
        r.cells[i] = t
        if want[i] then hAdd(r.box, sizeCell(t, PANEL_COLS[i]), 0) end
    end
    return r
end
local function ensurePanel()
    if ui.panel then return ui.panel end
    local p = { rows = {}, cache = {} }
    p.border = newObj("/Script/UMG.Border", ui.tree, "SH_PanelBg")
    pcall(function() p.border:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.35 }) end)
    pcall(function() p.border:SetPadding({ Left = 8, Top = 4, Right = 8, Bottom = 6 }) end)
    p.vbox = newObj("/Script/UMG.VerticalBox", ui.tree, "SH_PanelV")
    pcall(function() p.border:AddChild(p.vbox) end)
    local hdr = makePanelRow(true)
    vAdd(p.vbox, hdr.box, 0)
    for i = 1, 4 do
        local r = makePanelRow(false)
        vAdd(p.vbox, r.box, ROW_PULL)
        pcall(function() r.box:SetVisibility(VIS_COLLAPSED) end)
        r.vis = false
        p.rows[i] = r
    end
    p.slot = canvasAdd(p.border)
    pcall(function() p.slot:SetAlignment({ X = 1, Y = 0.5 }) end)
    pcall(function() p.border:SetVisibility(VIS_COLLAPSED) end)
    p.vis = false
    ui.panel = p
    return p
end

local function destroyMarker(m)
    pcall(function() m.far:RemoveFromParent() end)
    pcall(function() m.near:RemoveFromParent() end)
    pcall(function() m.edge:RemoveFromParent() end)
end

local function setMode(m, mode)
    if m.mode == mode then return end
    m.mode = mode
    m.cache.szDirty = 3        -- newly shown widget: measure again once laid out
    callm(m.far, "SetVisibility", mode == "far" and VIS_HITTEST_INVIS or VIS_COLLAPSED)
    callm(m.near, "SetVisibility", mode == "near" and VIS_HITTEST_INVIS or VIS_COLLAPSED)
    callm(m.edge, "SetVisibility", mode == "edge" and VIS_HITTEST_INVIS or VIS_COLLAPSED)
end

---------------------------------------------------------------------------
-- Sentry tracking
---------------------------------------------------------------------------
-- Discovery is event-based. FindAllOf walks every object in the game (a
-- visible hitch), so it only runs when something says a sentry may exist:
--   * the sentry class is loaded on this level (one search)
--   * a HUD deployable widget event (searches ~1 s and ~3 s later: a thrown
--     sentry isn't a BP_SentryGun yet, and teammates' replicate later)
--   * a sentry shoots (the heat hook hands it over directly, no search)
-- Maps where nobody brought a sentry cost nothing after the first seconds.
local sentries = {}      -- addr -> { obj, mine, show, id, firstHp, kills, marker, born }
local watched = {}       -- enemy addr -> { obj, sentry = sentryAddr, t }
local pending = {}       -- addr -> sentry object handed over by the heat hook
local isHost = false

local GPS = nil
local function getGPS()
    if not valid(GPS) then GPS = StaticFindObject("/Script/Engine.Default__GameplayStatics") end
    return GPS
end

local disc = {
    checks = {},          -- times at which an unloaded sentry class may be looked up
    cls = nil,            -- sentry class, once loaded on this level
    due = {},             -- times of requested searches
    lastSearch = nil,     -- nil = not searched on this level yet
    hudSeen = false,      -- a HUD widget event fired on this level
    players = -1, playersAt = 0,
    hookTryAt = -100, hudTries = 0, hudTryAt = -100, hudCheckAt = -100,
    n = 0, ms = 0, worst = 0,   -- search stats for PerfLog
}
local hookedAddr = {}     -- class path -> class address our hooks are registered on

local function scheduleSearch(delay)
    local t = os.clock() + delay
    for _, d in ipairs(disc.due) do if math.abs(d - t) < 0.75 then return end end
    if #disc.due < 8 then disc.due[#disc.due + 1] = t end
end
local function addChecks(list)
    local now = os.clock()
    for _, d in ipairs(list) do disc.checks[#disc.checks + 1] = now + d end
end

local function isMine(s, myPS)
    local owner = getp(s, "OwnerPlayerState")
    return myPS ~= nil and valid(owner) and addr(owner) == addr(myPS)
end
local function wanted(mineS)
    if mineS then return anyField(SHOW_MINE) or EDGE_WARN end
    return SHOW_TEAM
end

-- Picked-up sentries linger for a while before they're destroyed. Filter them.
local function isGhost(s)
    if getp(s, "bHidden", false) == true then return true end
    if isHost and callm(s, "HasAuthority") == false then return true end
    return false
end

local function nextId()   -- number tag: smallest free id among your sentries
    local used = {}
    for _, o in pairs(sentries) do if o.mine and o.id then used[o.id] = true end end
    local id = 1
    while used[id] do id = id + 1 end
    return id
end

local function addSentry(s, myPS, now)
    if not valid(s) then return end
    local a = addr(s)
    if a == 0 or sentries[a] or isGhost(s) then return end
    local mineS = isMine(s, myPS)
    local set = getp(s, "AttributeSet")
    sentries[a] = { obj = s, mine = mineS, show = wanted(mineS), kills = 0, born = now,
        firstHp = valid(set) and attr(set, "Health") or 500, id = mineS and nextId() or nil,
        loc = callm(s, "K2_GetActorLocation") }
end

-- Hook: each sentry shot -> remember its target for kill credit; an unknown
-- sentry is handed to the next tick. (Blueprint-function hooks only: native
-- and engine hooks are unsafe in this UE4SS build.)
local function onShot(ctx)
    local s = ctx:get()
    local sa = addr(s)
    if not sentries[sa] then
        if sa ~= 0 then pending[sa] = s end
        return
    end
    local t = getp(s, "CurrentTarget")
    if valid(t) then watched[addr(t)] = { obj = t, sentry = sa, t = os.clock() } end
end
-- HUD deployable events. The first one on a level (the HUD being built at
-- heist start) is when we check whether the sentry class is loaded. After
-- that, only a falling deployable count (something was placed) starts a
-- search; pickups need none (removal is checked every tick).
local hudAmmo = {}       -- widget addr -> last deployable count seen
local function _pget(x) return x:get() end
local function onHud(label, fn, delay)
    local isAmmo = (fn == "OnAmmoInventoryChanged")
    return function(ctx, p1)
        local now = os.clock()
        if not disc.hudSeen then
            disc.hudSeen = true
            if not disc.cls then clearTable(disc.checks); addChecks({ 1 }) end
        end
        if not isAmmo then
            if PERF_LOG then log("HUD event %s:%s", label, fn) end
            return
        end
        local ok1, w = pcall(_pget, ctx)
        local wa = ok1 and addr(w) or 0
        local ok2, v = pcall(_pget, p1)
        v = ok2 and tonumber(v) or nil
        local last = hudAmmo[wa]
        hudAmmo[wa] = v
        -- Unreadable count: assume something was placed.
        local placed = (v == nil) or (last ~= nil and v < last)
        if placed then scheduleSearch(delay) end
        if PERF_LOG then
            log("HUD event %s:%s count %s -> %s%s", label, fn, tostring(last), tostring(v), placed and " (placed: search)" or "")
        end
    end
end

-- Hooks are registered once per class object, so they don't pile up across
-- levels; a reloaded class (new address) gets them again.
local function hookSentryClass(c, now)
    local ca = addr(c)
    if hookedAddr[SENTRY_BP] == ca or now - disc.hookTryAt < 5 then return end
    disc.hookTryAt = now
    local ok, err = pcall(RegisterHook, SENTRY_BP .. ":OnOverheatDamageTaken", onShot)
    if ok then hookedAddr[SENTRY_BP] = ca
    else logOnce("hook:" .. tostring(err), "heat hook not ready: %s", tostring(err)) end
end
local function tryHudHooks(now)
    -- A missing widget class is a slow lookup: a few tries per level, 3 s apart.
    if disc.hudTries >= 5 or now - disc.hudTryAt < 3 then return end
    disc.hudTryAt = now
    local missing = false
    for _, h in ipairs(HUD_HOOKS) do
        local c = findLoaded(h.cls, true)
        if c then
            local ca = addr(c)
            if hookedAddr[h.cls] ~= ca then
                local n = 0
                for _, fn in ipairs(h.fns) do
                    if pcall(RegisterHook, h.cls .. ":" .. fn, onHud(h.label, fn, h.delay)) then n = n + 1 end
                end
                if n > 0 then hookedAddr[h.cls] = ca end
                if PERF_LOG then log("HUD hooks %s: %d of %d registered", h.label, n, #h.fns) end
            end
        else
            missing = true
        end
    end
    disc.hudTries = missing and disc.hudTries + 1 or 99
end

local function checkClass(now)
    if disc.cls and valid(disc.cls) then return disc.cls end
    disc.cls = nil
    local allow = false
    for i = #disc.checks, 1, -1 do
        if now >= disc.checks[i] then table.remove(disc.checks, i); allow = true end
    end
    if not allow then return nil end
    disc.cls = findLoaded(SENTRY_BP, true)
    if disc.cls and PERF_LOG then log("sentry class loaded") end
    return disc.cls
end

local function playerCount(pc)
    local gs = callm(getGPS(), "GetGameState", pc)
    local arr = valid(gs) and getp(gs, "PlayerArray") or nil
    return arr and callm(arr, "GetArrayNum") or nil
end

local function search(now, why, myPS)
    local t0 = os.clock()
    local list = FindAllOf("BP_SentryGun_C") or {}
    local ms = (os.clock() - t0) * 1000
    disc.lastSearch = now
    disc.n, disc.ms = disc.n + 1, disc.ms + ms
    if ms > disc.worst then disc.worst = ms end
    for _, s in ipairs(list) do addSentry(s, myPS, now) end
    if PERF_LOG then log("search (%s): %d sentries, %.1f ms", why, #list, ms) end
end

-- Heat = 1 - Health/HealthMax (the sentry's heat is self-damage on its health).
-- HealthMax isn't replicated to clients, so fall back to the health seen at deploy.
local function heatOf(st)
    local set = getp(st.obj, "AttributeSet")
    if not valid(set) then return nil end
    local hp = attr(set, "Health")
    local max = st.max
    if not max then
        max = attr(set, "HealthMax")
        if max and max > 0 then st.max = max else max = st.firstHp or 500 end
    end
    local mult = attr(set, "OutgoingDamageMultiplier") or 1
    if not hp then return nil end
    return clamp(1 - hp / max, 0, 1), hp, mult
end
-- Heat / bonus as shown: read 10x a second, not every frame.
local function stats(st, now)
    if not st.statAt or now - st.statAt >= STAT_EVERY then
        st.statAt = now
        st.heat, st.hp, st.mult = heatOf(st)
    end
    return st.heat, st.hp, st.mult
end

-- Bookkeeping, 4x a second. No object searches unless one is due.
local function tick(now)
    local pc = localPC()
    if not pc then return end
    isHost = callm(pc, "HasAuthority") == true
    local myPS = getp(pc, "PlayerState")
    if not valid(myPS) then myPS = nil end

    -- A teammate joining later may bring the sentry class with them.
    if not disc.cls and now - disc.playersAt >= 1 then
        disc.playersAt = now
        local n = playerCount(pc)
        if n then
            if disc.players >= 0 and n > disc.players then addChecks({ 5, 20 }) end
            disc.players = n
        end
    end

    tryHudHooks(now)        -- widget classes exist in any heist; capped tries per level
    local c = checkClass(now)
    if c then
        hookSentryClass(c, now)
        for a, s in pairs(pending) do pending[a] = nil; addSentry(s, myPS, now) end
        local why = nil
        for i = #disc.due, 1, -1 do
            if now >= disc.due[i] then table.remove(disc.due, i); why = "HUD event" end
        end
        if not why then
            if disc.lastSearch == nil then
                -- First search on this level: only if the heist has been running
                -- a while (joined in progress); at a fresh start nothing is placed.
                disc.lastSearch = now
                local gs = callm(getGPS(), "GetGameState", pc)
                local t = valid(gs) and callm(gs, "GetServerWorldTimeSeconds") or nil
                if t == nil or t > 45 then why = "joined in progress" end
                if PERF_LOG then log("sentry class ready, server time %s", tostring(t)) end
            end
        end
        if why then search(now, why, myPS) end
    else
        -- No sentry class: nothing can have been placed; drop due searches.
        clearTable(pending)
        for i = #disc.due, 1, -1 do if now >= disc.due[i] then table.remove(disc.due, i) end end
    end

    for a, st in pairs(sentries) do
        if not valid(st.obj) or isGhost(st.obj) then
            if st.marker then destroyMarker(st.marker) end
            sentries[a] = nil
        else
            -- Placed sentries don't move; 4x a second is plenty (covers settling).
            st.loc = callm(st.obj, "K2_GetActorLocation") or st.loc
            if not st.mine and now - st.born < 10 and isMine(st.obj, myPS) then
                -- Owner replicated after we found it: it's yours after all.
                st.mine, st.show, st.id = true, wanted(true), nextId()
                if st.marker then destroyMarker(st.marker); st.marker = nil end
            end
        end
    end

    -- Kill credit: enemies our sentries shot at that are now dead.
    for ea, w in pairs(watched) do
        if not valid(w.obj) or now - w.t > 30 then
            watched[ea] = nil
        else
            local set = getp(w.obj, "AttributeSet")
            local hp = valid(set) and attr(set, "Health") or nil
            if hp and hp <= 0 then
                local inst = getp(set, "LastInstigatorPawn")
                local credit = nil
                if valid(inst) then
                    if sentries[addr(inst)] then credit = addr(inst) end
                else
                    credit = w.sentry   -- no instigator info: credit the last sentry that shot it
                end
                if credit and sentries[credit] then
                    sentries[credit].kills = sentries[credit].kills + 1
                end
                watched[ea] = nil
            end
        end
    end
end

---------------------------------------------------------------------------
-- Per-frame marker update
---------------------------------------------------------------------------
local enabled = true
local WLL = nil
-- Scratch tables reused every frame (the engine copies them on each call),
-- so the per-frame path doesn't allocate.
local PROJ_IN, PROJ_OUT, POS = { X = 0, Y = 0, Z = 0 }, {}, { X = 0, Y = 0 }
local function setPos(slot, x, y)
    POS.X, POS.Y = x, y
    callm(slot, "SetPosition", POS)
end
-- Same, skipped when the marker moved less than half a pixel.
local function setPosC(cache, kx, ky, slot, x, y)
    local ox, oy = cache[kx], cache[ky]
    if ox and math.abs(ox - x) < 0.5 and math.abs(oy - y) < 0.5 then return end
    cache[kx], cache[ky] = x, y
    setPos(slot, x, y)
end

-- Camera for this frame: read once, shared by every sentry.
local CV = { ok = false, fovAt = -1, tanH = 1.2 }
local function camView(pc, now)
    CV.ok = false
    local cm = getp(pc, "PlayerCameraManager")
    if not valid(cm) then return nil end
    local l = callm(cm, "GetCameraLocation")
    local r = callm(cm, "GetCameraRotation")
    if not l or not r then return nil end
    if now - CV.fovAt >= 0.5 then
        CV.fovAt = now
        local f = callm(cm, "GetFOVAngle")
        if f and f > 1 and f < 179 then CV.tanH = math.tan(math.rad(f) / 2) end
    end
    local pr, yr = math.rad(r.Pitch), math.rad(r.Yaw)
    local cp, sp, cy, sy = math.cos(pr), math.sin(pr), math.cos(yr), math.sin(yr)
    CV.lx, CV.ly, CV.lz = l.X, l.Y, l.Z
    CV.fx, CV.fy, CV.fz = cp * cy, cp * sy, sp            -- forward
    CV.rx, CV.ry = -sy, cy                                -- right (no roll)
    CV.ux, CV.uy, CV.uz = -sp * cy, -sp * sy, cp           -- up
    CV.ok = true
    return CV
end
-- Pure Lua: is this point certainly off screen (behind the camera or well
-- outside the view)? Then the engine projection call is skipped. Generous
-- margins: unsure cases still get projected.
local function surelyOff(cv, x, y, z, W, H)
    local vx, vy, vz = x - cv.lx, y - cv.ly, z - cv.lz
    local f = vx * cv.fx + vy * cv.fy + vz * cv.fz
    if f <= 10 then return true end
    local r = vx * cv.rx + vy * cv.ry
    local u = vx * cv.ux + vy * cv.uy + vz * cv.uz
    -- The FOV may be horizontal or vertical (game setting): assume the wider case for both.
    local tH = cv.tanH * math.max(1, W / H) * 1.25
    local tV = cv.tanH * 1.25
    return math.abs(r) > f * tH or math.abs(u) > f * tV + 100
end
local function project(pc, lx, ly, lz)
    if not valid(WLL) then WLL = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary") end
    local loc, out = PROJ_IN, PROJ_OUT
    loc.X, loc.Y, loc.Z = lx, ly, lz
    out.X, out.Y, out.ScreenPosition = nil, nil, nil
    local ok, res = pcall(_call, WLL, "ProjectWorldLocationToWidgetPosition", pc, loc, out, false)
    if not ok then logOnce("proj", "projection error: %s", tostring(res)) return nil end
    if not res then return nil end
    local x, y = out.X, out.Y
    if x == nil and out.ScreenPosition then x, y = out.ScreenPosition.X, out.ScreenPosition.Y end
    if x == nil then return nil end
    return x, y
end

-- Viewport size in widget units (pixels / DPI scale), refreshed twice a second.
local vp = { w = 1920, h = 1080, t = -1 }
local function viewportSize(pc)
    local now = os.clock()
    if now - vp.t < 0.5 then return vp.w, vp.h end
    vp.t = now
    if not valid(WLL) then WLL = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary") end
    local sz = callm(WLL, "GetViewportSize", pc)
    local sc = callm(WLL, "GetViewportScale", pc)
    if sz and sz.X and sz.X > 0 and sc and sc > 0 then vp.w, vp.h = sz.X / sc, sz.Y / sc end
    return vp.w, vp.h
end

-- Direction to a world point in screen space (works behind the camera too).
-- Returns edge position, arrow angle (deg, 0 = pointing right) and the x sign.
local function edgePlacement(cv, loc, W, H)
    if not cv or not cv.ok then return nil end
    local vx, vy, vz = loc.X - cv.lx, loc.Y - cv.ly, loc.Z - cv.lz
    local right = vx * cv.rx + vy * cv.ry
    local up = vx * cv.ux + vy * cv.uy + vz * cv.uz
    local dx, dy = right, -up
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-3 then dx, dy, len = 0, 1, 1 end
    dx, dy = dx / len, dy / len
    local hw, hh = W / 2 - EDGE_MARGIN, H / 2 - EDGE_MARGIN
    local t = math.min(hw / math.max(math.abs(dx), 1e-6), hh / math.max(math.abs(dy), 1e-6))
    return W / 2 + dx * t, H / 2 + dy * t, math.deg(math.atan(dy, dx)), dx
end

local function heatColor(h)
    if h >= RED_AT then return COL_RED elseif h >= YELLOW_AT then return COL_YELLOW end
    return COL_GREEN
end

local lastTick = -1
-- Hide when paused or a cursor menu is open (the pause menu in online games,
-- where PD3 doesn't truly pause). Camera views (security cams, spectating)
-- still show markers: projection uses the active camera.
local function shouldHide(pc)
    if not HIDE_WHEN_PAUSED then return false end
    if not pc then return true end
    if getp(pc, "bShowMouseCursor", false) == true then return true end
    return callm(getGPS(), "IsGamePaused", pc) == true
end

local function byDist(a, b) return a.d < b.d end
local CAM_LOC = { X = 0, Y = 0, Z = 0 }
-- De-overlap entry, one reused table per marker.
local function place(m, w, slot, x, y, s, d, fw, fh)
    local p = m.pl
    if not p then p = {}; m.pl = p end
    p.m, p.w, p.slot, p.x, p.y, p.s, p.d, p.fw, p.fh = m, w, slot, x, y, s, d, fw, fh
    if slot == m.farSlot then p.kx, p.ky = "fx", "fy" else p.kx, p.ky = "nx", "ny" end
    return p
end
local function byId(a, b) return a.id < b.id end
local updatePanel   -- defined below

local function update()
    local now = os.clock()
    if now - lastTick >= TICK_EVERY then
        lastTick = now
        local ok, err = pcall(tick, now)
        if not ok then logOnce("tick:" .. tostring(err), "tick error: %s", tostring(err)) end
    end

    local any = next(sentries) ~= nil
    if not enabled or not any or shouldHide(localPC()) then
        if valid(ui.root) and ui.rootVis ~= VIS_COLLAPSED then
            ui.rootVis = VIS_COLLAPSED
            callm(ui.root, "SetVisibility", VIS_COLLAPSED)
        end
        return
    end
    if not ensureRoot() then return end
    if ui.rootVis ~= VIS_HITTEST_INVIS then
        ui.rootVis = VIS_HITTEST_INVIS
        callm(ui.root, "SetVisibility", VIS_HITTEST_INVIS)
    end

    if ui.resetMarkers then
        ui.resetMarkers = false
        for _, st in pairs(sentries) do st.marker = nil end
    end

    local pc = localPC()
    if not pc then return end
    local cv = camView(pc, now)
    local cam = cv and CAM_LOC or cameraLoc(pc)
    if cv then CAM_LOC.X, CAM_LOC.Y, CAM_LOC.Z = cv.lx, cv.ly, cv.lz end
    local W, H = viewportSize(pc)
    -- Pulse in 1/40 steps: unchanged opacity values skip the engine call.
    local pulse = math.floor((0.55 + 0.45 * math.abs(math.sin(now * 6))) * 40 + 0.5) / 40
    local placed = ui.placed or {}
    ui.placed = placed
    for i = #placed, 1, -1 do placed[i] = nil end

    for a, st in pairs(sentries) do
        local alive = valid(st.obj)
        if not alive then
            if st.marker then destroyMarker(st.marker) end
            sentries[a] = nil
        elseif st.show and not st.marker then
            local ok, res = pcall(createMarker, st.mine and SHOW_MINE or SHOW_TEAMF)
            if ok then st.marker = res else logOnce("marker:" .. tostring(res), "marker creation failed: %s", tostring(res)) end
        end
        local m = alive and st.show and st.marker or nil
        if m then
            local loc = st.loc
            local heat, hp, mult = stats(st, now)
            local x, y
            if loc and heat and not (cv and surelyOff(cv, loc.X, loc.Y, loc.Z + MARKER_CM, W, H)) then
                x, y = project(pc, loc.X, loc.Y, loc.Z + MARKER_CM)
            end
            local onScreen = x ~= nil and x >= 0 and x <= W and y >= 0 and y <= H + 40
            local hot = heat and (heat >= EDGE_WARN_AT or hp <= 0)
            if not onScreen and st.mine and EDGE_WARN and loc and hot then
                local ex, ey, ang, sx = edgePlacement(cv, loc, W, H)
                if ex then
                    setMode(m, "edge")
                    local txt = hp <= 0 and "OVH" or pctStr(heat)
                    if STYLE == "panel" and st.id then txt = st.id .. " (" .. txt .. ")" end
                    if sx >= 0 then   -- arrow on the right -> number to its left
                        setText(m.edgeL, m.cache, "el", txt); setText(m.edgeR, m.cache, "er", "")
                    else              -- arrow on the left -> number to its right
                        setText(m.edgeL, m.cache, "el", ""); setText(m.edgeR, m.cache, "er", txt)
                    end
                    local an = math.floor(ang + 0.5)
                    if m.cache.ang ~= an then
                        m.cache.ang = an
                        callm(m.edgeArrow, "SetRenderTransformAngle", an)
                    end
                    setOpacity(m.edge, m.cache, "eo", (hp <= 0 or heat >= PULSE_AT) and pulse or 1)
                    setPosC(m.cache, "ex", "ey", m.edgeSlot, ex, ey)
                else
                    setMode(m, "hidden")
                end
            elseif not onScreen then
                setMode(m, "hidden")
            else
                local d = cam and distM(cam, loc) or 0
                local overheated = hp <= 0
                local heatStr = overheated and "OVH" or pctStr(heat)
                local bonusStr = string.format("+%d%%", math.floor((mult - 1) * 100 + 0.5))
                local capped = mult >= MAX_MULT - 0.001
                local hc = overheated and COL_RED or heatColor(heat)
                local bc = capped and COL_CAPPED or COL_WHITE
                local opacity = (overheated or heat >= PULSE_AT) and pulse or 1
                -- Field set for this sentry; teammates with heat only never use the near panel.
                local F = st.mine and FIELDS_MINE or FIELDS_TEAM

                if STYLE == "panel" and st.mine then
                    setMode(m, "far")
                    setText(m.farHeat, m.cache, "fh", tostring(st.id or "?"))
                    setColor(m.farHeat, m.cache, "fhc", hc)
                    setOpacity(m.farHeat, m.cache, "fho", opacity)
                    setText(m.farBonus, m.cache, "fb", "")
                    placed[#placed + 1] = place(m, m.far, m.farSlot, x, y, 1, d, 14, 20)
                elseif F.near and d <= NEAR_DIST then
                    setMode(m, "near")
                    if not st.mine then setOpacity(m.near, m.cache, "no", TEAM_OPACITY) end
                    setText(m.nearHeat, m.cache, "nh", heatStr)
                    setColor(m.nearHeat, m.cache, "nhc", hc)
                    setOpacity(m.nearHeat, m.cache, "nho", opacity)
                    setText(m.nearBonus, m.cache, "nb", capped and (bonusStr .. " MAX") or bonusStr)
                    setColor(m.nearBonus, m.cache, "nbc", bc)
                    setText(m.nearKills, m.cache, "nk", tostring(st.kills))
                    local s = SCALE_CLOSE + (SCALE_FAR - SCALE_CLOSE) * clamp((d - 3) / math.max(NEAR_DIST - 3, 1), 0, 1)
                    s = math.floor(s * 100 + 0.5) / 100   -- 1% steps: fewer engine calls
                    if m.cache.scale ~= s then
                        m.cache.scale = s
                        callm(m.near, "SetRenderScale", { X = s, Y = s })
                    end
                    placed[#placed + 1] = place(m, m.near, m.nearSlot, x, y, s, d, 110, 46)
                else
                    setMode(m, "far")
                    -- Far line: heat and/or dmg; kills only if neither is selected.
                    if F.heat then
                        setText(m.farHeat, m.cache, "fh", heatStr)
                        setColor(m.farHeat, m.cache, "fhc", hc)
                        setOpacity(m.farHeat, m.cache, "fho", opacity)
                    else
                        setText(m.farHeat, m.cache, "fh", "")
                    end
                    if F.dmg then
                        setText(m.farBonus, m.cache, "fb", bonusStr)
                        setColor(m.farBonus, m.cache, "fbc", bc)
                    elseif not F.heat and F.kills then
                        setText(m.farBonus, m.cache, "fb", tostring(st.kills) .. " kills")
                        setColor(m.farBonus, m.cache, "fbc", COL_GREY)
                    else
                        setText(m.farBonus, m.cache, "fb", "")
                    end
                    -- Teammate sentry: slightly faded so yours stand out.
                    if not st.mine then setOpacity(m.far, m.cache, "fo", TEAM_OPACITY) end
                    placed[#placed + 1] = place(m, m.far, m.farSlot, x, y, 1,
                        st.mine and d or d + 10000,   -- yours win de-overlap priority
                        st.mine and 85 or 55, 20)
                end
            end
        end
    end

    -- De-overlap: closest marker stays put; others are pushed up until clear.
    for _, p in ipairs(placed) do
        -- Size only changes with the text or mode: measure then, not every frame.
        local mc = p.m.cache
        if mc.szW ~= p.w or (mc.szDirty or 0) > 0 then
            local sz = callm(p.w, "GetDesiredSize")
            mc.szX, mc.szY, mc.szW = sz and sz.X or 0, sz and sz.Y or 0, p.w
            if (mc.szDirty or 0) > 0 then mc.szDirty = mc.szDirty - 1 end
        end
        local w, h = mc.szX, mc.szY
        if not w or w <= 1 then w = p.fw end
        if not h or h <= 1 then h = p.fh end
        p.uh = h                       -- unscaled height (slot anchor is bottom-centre)
        p.hw, p.hh = w * p.s / 2, h * p.s / 2   -- visual half extents
        p.cx, p.cy = p.x, p.y - h / 2           -- visual centre (render scale pivots on centre)
    end
    if #placed > 1 then table.sort(placed, byDist) end
    local GAP = 3
    for i = 2, #placed do
        local p = placed[i]
        for _ = 1, 8 do
            local moved = false
            for j = 1, i - 1 do
                local q = placed[j]
                if math.abs(p.cx - q.cx) < p.hw + q.hw and math.abs(p.cy - q.cy) < p.hh + q.hh + GAP then
                    p.cy = q.cy - q.hh - p.hh - GAP
                    moved = true
                end
            end
            if not moved then break end
        end
    end
    for _, p in ipairs(placed) do
        setPosC(p.m.cache, p.kx, p.ky, p.slot, p.cx, p.cy + p.uh / 2)
    end

    if STYLE == "panel" then
        local ok, err = pcall(updatePanel, pc, pulse)
        if not ok then logOnce("panel:" .. tostring(err), "panel error: %s", tostring(err)) end
    end
end

-- HUD panel contents (Style = panel).
function updatePanel(pc, pulse)
    local own = {}
    for _, st in pairs(sentries) do
        if st.mine and st.id and valid(st.obj) then own[#own + 1] = st end
    end
    if #own > 1 then table.sort(own, byId) end
    local p = ensurePanel()
    local show = #own > 0
    if p.vis ~= show then
        p.vis = show
        callm(p.border, "SetVisibility", show and VIS_HITTEST_INVIS or VIS_COLLAPSED)
    end
    if not show then return end
    local W, H = viewportSize(pc)
    local px, py = W * PANEL_X, H * PANEL_Y
    if p.cache.px ~= px or p.cache.py ~= py then
        p.cache.px, p.cache.py = px, py
        setPos(p.slot, px, py)
    end
    for i, r in ipairs(p.rows) do
        local st = own[i]
        local want = (st ~= nil)
        if want ~= r.vis then
            r.vis = want
            callm(r.box, "SetVisibility", r.vis and VIS_HITTEST_INVIS or VIS_COLLAPSED)
        end
        if st then
            local heat, hp, mult = stats(st, os.clock())
            if heat then
                local overheated = hp <= 0
                local capped = mult >= MAX_MULT - 0.001
                setText(r.cells[1], r.cache, "c1", tostring(st.id))
                setText(r.cells[2], r.cache, "c2", overheated and "OVH" or pctStr(heat))
                setColor(r.cells[2], r.cache, "c2c", overheated and COL_RED or heatColor(heat))
                setOpacity(r.cells[2], r.cache, "c2o", (overheated or heat >= PULSE_AT) and pulse or 1)
                setText(r.cells[3], r.cache, "c3", string.format("+%d%%", math.floor((mult - 1) * 100 + 0.5)))
                setColor(r.cells[3], r.cache, "c3c", capped and COL_CAPPED or COL_WHITE)
                setText(r.cells[4], r.cache, "c4", tostring(st.kills))
                setColor(r.cells[4], r.cache, "c4c", COL_GREY)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Level changes: drop every reference before the old world's objects are used.
---------------------------------------------------------------------------
local curWorld = nil
local pauseUntil = 0     -- after a reset, stay idle while the level swaps

local function resetAll()
    -- If the old overlay survived the level change (heist -> heist without the
    -- main menu), take it off screen. valid() guards against freed objects.
    if valid(ui.root) then callm(ui.root, "RemoveFromParent") end
    ui.root, ui.tree, ui.canvas, ui.icon, ui.rootVis, ui.panel = nil, nil, nil, nil, nil, nil
    ui.swept, ui.failAt = nil, nil
    clearTable(sentries); clearTable(watched); clearTable(pending); clearTable(hudAmmo)
    if pcCache then deadPC[addr(pcCache)] = true end
    pcCache = nil
    -- Discovery starts over; hook registrations are kept (per class object).
    disc.cls, disc.lastSearch, disc.hudSeen = nil, nil, false
    clearTable(disc.checks); clearTable(disc.due)
    disc.players, disc.playersAt = -1, 0
    disc.hudTries, disc.hudTryAt, disc.hookTryAt, disc.hudCheckAt = 0, -100, -100, -100
    curWorld = nil
    pauseUntil = os.clock() + 3
end

-- A new level is playable: look for the sentry class a few times while it
-- settles (a failed lookup is slow, so not continuously).
local function onLevelReady()
    -- Nothing scheduled: the first HUD event (heist start) triggers the class
    -- check. Fallback if no HUD event ever comes: one check after 20 s.
    addChecks({ 20 })
end

---------------------------------------------------------------------------
-- Keys: polled from the game's own input on the game thread.
---------------------------------------------------------------------------
local function toggleStyle()
    STYLE = (STYLE == "panel") and "world" or "panel"
    for _, st in pairs(sentries) do
        if st.marker then destroyMarker(st.marker); st.marker = nil end
    end
    if ui.panel then
        pcall(function() ui.panel.border:RemoveFromParent() end)
        ui.panel = nil
    end
end

local KEYS = {}
-- @dev-begin
-- Debug/staging (ModMenu DEBUG tab, dev builds): change heat of YOUR sentries. Host only.
-- Dev builds only: build_release.py strips everything up to @dev-end.
-- Heat never goes to exactly 100% here: the game only overheats a sentry from a
-- damage event, so F9 leaves 0.1 HP and the next shot breaks it for real.
local function debugHeat(step, breakIt)
    for _, st in pairs(sentries) do
        if st.mine and valid(st.obj) and safe(function() return st.obj:HasAuthority() end, false) then
            pcall(function()
                local set = st.obj.AttributeSet
                local hp = attr(set, "Health") or 0
                if hp <= 0 then return end   -- overheated: leave it alone
                local mx = attr(set, "HealthMax") or 500
                local v = breakIt and 0.1 or clamp(hp - mx * step, 0.1, mx)
                set.Health.BaseValue = v
                set.Health.CurrentValue = v
            end)
        end
    end
end

-- Screenshot staging: your live sentries, in placement order, get believable
-- values. heat = fraction (nil = leave 0.1 HP: breaks on its next shot, OVH).
local STAGE = {
    { heat = 0.85, mult = 1.50, kills = 13 },   -- red, capped (blue MAX)
    { heat = 0.68, mult = 1.35, kills = 7 },    -- yellow
    { heat = nil,  mult = 1.50, kills = 9 },    -- breaks on its next shot
    { heat = 0.22, mult = 1.20, kills = 4 },
}
local function debugStage()
    local list = {}
    for _, st in pairs(sentries) do
        if st.mine and valid(st.obj) and safe(function() return st.obj:HasAuthority() end, false) then
            list[#list + 1] = st
        end
    end
    table.sort(list, function(a, b) return (a.id or 0) < (b.id or 0) or ((a.id or 0) == (b.id or 0) and a.born < b.born) end)
    local done = {}
    for i, st in ipairs(list) do
        local p = STAGE[(i - 1) % #STAGE + 1]
        pcall(function()
            local set = st.obj.AttributeSet
            local mx = attr(set, "HealthMax") or 500
            local v = p.heat and mx * (1 - p.heat) or 0.1
            set.Health.BaseValue = v
            set.Health.CurrentValue = v
            set.OutgoingDamageMultiplier.BaseValue = p.mult
            set.OutgoingDamageMultiplier.CurrentValue = p.mult
        end)
        st.kills = p.kills
        st.statAt = nil                       -- show the new values at once
        done[#done + 1] = p.heat and string.format("%d%%", math.floor(p.heat * 100 + 0.5)) or "break"
    end
    if #list == 0 then return "no sentries of yours found (host only)" end
    return "staged " .. #list .. ": " .. table.concat(done, ", ")
end

-- @dev-end
-- the two keys from settings.ini (rebuilt when the settings are reloaded)
local MM = { seen = nil, at = 0 }   -- ModMenu live settings (one table: Lua's 200-locals limit)
function MM.buildKeys()
    for i = #KEYS, 1, -1 do if KEYS[i].setting then table.remove(KEYS, i) end end
    if TOGGLE_KEY ~= "" and TOGGLE_KEY ~= "NONE" then
        KEYS[#KEYS + 1] = { name = TOGGLE_KEY, setting = true, fn = function() enabled = not enabled end }
    end
    if STYLE_KEY ~= "" and STYLE_KEY ~= "NONE" and STYLE_KEY ~= TOGGLE_KEY then
        KEYS[#KEYS + 1] = { name = STYLE_KEY, setting = true, fn = toggleStyle }
    end
end
MM.buildKeys()

-- settings.ini changed (from ModMenu): read it again and rebuild what depends on it
function MM.reloadSettings()
    local before = #SETTINGS_LOG
    loadSettings()
    if YELLOW_AT > RED_AT then YELLOW_AT = RED_AT end
    if EDGE_WARN_AT == nil then EDGE_WARN_AT = RED_AT end
    SHOW_TEAM = anyField(SHOW_TEAMF)
    FIELDS_MINE.heat, FIELDS_MINE.dmg, FIELDS_MINE.kills = SHOW_MINE.heat, SHOW_MINE.dmg, SHOW_MINE.kills
    FIELDS_TEAM.heat, FIELDS_TEAM.dmg, FIELDS_TEAM.kills = SHOW_TEAMF.heat, SHOW_TEAMF.dmg, SHOW_TEAMF.kills
    FIELDS_TEAM.near = (SHOW_TEAMF.dmg or SHOW_TEAMF.kills) or false
    MM.buildKeys()
    -- markers and the panel are rebuilt with the new look on the next frame
    for _, st in pairs(sentries) do
        if st.marker then destroyMarker(st.marker); st.marker = nil end
    end
    if ui.panel then
        pcall(function() ui.panel.border:RemoveFromParent() end)
        ui.panel = nil
    end
    log("settings reloaded (style=%s, %s = markers on/off, %s = switch style)", STYLE, TOGGLE_KEY, STYLE_KEY)
    for i = before + 1, #SETTINGS_LOG do log("%s", SETTINGS_LOG[i]) end
end
---------------------------------------------------------------------------
-- Live settings: ModMenu (the in-game settings menu) sets the shared
-- variable "ModMenu.changed.<this folder>" after it saves our settings.ini.
-- Checked twice a second; without ModMenu it never changes.
---------------------------------------------------------------------------
MM.var = "ModMenu.changed." .. (((debug and debug.getinfo and debug.getinfo(1, "S").source) or "")
    :match("([^/\\]+)[/\\]Scripts[/\\][^/\\]*$") or "SentryHeat")
function MM.check()
    local now = os.clock()
    if now < MM.at then return end
    MM.at = now + 0.5
    if ModRef == nil then return end
    if MM.debugCheck then MM.debugCheck() end
    local ok, v = pcall(ModRef.GetSharedVariable, ModRef, MM.var)
    if not ok or v == nil or v == MM.seen then return end
    MM.seen = v
    local ok2, err = pcall(MM.reloadSettings)
    if not ok2 then log("settings reload failed: %s", tostring(err)) end
end
-- @dev-begin
-- Debug actions for ModMenu's DEBUG tab (dev builds; shown when its Debug setting is on). The
-- list goes out in "ModMenu.debug.<folder>" (one "id<TAB>label<TAB>description"
-- per line). ModMenu asks for one with "ModMenu.run.<folder>" = "id#stamp" and
-- gets "id#stamp<TAB>result" back in "ModMenu.reply.<folder>".
MM.folder = MM.var:match("^ModMenu%.changed%.(.+)$")
MM.actions = {}
function MM.action(id, label, desc, fn) MM.actions[#MM.actions + 1] = { id = id, label = label, desc = desc, fn = fn } end
function MM.debugCheck()
    if #MM.actions == 0 then return end           -- (dev builds; ModMenu shows them when its Debug setting is on)
    if not MM.published then
        local lines = {}
        for _, a in ipairs(MM.actions) do lines[#lines + 1] = a.id .. "\t" .. a.label .. "\t" .. (a.desc or "") end
        MM.published = pcall(ModRef.SetSharedVariable, ModRef, "ModMenu.debug." .. MM.folder, table.concat(lines, "\n"))
    end
    local ok, r = pcall(ModRef.GetSharedVariable, ModRef, "ModMenu.run." .. MM.folder)
    r = (ok and type(r) == "string") and r or ""
    if MM.lastRun == nil then MM.lastRun = r; return end   -- first look: a request from before a reload is old
    if r == MM.lastRun then return end
    MM.lastRun = r
    local id = r:match("^(.-)#")
    for _, a in ipairs(MM.actions) do
        if a.id == id then
            local ok2, res = pcall(a.fn)
            res = ok2 and tostring(res or "done") or ("error: " .. tostring(res))
            log("debug action %s: %s", id, res)
            pcall(ModRef.SetSharedVariable, ModRef, "ModMenu.reply." .. MM.folder, r .. "\t" .. res)
        end
    end
end
-- @dev-end
-- @dev-begin
MM.action("heat_up", "Heat +10%", "Your sentries (host only).", function() debugHeat(0.10); return "heat +10% on your sentries" end)
MM.action("heat_down", "Heat -10%", "Your sentries (host only).", function() debugHeat(-0.10); return "heat -10% on your sentries" end)
MM.action("break", "Break on next shot", "Leaves 0.1 HP, so the next shot overheats it for real (host only).", function() debugHeat(0, true); return "your sentries break on their next shot" end)
MM.action("stage", "Stage for screenshots", "Your sentries in placement order: 85% red +50%, 68% yellow +35%, then one that breaks on its next shot (host only).", debugStage)
-- @dev-end

local keyWarned = false
local function pollKeys(pc)
    for _, k in ipairs(KEYS) do
        if not k.fkey then k.fkey = { KeyName = FName(k.name) } end
        local ok, down = pcall(_call, pc, "WasInputKeyJustPressed", k.fkey)
        if not ok and not keyWarned then
            keyWarned = true
            log("key polling failed: %s", tostring(down))
        elseif ok and down then
            local ok2, err = pcall(k.fn)
            if not ok2 then logOnce("key:" .. tostring(err), "key %s error: %s", k.name, tostring(err)) end
        end
    end
end

---------------------------------------------------------------------------
-- Main loop: everything runs here, on the game thread. (No LoopAsync,
-- ExecuteWithDelay or RegisterKeyBind: they run Lua on other threads.)
---------------------------------------------------------------------------
local function frame()
    local now = os.clock()
    if now < pauseUntil then return end
    if next(deadPC) and now - pauseUntil > 30 then clearTable(deadPC) end
    -- Level change: world pointer changed -> drop everything before touching it.
    local pc = localPC()
    local wa = pc and addr(callm(pc, "GetWorld")) or 0
    if curWorld ~= nil and wa ~= curWorld then
        resetAll()
        return
    end
    if wa == 0 then curWorld = nil return end
    if curWorld == nil then onLevelReady() end
    curWorld = wa
    pollKeys(pc)
    local ok, err = pcall(update)
    if not ok then logOnce("upd:" .. tostring(err), "update error: %s", tostring(err)) end
end

-- PerfLog = true: every 10 s, the mod's own time per frame, the Lua garbage
-- it makes and the sentry searches (os.clock has ~1 ms steps, so the average
-- is over many frames).
local pf = { t0 = os.clock(), n = 0, sum = 0, worst = 0, kb = 0 }
local function perfFrame()
    local m0 = collectgarbage("count")
    local c0 = os.clock()
    local ok, err = pcall(frame)
    local dt = os.clock() - c0
    local m1 = collectgarbage("count")
    if not ok then logOnce("frame:" .. tostring(err), "frame error: %s", tostring(err)) end
    pf.n, pf.sum = pf.n + 1, pf.sum + dt
    if dt > pf.worst then pf.worst = dt end
    if m1 > m0 then pf.kb = pf.kb + (m1 - m0) end
    local span = c0 - pf.t0
    if span >= 10 then
        local k = 0
        for _ in pairs(sentries) do k = k + 1 end
        log("perf: %d frames in %.0f s, avg %.3f ms, worst %.1f ms, garbage %.1f KB/s, %d sentries, %d searches (avg %.1f ms, worst %.1f ms), class %s, HUD events %s",
            pf.n, span, pf.sum / pf.n * 1000, pf.worst * 1000, pf.kb / span, k,
            disc.n, disc.n > 0 and disc.ms / disc.n or 0, disc.worst,
            disc.cls and "loaded" or "not loaded", disc.hudSeen and "seen" or "not seen")
        pf.t0, pf.n, pf.sum, pf.worst, pf.kb = c0, 0, 0, 0, 0
        disc.n, disc.ms, disc.worst = 0, 0, 0
    end
end

LoopInGameThreadAfterFrames(1, function()
    MM.check()
    if PERF_LOG then
        perfFrame()
    else
        local ok, err = pcall(frame)
        if not ok then logOnce("frame:" .. tostring(err), "frame error: %s", tostring(err)) end
    end
    return false
end)

log("1.1.0 loaded (style=%s, %s = markers on/off, %s = switch style)", STYLE, TOGGLE_KEY, STYLE_KEY)
for _, l in ipairs(SETTINGS_LOG) do log("%s", l) end
if PERF_LOG then log("perf log ON (every 10 s)") end
