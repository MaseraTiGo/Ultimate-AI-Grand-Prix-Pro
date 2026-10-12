--[[
  persona_loader.lua
  Driver Persona Management & Hot Reloading
]]

local M = {}

local _personaDB = {}
local _driverMappings = {}
local _defaultPersona = {
  name = "Pro Contender",
  base_aggression = 0.75,
  base_caution = 1.00,
  pressure_resist = 0.65,
  block_tendency = 0.75,
  decoy_tendency = 0.40,
  error_probability = 0.12
}

local function jsonDecode(str)
  if not str or str == "" then return nil end
  if JSON and JSON.parse then
    local ok, res = pcall(JSON.parse, str)
    if ok and res then return res end
  end
  if json and json.decode then
    local ok, res = pcall(json.decode, str)
    if ok and res then return res end
  end
  local okJson, libJson = pcall(require, "lib/driver/json")
  if okJson and libJson and libJson.parse then
    local ok, res = pcall(libJson.parse, str)
    if ok and res then return res end
  end
  if okJson and libJson and libJson.decode then
    local ok, res = pcall(libJson.decode, str)
    if ok and res then return res end
  end
  return nil
end

function M.init(configPath)
  local fileContent = nil
  if io and io.load then
    fileContent = io.load(configPath or "config/personas.json")
  else
    local f = io.open(configPath or "config/personas.json", "r")
    if f then
      fileContent = f:read("*a")
      f:close()
    end
  end

  if fileContent then
    local data = jsonDecode(fileContent)
    if data and data.personas then
      _personaDB = data.personas
      _driverMappings = data.driver_mappings or {}
      local defKey = data.default_persona or "balanced"
      if _personaDB[defKey] then
        _defaultPersona = _personaDB[defKey]
      end
    end
  end
end

local _manualOverrides = {} -- carIndex -> personaKey

--- Manually override persona for a car index (for Grid setup UI)
function M.setManualOverride(carIndex, personaKey)
  if not carIndex then return end
  if personaKey and _personaDB[personaKey] then
    _manualOverrides[carIndex] = personaKey
  else
    _manualOverrides[carIndex] = nil
  end
end

function M.getManualOverride(carIndex)
  return _manualOverrides[carIndex]
end

--- DJB2 string hash for procedural DNA seed generation
local function hashString(str)
  local hash = 5381
  for i = 1, #str do
    hash = ((hash * 33) + str:byte(i)) % 2147483647
  end
  return hash
end

--- Generate Continuous DNA Spectrum persona for unmapped drivers
--- 5-dimensional attributes: Smoothness, Pressure Resist, Tyre Management, Aggression, Rain/Wet Potential
---@param driverName string
---@param carIndex integer
---@return table persona
local function generateProceduralDNA(driverName, carIndex)
  local seed = hashString(driverName .. tostring(carIndex or 0))
  
  -- Pseudo-random normalized floats [0.0, 1.0] derived from hash shifts
  local r1 = ((seed % 1000) / 1000.0)
  local r2 = (((math.floor(seed / 1000)) % 1000) / 1000.0)
  local r3 = (((math.floor(seed / 1000000)) % 1000) / 1000.0)
  local r4 = (((math.floor(seed / 13)) % 1000) / 1000.0)

  local aggr = 0.50 + r1 * 0.45       -- 0.50 ~ 0.95
  local caution = 0.30 + (1.0 - r1) * 0.85 -- 0.30 ~ 1.15
  local resist = 0.40 + r2 * 0.55     -- 0.40 ~ 0.95
  local block = 0.50 + r3 * 0.45      -- 0.50 ~ 0.95
  local decoy = 0.20 + r4 * 0.65      -- 0.20 ~ 0.85
  local errProb = 0.04 + (1.0 - r2) * 0.16 -- 0.04 ~ 0.20

  return {
    name = "DNA: " .. (driverName ~= "" and driverName or ("Car #" .. carIndex)),
    is_procedural = true,
    base_aggression = aggr,
    base_caution = caution,
    pressure_resist = resist,
    block_tendency = block,
    decoy_tendency = decoy,
    error_probability = errProb,
    tyre_management = 0.50 + r3 * 0.50, -- 0.50 ~ 1.0
    -- Strategy integration traits (AI Pit Control PRO)
    fuel_saving_factor = 0.30 + (1.0 - r1) * 0.60, -- 0.30 ~ 0.90
    tyre_preservation = 0.35 + (1.0 - r2) * 0.55,  -- 0.35 ~ 0.90
    undercut_preference = 0.30 + r1 * 0.65,        -- 0.30 ~ 0.95
    overcut_preference = 0.20 + (1.0 - r1) * 0.60, -- 0.20 ~ 0.80
  }
end

--- Resolve persona for a specific car based on manual override, driver mapping, or procedural DNA
---@param carIndex integer
---@param driverName string
---@return table
function M.getPersonaForCar(carIndex, driverName)
  if carIndex and _manualOverrides[carIndex] then
    local pKey = _manualOverrides[carIndex]
    if _personaDB[pKey] then return _personaDB[pKey] end
  end

  local nameLower = (driverName or ""):lower()
  for key, personaKey in pairs(_driverMappings) do
    if nameLower:find(key, 1, true) then
      local p = _personaDB[personaKey]
      if p then return p end
    end
  end

  -- Generate unique procedural DNA spectrum for driver based on name seed
  return generateProceduralDNA(driverName or "", carIndex or 0)
end

function M.getAllPersonas()
  return _personaDB
end

return M
