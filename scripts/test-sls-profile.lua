#!/usr/bin/env luajit
-- Unit tests for plugin/backend/sls_profile.lua (SLSsteam config resolution).
-- Run from the repo root:  luajit scripts/test-sls-profile.lua   (also lua5.4)

package.path = "plugin/backend/?.lua;" .. package.path
local sls_profile = require("sls_profile")

local fails = 0
local function check(name, cond)
  if cond then
    io.write("ok " .. name .. "\n")
  else
    io.write("FAIL " .. name .. "\n")
    fails = fails + 1
  end
end

local function environ(vars)
  local parts = {}
  for _, pair in ipairs(vars) do parts[#parts + 1] = pair .. "\0" end
  return table.concat(parts)
end

-- procs: list of { pid = "N", comm = "steam\n", env = <blob or nil> }
local function fake(env, procs)
  local by_pid = {}
  local pids = {}
  for _, proc in ipairs(procs or {}) do
    by_pid[proc.pid] = proc
    pids[#pids + 1] = proc.pid
  end
  local scanned = false
  local opts = {
    getenv = function(key) return env[key] end,
    list_pids = function() scanned = true; return pids end,
    read_comm = function(pid) return by_pid[pid] and by_pid[pid].comm end,
    read_environ = function(pid) return by_pid[pid] and by_pid[pid].env end,
  }
  return opts, function() return scanned end
end

local HOME = "/home/berk"
local function steam_proc(pid, comm, home, xdg)
  local vars = { "PATH=/usr/bin", "HOME=" .. home }
  if xdg then vars[#vars + 1] = "XDG_CONFIG_HOME=" .. xdg end
  return { pid = pid, comm = comm .. "\n", env = environ(vars) }
end

-- environ_value
local blob = environ({ "HOMEDIR=/wrong", "HOME=/home/a", "EMPTY=", "EQ=a=b" }) .. "LAST=tail"
check("E1 exact key match", sls_profile.environ_value(blob, "HOME") == "/home/a")
check("E2 prefix key not confused", sls_profile.environ_value(blob, "HOMEDIR") == "/wrong")
check("E3 empty value is nil", sls_profile.environ_value(blob, "EMPTY") == nil)
check("E4 missing key is nil", sls_profile.environ_value(blob, "XDG_CONFIG_HOME") == nil)
check("E5 value keeps '='", sls_profile.environ_value(blob, "EQ") == "a=b")
check("E6 unterminated last entry", sls_profile.environ_value(blob, "LAST") == "tail")
check("E7 nil blob", sls_profile.environ_value(nil, "HOME") == nil)
check("E8 value match is not a key match",
  sls_profile.environ_value(environ({ "A=HOME=/x" }), "HOME") == nil)

-- Tier 1: SLSSTEAM_CONFIG_HOME wins over everything and skips /proc.
local opts, scanned = fake(
  { SLSSTEAM_CONFIG_HOME = "/srv/sls///", HOME = HOME, XDG_CONFIG_HOME = "/own/xdg" },
  { steam_proc("10", "steam", HOME, "/steam/xdg") })
check("T1 explicit override, trailing slashes stripped",
  sls_profile.config_home(opts) == "/srv/sls")
check("T1 explicit override does not scan /proc", not scanned())
check("T1 root", sls_profile.root(opts) == "/srv/sls/SLSsteam")
check("T1 path", sls_profile.path("config.yaml", opts) == "/srv/sls/SLSsteam/config.yaml")

opts = fake({ SLSSTEAM_CONFIG_HOME = "///", HOME = HOME })
check("T1 slash-only override counts as unset", sls_profile.config_home(opts) == HOME .. "/.config")

-- Tier 2: running Steam's XDG_CONFIG_HOME beats our own.
opts = fake({ HOME = HOME, XDG_CONFIG_HOME = "/own/xdg" },
  { { pid = "5", comm = "bash\n", env = environ({ "HOME=" .. HOME, "XDG_CONFIG_HOME=/bash/xdg" }) },
    steam_proc("10", "steam", HOME, "/steam/xdg/") })
check("T2 steam process XDG used, slash stripped", sls_profile.config_home(opts) == "/steam/xdg")

opts = fake({ HOME = HOME },
  { steam_proc("11", "steamwebhelper", HOME, "/helper/xdg"),
    steam_proc("12", "steam", HOME, "/steam/xdg") })
check("T2 steam preferred over earlier steamwebhelper", sls_profile.config_home(opts) == "/steam/xdg")

opts = fake({ HOME = HOME, XDG_CONFIG_HOME = "/own/xdg" },
  { steam_proc("11", "steamwebhelper", HOME, "/helper/xdg") })
check("T2 steamwebhelper used when steam absent", sls_profile.config_home(opts) == "/helper/xdg")

opts = fake({ HOME = HOME },
  { steam_proc("10", "steam", HOME, nil),
    steam_proc("11", "steamwebhelper", HOME, "/helper/xdg") })
check("T2 steam without XDG does not qualify", sls_profile.config_home(opts) == "/helper/xdg")

opts = fake({ HOME = HOME },
  { steam_proc("10", "steam", HOME .. "/", "/steam/xdg") })
check("T2 HOME match ignores trailing slash", sls_profile.config_home(opts) == "/steam/xdg")

opts = fake({ HOME = HOME, XDG_CONFIG_HOME = "/own/xdg" },
  { steam_proc("10", "steam", "/home/other", "/other/xdg"),
    steam_proc("11", "steamwebhelper", "/home/other", "/other/helper") })
check("T2 foreign HOME processes ignored", sls_profile.config_home(opts) == "/own/xdg")

opts = fake({ HOME = HOME, XDG_CONFIG_HOME = "/own/xdg" },
  { { pid = "10", comm = "steam\n", env = nil } })
check("T2 unreadable environ skipped", sls_profile.config_home(opts) == "/own/xdg")

opts = fake({ HOME = HOME }, { steam_proc("10", "steam", HOME, "/steam/xdg") })
opts.home = function() return "/home/injected" end
check("T2 injected home reader drives the match", sls_profile.config_home(opts) == "/home/injected/.config")

-- Tier 3: our own XDG_CONFIG_HOME.
opts = fake({ HOME = HOME, XDG_CONFIG_HOME = "/own/xdg//" })
check("T3 own XDG, trailing slashes stripped", sls_profile.config_home(opts) == "/own/xdg")
opts = fake({ HOME = HOME, XDG_CONFIG_HOME = "" })
check("T3 empty XDG ignored", sls_profile.config_home(opts) == HOME .. "/.config")

-- Tier 4: $HOME/.config.
opts = fake({ HOME = HOME .. "/" })
check("T4 HOME fallback, trailing slash stripped", sls_profile.config_home(opts) == HOME .. "/.config")
check("T4 path", sls_profile.path("cache", opts) == HOME .. "/.config/SLSsteam/cache")

opts, scanned = fake({})
check("T4 nothing resolves", sls_profile.config_home(opts) == nil)
check("T4 no HOME skips /proc", not scanned())
check("T4 root nil", sls_profile.root(opts) == nil)
check("T4 path nil", sls_profile.path("config.yaml", opts) == nil)

-- Default /proc readers run against the live system; a HOME no process owns
-- keeps the result deterministic.
local live = sls_profile.config_home({
  getenv = function(key) if key == "HOME" then return "/nonexistent/sls-profile-test" end end,
})
check("L1 default readers fall back to HOME", live == "/nonexistent/sls-profile-test/.config")

if fails == 0 then io.write("\nALL TESTS OK\n") else io.write("\n" .. fails .. " FAILED\n"); os.exit(1) end
