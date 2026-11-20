-- sls_profile.lua  (Linux overlay for luatools-moon)
--
-- Resolves the directory that holds SLSsteam/ (config.yaml, cache, manifests)
-- the same way the running Steam client sees it. The backend may run with a
-- different environment than Steam (for example without XDG_CONFIG_HOME), so
-- the Steam process environment is consulted before our own.
--
-- Resolution order:
--   1. SLSSTEAM_CONFIG_HOME
--   2. XDG_CONFIG_HOME of a running `steam` (preferred) or `steamwebhelper`
--      process that belongs to the same HOME
--   3. our own XDG_CONFIG_HOME
--   4. $HOME/.config
--
-- Every environment and /proc reader can be replaced through `opts`
-- (getenv, home, list_pids, read_comm, read_environ) so tests stay pure.

local sls_profile = {}

-- Looked up on each call so callers that swap os.getenv keep working.
local function default_getenv(key)
  return os.getenv(key)
end

local function read_all(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local data = file:read("*a")
  file:close()
  return data
end

local function default_list_pids()
  local pids = {}
  local ok_lfs, lfs = pcall(require, "lfs")
  if ok_lfs and pcall(function()
    for name in lfs.dir("/proc") do
      if name:match("^%d+$") then pids[#pids + 1] = name end
    end
  end) then
    return pids
  end
  pids = {}
  local pipe = io.popen("ls -1 /proc 2>/dev/null")
  if not pipe then return pids end
  for name in pipe:lines() do
    if name:match("^%d+$") then pids[#pids + 1] = name end
  end
  pipe:close()
  return pids
end

local function default_read_comm(pid)
  return read_all("/proc/" .. tostring(pid) .. "/comm")
end

local function default_read_environ(pid)
  return read_all("/proc/" .. tostring(pid) .. "/environ")
end

-- Strip trailing slashes; empty and non-string values count as unset.
local function normalize_dir(value)
  if type(value) ~= "string" then return nil end
  value = value:gsub("/+$", "")
  if value == "" then return nil end
  return value
end

-- Value of KEY in a NUL-separated /proc/<pid>/environ blob; nil when the key
-- is missing or empty.
function sls_profile.environ_value(blob, key)
  if type(blob) ~= "string" or type(key) ~= "string" or key == "" then
    return nil
  end
  local prefix = key .. "="
  local pos = 1
  while pos <= #blob do
    local stop = blob:find("\0", pos, true)
    local entry_end = (stop or (#blob + 1)) - 1
    if blob:sub(pos, pos + #prefix - 1) == prefix then
      local value = blob:sub(pos + #prefix, entry_end)
      if value == "" then return nil end
      return value
    end
    if not stop then break end
    pos = stop + 1
  end
  return nil
end

local function running_config_home(home, opts)
  local list_pids = opts.list_pids or default_list_pids
  local read_comm = opts.read_comm or default_read_comm
  local read_environ = opts.read_environ or default_read_environ
  local helper_xdg
  for _, pid in ipairs(list_pids() or {}) do
    local comm = (read_comm(pid) or ""):gsub("%s+$", "")
    if comm == "steam" or (comm == "steamwebhelper" and not helper_xdg) then
      local environ = read_environ(pid)
      if normalize_dir(sls_profile.environ_value(environ, "HOME")) == home then
        local xdg = normalize_dir(sls_profile.environ_value(environ, "XDG_CONFIG_HOME"))
        if xdg then
          if comm == "steam" then return xdg end
          helper_xdg = xdg
        end
      end
    end
  end
  return helper_xdg
end

-- Directory that contains SLSsteam/, or nil when nothing resolves.
function sls_profile.config_home(opts)
  opts = opts or {}
  local getenv = opts.getenv or default_getenv
  local explicit = normalize_dir(getenv("SLSSTEAM_CONFIG_HOME"))
  if explicit then return explicit end

  local home
  if opts.home then
    home = normalize_dir(opts.home())
  else
    home = normalize_dir(getenv("HOME"))
  end
  if home then
    local running = running_config_home(home, opts)
    if running then return running end
  end

  local xdg = normalize_dir(getenv("XDG_CONFIG_HOME"))
  if xdg then return xdg end
  if home then return home .. "/.config" end
  return nil
end

function sls_profile.root(opts)
  local base = sls_profile.config_home(opts)
  if not base then return nil end
  return base .. "/SLSsteam"
end

function sls_profile.path(subpath, opts)
  local root = sls_profile.root(opts)
  if not root then return nil end
  return root .. "/" .. subpath
end

return sls_profile
