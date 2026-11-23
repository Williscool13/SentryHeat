"""Mock-world test for SentryHeat event-based discovery + per-frame garbage.
usage: simperf.py main.lua"""
import sys
from lupa.lua54 import LuaRuntime
L = LuaRuntime()
L.execute(r'''
clock = 0
os.clock = function() return clock end
local function isv(self) return self.__valid end
local function ga(self) return self.__addr end
local function nop() return nil end
local MT = { __index = function(t, k)
    if k == "IsValid" then return isv end
    if k == "GetAddress" then return ga end
    return nop
  end }
local function obj(fields)
  local o = fields or {}
  o.__valid = true
  return setmetatable(o, MT)
end
_G.obj = obj
local n = 0
texts = {}; seen = {}
local function W() n = n + 1; local o = obj({ __addr = 1000 + n }); o.Font = { OutlineSettings = {} }; o.SetText = function(self, s) if not seen[s] then seen[s] = true; texts[#texts+1] = s end end; return o end
function FName(s) return s end
function FText(s) return s end
logs = {}
function print(...) local s = table.concat({...}, " "); logs[#logs+1] = s; io.write(s) end
SENTRY_BP = "/Game/Gameplay/SentryGun/BP_SentryGun.BP_SentryGun_C"
classLoaded = false; hudLoaded = true
stats = { failed = 0, found = 0, search = 0, hookreg = 0 }
sentryCls = obj({ __addr = 4242 })
serverT = nil
gs = obj({ __addr = 801, GetServerWorldTimeSeconds = function() return serverT end, PlayerArray = obj({ __addr = 802, GetArrayNum = function() return players end }) })
players = 1
function StaticFindObject(p)
  if p:find("WidgetLayoutLibrary") then
    stats.found = stats.found + 1
    return obj({ __addr = 7,
      ProjectWorldLocationToWidgetPosition = function(self, pc, loc, out) out.X = loc.X / 10 + 500; out.Y = 400; return true end,
      GetViewportSize = function() return { X = 1920, Y = 1080 } end,
      GetViewportScale = function() return 1 end })
  end
  if p:find("GameplayStatics") then stats.found = stats.found + 1; return obj({ __addr = 8, IsGamePaused = function() return false end, GetGameState = function() return gs end }) end
  if p == SENTRY_BP then
    if classLoaded then stats.found = stats.found + 1; return sentryCls end
    stats.failed = stats.failed + 1; return nil
  end
  if p:find("PlaceableStatus") then
    if hudLoaded then stats.found = stats.found + 1; return obj({ __addr = p:find("PartyMember") and 4301 or 4300 }) end
    stats.failed = stats.failed + 1; return nil
  end
  if p:find("^/Script/") then return obj({ __addr = 9 }) end
  stats.found = stats.found + 1
  return obj({ __addr = 10 })
end
function LoadAsset(p) return obj({ __addr = 10 }) end
function StaticConstructObject(c, outer, name)
  local o = W()
  o.AddChildToHorizontalBox = function() return W() end
  o.AddChildToVerticalBox = function() return W() end
  o.AddChildToCanvas = function() return W() end
  o.GetDesiredSize = function() return { X = 80, Y = 18 } end
  o.IsInViewport = function() return true end
  o.GetFName = function() return { ToString = function() return name end } end
  return o
end
hooks = {}
function RegisterHook(path, fn)
  stats.hookreg = stats.hookreg + 1
  if path:find("^" .. SENTRY_BP:gsub("%p", "%%%0")) and not classLoaded then error("no such function") end
  hooks[path] = fn; return 1, 1
end
loops = {}
function LoopInGameThreadAfterFrames(n, fn) loops[#loops + 1] = fn end

world = obj({ __addr = 500 })
myPS = obj({ __addr = 600 })
otherPS = obj({ __addr = 601 })
pressed = {}
pc = obj({ __addr = 700, PlayerState = myPS, bShowMouseCursor = false,
  IsLocalController = function() return true end,
  HasAuthority = function() return true end,
  GetWorld = function() return world end,
  WasInputKeyJustPressed = function(self, k) return pressed[k.KeyName] == true end,
  PlayerCameraManager = obj({ __addr = 701,
     GetCameraLocation = function() return { X = 0, Y = 0, Z = 0 } end,
     GetCameraRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end }) })
function attrset(h, m) return obj({ __addr = 0, Health = { CurrentValue = h, BaseValue = h }, HealthMax = { CurrentValue = 500 }, OutgoingDamageMultiplier = { CurrentValue = m } }) end
function sentry(a, ps, x, h, m)
  return obj({ __addr = a, OwnerPlayerState = ps, bHidden = false, AttributeSet = attrset(h, m),
    HasAuthority = function() return true end,
    K2_GetActorLocation = function() return { X = x, Y = 0, Z = 0 } end })
end
sentryList = {}
function FindAllOf(c)
  if c == "PlayerController" then return { pc } end
  if c == "BP_SentryGun_C" then stats.search = stats.search + 1; return sentryList end
  if c == "UserWidget" then return {} end
  return nil
end
function run(sec) local k = math.floor(sec * 60 + 0.5); for i = 1, k do clock = clock + 1/60; for _, f in ipairs(loops) do f() end end end
function count(t) local k = 0; for _ in pairs(t) do k = k + 1 end; return k end
function reset() for k in pairs(stats) do stats[k] = 0 end end
function check(name, cond) io.write((cond and "PASS " or "FAIL ") .. name .. "\n"); if not cond then FAILS = (FAILS or 0) + 1 end end
''')
L.execute(open(sys.argv[1], encoding='utf-8').read())
L.execute(r'''
io.write("\n--- A: map without sentries, 3 min ---\n")
run(180)
io.write(string.format("failed lookups %d, sentry searches %d, hook registrations %d\n", stats.failed, stats.search, stats.hookreg))
check("A: at most 4 slow lookups in 3 min", stats.failed <= 4)
check("A: no sentry searches", stats.search == 0)

io.write("\n--- B: teammate joins with a sentry (class loads) ---\n")
reset()
players = 2; run(2); classLoaded = true
sentryList = { sentry(103, otherPS, 800, 200, 1.0) }
run(40)
io.write(string.format("failed lookups %d, searches %d, hooks %d\n", stats.failed, stats.search, stats.hookreg))
check("B: class found after join, teammate sentry tracked", hooks[SENTRY_BP .. ":OnOverheatDamageTaken"] ~= nil)
check("B: searches small (<= 3 in 40 s)", stats.search <= 3)

io.write("\n--- C: you throw a sentry; HUD event -> found ~1 s later ---\n")
reset()
own = "/Game/UI/Widgets/HUD/WBP_UI_WidgetPlaceableStatus.WBP_UI_WidgetPlaceableStatus_C:OnAmmoInventoryChanged"
check("C: own HUD hook registered", hooks[own] ~= nil)
s1 = sentry(101, myPS, 500, 450, 1.1)
sentryList = { sentryList[1], s1 }
hudW = obj({ __addr = 5000 })
hooks[own]({ get = function() return hudW end }, { get = function() return 2 end })
run(3)
check("C: first count seen (heist start): no search", stats.search == 0)
hooks[own]({ get = function() return hudW end }, { get = function() return 1 end })
run(0.5)
check("C: not searched before 1 s", stats.search == 0)
run(1.0)
check("C: searched after ~1 s", stats.search == 1)
run(3)
check("C: only 1 search for the placement", stats.search == 1)
hooks[own]({ get = function() return hudW end }, { get = function() return 2 end })
run(3)
check("C: pickup (count up): no search", stats.search == 1)

io.write("\n--- D: unknown sentry shoots -> added without a search ---\n")
reset()
s2 = sentry(102, myPS, 3000, 50, 1.5)
sentryList[#sentryList + 1] = s2
hooks[SENTRY_BP .. ":OnOverheatDamageTaken"]({ get = function() return s2 end })
run(0.5)
check("D: no search", stats.search == 0)
-- kill credit
local enemy = obj({ __addr = 900, AttributeSet = obj({ __addr = 901, Health = { CurrentValue = 100 } }) })
s1.CurrentTarget = enemy
hooks[SENTRY_BP .. ":OnOverheatDamageTaken"]({ get = function() return s1 end })
enemy.AttributeSet.Health.CurrentValue = 0
enemy.AttributeSet.LastInstigatorPawn = s1
run(1)

io.write("\n--- E: pick up s1 (hidden ghost), overheat s2 off screen ---\n")
s1.bHidden = true
s2.AttributeSet.Health.CurrentValue = 0
s2.K2_GetActorLocation = function() return { X = -50000, Y = 0, Z = 0 } end
run(2)

io.write("\n--- F: garbage per frame, 3 sentries on screen, world style ---\n")
s1.bHidden = false
s2.K2_GetActorLocation = function() return { X = 3000, Y = 0, Z = 0 } end
s2.AttributeSet.Health.CurrentValue = 50
run(2)
collectgarbage("collect"); collectgarbage("stop")
local m0 = collectgarbage("count"); run(10); local m1 = collectgarbage("count")
collectgarbage("restart")
io.write(string.format("garbage %.2f KB/frame (world)\n", (m1 - m0) / 600))
pressed["F5"] = true; run(1/60); pressed["F5"] = false; run(1)
collectgarbage("collect"); collectgarbage("stop")
m0 = collectgarbage("count"); run(10); m1 = collectgarbage("count")
collectgarbage("restart")
io.write(string.format("garbage %.2f KB/frame (panel)\n", (m1 - m0) / 600))

io.write("\n--- G: safety cadence with HUD events seen: 5 min ---\n")
reset(); run(300)
io.write(string.format("searches in 5 min: %d\n", stats.search))
check("G: <= 3 safety searches in 5 min", stats.search <= 3)

io.write("\n--- H: level change -> new map with class still loaded ---\n")
reset()
world = obj({ __addr = 501 }); run(0.1); pc.__addr = 702; run(31)
io.write(string.format("failed %d, searches %d, hook registrations %d\n", stats.failed, stats.search, stats.hookreg))
check("H: hooks not re-registered (same class objects)", stats.hookreg == 0)
check("H: searched on the new level", stats.search >= 1)

io.write("\n--- I: new level, class loads late (60 s, no join), then a HUD event ---\n")
classLoaded = false; sentryCls.__valid = false
world = obj({ __addr = 502 }); run(0.1); pc.__addr = 703
reset(); run(60)
io.write(string.format("before load: failed %d, searches %d\n", stats.failed, stats.search))
check("I: no searches while the class isn't loaded", stats.search == 0)
check("I: few slow lookups in 60 s", stats.failed <= 4)
classLoaded = true; sentryCls = obj({ __addr = 4343 })
sentryList = { sentry(110, myPS, 500, 400, 1.0) }
reset()
hooks[own]({ get = function() return nil end }, { get = function() return 1 end })
run(3.5)
io.write(string.format("after HUD event: failed %d, searches %d, hook regs %d\n", stats.failed, stats.search, stats.hookreg))
check("I: class found and searched within ~3 s of the HUD event", stats.search >= 1)
check("I: heat hook registered on the new class", stats.hookreg >= 1)

io.write("\n--- J: fresh heist (server time 10 s), class loaded at start ---\n")
serverT = 10
world = obj({ __addr = 503 }); run(0.1); pc.__addr = 704
reset(); run(4)
hudW2 = obj({ __addr = 5001 })
hooks[own]({ get = function() return hudW2 end }, { get = function() return 2 end })
run(20)
io.write(string.format("failed %d, searches %d\n", stats.failed, stats.search))
check("J: no search at a fresh start", stats.search == 0)
check("J: class found from the first HUD event", hooks[SENTRY_BP .. ":OnOverheatDamageTaken"] ~= nil)
io.write("TEXTS: " .. table.concat(texts, " | ") .. "\n")
io.write(string.format("\n%s\n", FAILS and (FAILS .. " FAILED") or "ALL PASS"))
''')
