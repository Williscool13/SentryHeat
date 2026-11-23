"""Smoke test: runs SentryHeat in a mock world (sentries, heat, kills, edge arrow,
panel, level change) and prints what it would draw. No assertions.
usage: python tests/simtest.py SentryHeat/Scripts/main.lua"""
import sys
from lupa.lua54 import LuaRuntime
L = LuaRuntime()
L.execute(r'''
clock = 0
os.clock = function() return clock end
local function obj(fields)
  local o = fields or {}
  o.__valid = true
  local mt = {}
  mt.__index = function(t, k)
    if k == "IsValid" then return function(self) return self.__valid end end
    if k == "GetAddress" then return function(self) return self.__addr end end
    -- any unknown method: return a function that returns a fresh object (widgets etc.)
    return function(self, ...) return rawget(t, "__ret_" .. k) end
  end
  return setmetatable(o, mt)
end
_G.obj = obj
local n = 0
texts = {}; seen = {}
local function W() n = n + 1; local o = obj({ __addr = 1000 + n }); o.Font = { OutlineSettings = {} }; o.SetText = function(self, s) if not seen[s] then seen[s] = true; texts[#texts+1] = s end end; return o end
_G.W = W
function FName(s) return s end
function FText(s) return s end
function print(...) io.write(table.concat({...}, " ")) end
function StaticFindObject(p)
  if p:find("WidgetLayoutLibrary") then
    return obj({ __addr = 7,
      ProjectWorldLocationToWidgetPosition = function(self, pc, loc, out) out.X = loc.X / 10 + 500; out.Y = 400; return true end,
      GetViewportSize = function() return { X = 1920, Y = 1080 } end,
      GetViewportScale = function() return 1 end })
  end
  if p:find("GameplayStatics") then return obj({ __addr = 8, IsGamePaused = function() return false end, GetGameState = function() return nil end }) end
  return obj({ __addr = 9 })
end
function LoadAsset(p) return obj({ __addr = 10 }) end
function StaticConstructObject(c, outer, name)
  local o = W()
  o.__name = name
  o.AddChildToHorizontalBox = function() return W() end
  o.AddChildToVerticalBox = function() return W() end
  o.AddChildToCanvas = function() return W() end
  o.GetDesiredSize = function() return { X = 80, Y = 18 } end
  o.IsInViewport = function() return true end
  o.GetFName = function() return { ToString = function() return name end } end
  return o
end
hooks = {}
byPath = {}
function RegisterHook(path, fn) hooks[#hooks + 1] = fn; byPath[path] = fn; return 1, 1 end
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
enemy = obj({ __addr = 900, AttributeSet = obj({ __addr = 901, Health = { CurrentValue = 100 } }) })
s1 = sentry(101, myPS, 500, 450, 1.1)
s2 = sentry(102, myPS, 3000, 50, 1.5)
s3 = sentry(103, otherPS, 800, 200, 1.0)
s1.CurrentTarget = enemy
sentryList = { s1, s2, s3 }
userWidgets = {}
function FindAllOf(c)
  if c == "PlayerController" then return { pc } end
  if c == "BP_SentryGun_C" then return sentryList end
  if c == "UserWidget" then return userWidgets end
  return nil
end
''')
L.execute(open(sys.argv[1], encoding='utf-8').read())
L.execute(r'''
local function run(k) for i = 1, k do clock = clock + 0.3; for _, f in ipairs(loops) do f() end end end
run(80)
print("\nhooks:", #hooks, "\n")
-- shot + kill credit
byPath['/Game/Gameplay/SentryGun/BP_SentryGun.BP_SentryGun_C:OnOverheatDamageTaken']({ get = function() return s1 end })
enemy.AttributeSet.Health.CurrentValue = 0
enemy.AttributeSet.LastInstigatorPawn = s1
run(3)
-- overheat s2 + edge (move s2 off screen)
s2.AttributeSet.Health.CurrentValue = 0
s2.K2_GetActorLocation = function() return { X = -50000, Y = 0, Z = 0 } end
run(3)
-- style toggle
pressed["F5"] = true; run(1); pressed["F5"] = false; run(3)
pressed["F7"] = true; run(1); pressed["F7"] = false; run(2)
pressed["F7"] = true; run(1); pressed["F7"] = false; run(2)
-- menu hide
pc.bShowMouseCursor = true; run(2); pc.bShowMouseCursor = false; run(2)
-- level change
world = obj({ __addr = 501 }); run(2); clock = clock + 4; run(5)
print("TEXTS: " .. table.concat(texts, " | "))
print("\nsim done\n")
''')
