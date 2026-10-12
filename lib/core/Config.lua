--[[
  lib/core/Config.lua
  Ultimate AI Grand Prix Pro - Unified Configuration & Validation Layer
]]

local Logger = require("lib/core/Logger")

local M = {}

local _defaultConfig = {
  general = {
    log_level = 2, -- INFO
    enable_smart_driver = true,
    enable_race_strategy = true,
    enable_safety_watchdog = true,
    enable_telemetry_bridge = true,
    enable_human_override = true,
  },
  strategy = {
    default_reserve_laps = 0.8,
    fuel_variation_enabled = true,
    fuel_variation_pct = 0.02,
    undercut_window_laps = 3,
    sc_fuel_discount = 0.45,
    traffic_density_penalty = 1.8,
    pit_lane_loss_sec = 22.0,
  },
  driver = {
    perception_delay_enabled = true,
    commitment_hold_sec = 0.7,
    car_width_corridor_margin = 0.40,
    breaking_tow_dist = 30.0,
    lift_and_coast_wear_threshold = 0.65,
    deep_sleep_enabled = true,
  }
}

local _currentConfig = {}

local function deepCopy(orig)
  local orig_type = type(orig)
  local copy
  if orig_type == 'table' then
    copy = {}
    for orig_key, orig_value in next, orig, nil do
      copy[deepCopy(orig_key)] = deepCopy(orig_value)
    end
  else
    copy = orig
  end
  return copy
end

function M.init(customPath)
  _currentConfig = deepCopy(_defaultConfig)
  -- If JSON config exists, load it
  local path = customPath or "config/settings.json"
  local content = nil
  if io and io.load then
    content = io.load(path)
  else
    local f = io.open(path, "r")
    if f then
      content = f:read("*a")
      f:close()
    end
  end

  if content and content ~= "" then
    local ok, parsed = pcall(function()
      if JSON and JSON.parse then return JSON.parse(content) end
      local okJ, j = pcall(require, "lib/json")
      if okJ and j and j.decode then return j.decode(content) end
      return nil
    end)
    if ok and type(parsed) == "table" then
      for section, vals in pairs(parsed) do
        if _currentConfig[section] and type(vals) == "table" then
          for k, v in pairs(vals) do
            _currentConfig[section][k] = v
          end
        else
          _currentConfig[section] = vals
        end
      end
      Logger.info("CONFIG", "Loaded custom configuration from " .. path)
    end
  else
    Logger.info("CONFIG", "Using default unified configuration")
  end
end

function M.get(section, key, defaultVal)
  if not section then return _currentConfig end
  if _currentConfig[section] then
    if key then
      local v = _currentConfig[section][key]
      if v ~= nil then return v end
      return defaultVal
    end
    return _currentConfig[section]
  end
  return defaultVal
end

function M.set(section, key, val)
  if not _currentConfig[section] then
    _currentConfig[section] = {}
  end
  _currentConfig[section][key] = val
end

return M
