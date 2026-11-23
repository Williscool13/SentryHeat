"""Build the SentryHeat release zip from the dev source.

Dev-only code (debug actions for Will's Mod Menu) is marked in main.lua and stripped here:
  a line ending in   -- @dev          is removed
  lines between      -- @dev-begin / -- @dev-end   are removed (markers too)

usage: python build_release.py          (run from the repo root)
"""
import os, re, sys, time, zipfile

VERSION = "1.1.0"

def strip_dev(src):
    out, skipping = [], False
    for line in src.split("\n"):
        tag = line.strip()
        if tag == "-- @dev-begin":
            assert not skipping, "nested @dev-begin"
            skipping = True
            continue
        if tag == "-- @dev-end":
            assert skipping, "@dev-end without begin"
            skipping = False
            continue
        if skipping or line.rstrip().endswith("-- @dev"):
            continue
        out.append(line)
    assert not skipping, "unclosed @dev-begin"
    return "\n".join(out)

lua_dev = open("SentryHeat/Scripts/main.lua", encoding="utf-8").read()
lua = strip_dev(lua_dev)
for bad in ("DEBUG_KEYS", "debugHeat", "debugkeys", '"F8"', '"F6"', '"F9"', "@dev"):
    assert bad not in lua, "dev code left in release: " + bad
os.makedirs("build", exist_ok=True)
os.makedirs("release", exist_ok=True)
open("build/main.release.lua", "w", encoding="utf-8", newline="\n").write(lua)

ini = open("SentryHeat/settings.ini", encoding="utf-8").read().replace("\r\n", "\n")
readme = open("docs/player-readme.txt", encoding="utf-8").read().replace("\r\n", "\n")
assert "debugkeys" not in ini.lower() and "perflog" not in ini.lower()
schema = open("SentryHeat/settings.schema.json", "rb").read()
import json; json.loads(schema)
crlf = lambda t: t.replace("\n", "\r\n").encode("utf-8")

for _ in (1,):   # one zip; the style is switched in game (Style setting / StyleKey)
    i = ini
    p = f"release/SentryHeat-{VERSION}.zip"
    dt = time.localtime()[:6]
    with zipfile.ZipFile(p, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in (("SentryHeat/Scripts/main.lua", lua.encode("utf-8")),
                           ("SentryHeat/settings.ini", crlf(i)),
                           ("SentryHeat/settings.schema.json", schema),
                           ("SentryHeat/enabled.txt", b""),
                           ("SentryHeat/README.txt", crlf(readme))):
            zi = zipfile.ZipInfo(name, dt)
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)
    with zipfile.ZipFile(p) as z:
        assert z.testzip() is None
        style = [l.split(";")[0].strip() for l in z.read("SentryHeat/settings.ini").decode().splitlines()
                 if l.startswith("Style ")]
        print(p, z.namelist(), style)
print("release main.lua: %d lines (dev %d); also written to build/main.release.lua for testing"
      % (lua.count("\n") + 1, lua_dev.count("\n") + 1))
