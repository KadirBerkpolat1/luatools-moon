-- provision.lua  (Linux overlay for luatools-moon / AceSLS 64-bit graft)
--
-- The grafted AceSLS SLSsteam.so CONSUMES ~/.config/SLSsteam/cache/
-- picsbuffer_<appid>.bin: synthesizeDepotPlan reads depots/<id>/manifests/public
-- gid+size from it whenever 64-bit CUserAppManager::BuildDepotDependency returns
-- an empty vector for an unowned app. But, unlike upstream slsteam-moon, the
-- graft does NOT render that buffer (moon's AppInfoProvision layer was not
-- grafted). With no buffer the app has no depot section, Steam builds an empty
-- plan, and the Install dialog shows 0 B.
--
-- Upstream renders it inside the injected client (C++). Our graft lacks that, so
-- the add flow renders it here: fetch the app's PUBLIC appinfo from
-- api.steamcmd.net (the same PICS proxy the backend already uses for
-- GetSteamAppDetails) and write it as the KV1 text the .so parses. Called from
-- downloads._start_smart_records before the depot coverage handoff, so the
-- user's own "Add via LuaTools" click is all it takes and the collector and the
-- merge already see the public depots. Never overwrites an existing buffer (a
-- real provision wins).

local m_utils = require("utils")
local fs = require("fs")
local http_client = require("http_client")
local utils = require("plugin_utils")

local provision = {}

local function esc(value)
    return (tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"'))
end

-- Scalar -> VDF string. Integers stay integral (no "2036428360.0"); large depot
-- gids arrive as JSON strings and pass through untouched.
local function scalar(value)
    if type(value) == "boolean" then return value and "1" or "0" end
    if type(value) == "number" then
        if math.type and math.type(value) == "integer" then return string.format("%d", value) end
        if value == math.floor(value) and math.abs(value) < 1e15 then return string.format("%.0f", value) end
        return tostring(value)
    end
    return tostring(value)
end

-- Serialize a decoded-JSON appinfo node to Valve KV1 text. Objects become brace
-- blocks; string/number/boolean scalars become "key"<tab><tab>"value". JSON
-- nulls and other non-scalar leaves are skipped. Keys sorted for determinism
-- (the .so builds a map, so order is irrelevant to it). Underscore-prefixed API
-- metadata (_change_number, _sha, _missing_token) is dropped.
local function serialize(node, depth, out)
    local keys = {}
    for key in pairs(node) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local pad = string.rep("	", depth)
    for _, key in ipairs(keys) do
        local text_key = tostring(key)
        if text_key:sub(1, 1) ~= "_" then
            local value = node[key]
            if type(value) == "table" then
                out[#out + 1] = pad .. '"' .. esc(text_key) .. '"'
                out[#out + 1] = pad .. "{"
                serialize(value, depth + 1, out)
                out[#out + 1] = pad .. "}"
            elseif type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
                out[#out + 1] = pad .. '"' .. esc(text_key) .. '"		"' .. esc(scalar(value)) .. '"'
            end
        end
    end
end
provision._serialize_appinfo = function(body)
    local out = { '"appinfo"', "{" }
    serialize(body, 1, out)
    out[#out + 1] = "}"
    return table.concat(out, "\n") .. "\n"
end

-- Fetch one app's public appinfo from the PICS proxy. Two bounded attempts,
-- matching main.lua's fetch pattern. A 4xx means "no such app" -> stop early.
local function fetch_appinfo(appid)
    local endpoint = "https://api.steamcmd.net/v1/info/" .. tostring(appid)
    local response
    for _ = 1, 2 do
        local ok, resp = pcall(http_client.get, endpoint, { timeout = 10, max_bytes = 4 * 1024 * 1024 })
        if ok and type(resp) == "table" and resp.status == 200 and type(resp.body) == "string" then
            response = resp
            break
        end
        if ok and type(resp) == "table" and tonumber(resp.status)
            and resp.status >= 400 and resp.status < 500 then
            return nil, "appinfo unavailable (http " .. tostring(resp.status) .. ")"
        end
    end
    if not response then return nil, "appinfo request failed" end
    local payload = utils.decode_json(response.body)
    local data = type(payload) == "table" and type(payload.data) == "table"
        and payload.data[tostring(appid)] or nil
    if type(data) ~= "table" or type(data.depots) ~= "table" then
        return nil, "appinfo has no depots"
    end
    return data, tonumber(data._change_number) or 0
end

-- ensure_picsbuffer(appid, opts) -> true,"exists"|"written" | nil, error
-- opts (injectable for tests): home, exists, write_file, mkdir, fetch.
function provision.ensure_picsbuffer(appid, opts)
    opts = opts or {}
    local id = tonumber(appid)
    if not id or id <= 0 or id ~= math.floor(id) then return nil, "invalid appid" end
    id = math.floor(id)

    local home = opts.home or m_utils.getenv("HOME") or os.getenv("HOME") or ""
    if home == "" then return nil, "no HOME" end
    local exists = opts.exists or fs.exists
    local mkdir = opts.mkdir or fs.create_directories
    local write_file = opts.write_file or function(path, content)
        local ok, written = pcall(m_utils.write_file, path, content)
        return ok and written ~= false
    end

    local cache_dir = home .. "/.config/SLSsteam/cache"
    local bin_path = cache_dir .. "/picsbuffer_" .. id .. ".bin"
    local yaml_path = cache_dir .. "/picsbuffer_" .. id .. ".yaml"
    if exists(bin_path) then return true, "exists" end

    local fetch = opts.fetch or fetch_appinfo
    local data, change_number = fetch(id)
    if not data then return nil, change_number or "appinfo unavailable" end

    local body = {}
    for key, value in pairs(data) do
        if tostring(key):sub(1, 1) ~= "_" then body[key] = value end
    end
    if body.appid == nil then body.appid = tostring(id) end

    local text = provision._serialize_appinfo(body)
    mkdir(cache_dir)
    if not write_file(bin_path, text) then return nil, "failed to write picsbuffer" end
    write_file(yaml_path, table.concat({
        "appid: " .. id,
        "change_number: " .. tostring(tonumber(change_number) or 0),
        "wire_size: " .. tostring(#text),
        "sha_b64: AAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "normalized: true",
        "synthetic: false",
    }, "\n"))
    return true, "written"
end

return provision
