--[[
  persona_loader.lua
  Driver Persona Management & Hot Reloading
]]

local M = {}

local _defaultPresets = {
  ["ice_man"] = {
    name = "The Ice Man",
    description = "Ultra calm under pressure, calculates apex with precision, optimal tyre management.",
    base_aggression = 0.65,
    base_caution = 1.20,
    pressure_resist = 0.90,
    mistake_resistance = 0.90,
    pressure_handling = 0.92,
    block_tendency = 0.70,
    decoy_tendency = 0.20,
    error_probability = 0.04,
    fuel_saving_factor = 0.85,
    tyre_preservation = 0.90,
    undercut_preference = 0.40,
    overcut_preference = 0.80,
    racecraft_iq = 0.85,
    patience = 0.80
  },
  ["aggressive_bull"] = {
    name = "Aggressive Bull",
    description = "Divebomber, hugs the bumper, dives into every gap, aggressive fuel burn & undercut seeker.",
    base_aggression = 0.95,
    base_caution = 0.25,
    pressure_resist = 0.40,
    mistake_resistance = 0.60,
    pressure_handling = 0.55,
    block_tendency = 0.95,
    decoy_tendency = 0.85,
    error_probability = 0.25,
    fuel_saving_factor = 0.30,
    tyre_preservation = 0.40,
    undercut_preference = 0.95,
    overcut_preference = 0.20,
    racecraft_iq = 0.75,
    patience = 0.30
  },
  ["tactical_master"] = {
    name = "Tactical Master",
    description = "Calculates defense lines, master of one-move blocking, balanced stint execution.",
    base_aggression = 0.80,
    base_caution = 0.80,
    pressure_resist = 0.75,
    mistake_resistance = 0.85,
    pressure_handling = 0.82,
    block_tendency = 0.90,
    decoy_tendency = 0.60,
    error_probability = 0.08,
    fuel_saving_factor = 0.75,
    tyre_preservation = 0.80,
    undercut_preference = 0.75,
    overcut_preference = 0.65,
    racecraft_iq = 0.90,
    patience = 0.75
  },
  ["gentleman_driver"] = {
    name = "Gentleman Driver",
    description = "Clean and respectful, gives generous racing room, conservative strategy.",
    base_aggression = 0.45,
    base_caution = 2.50,
    pressure_resist = 0.30,
    mistake_resistance = 0.40,
    pressure_handling = 0.35,
    block_tendency = 0.35,
    decoy_tendency = 0.05,
    error_probability = 0.35,
    fuel_saving_factor = 0.60,
    tyre_preservation = 0.65,
    undercut_preference = 0.30,
    overcut_preference = 0.50,
    racecraft_iq = 0.50,
    patience = 0.65
  },
  ["balanced"] = {
    name = "Pro Contender",
    description = "Solid GT3 / Prototype field contender, well rounded skills and strategic reactions.",
    base_aggression = 0.75,
    base_caution = 1.00,
    pressure_resist = 0.65,
    mistake_resistance = 0.70,
    pressure_handling = 0.70,
    block_tendency = 0.75,
    decoy_tendency = 0.40,
    error_probability = 0.12,
    fuel_saving_factor = 0.65,
    tyre_preservation = 0.70,
    undercut_preference = 0.60,
    overcut_preference = 0.60,
    racecraft_iq = 0.70,
    patience = 0.60
  },
  ["f1_verstappen"] = {
    name = "Max Verstappen",
    team = "Red Bull Racing",
    description = "Ruthless predator, master of late braking and positioning, near-zero errors.",
    base_aggression = 0.96,
    base_caution = 0.30,
    pressure_resist = 0.95,
    mistake_resistance = 0.95,
    pressure_handling = 0.95,
    block_tendency = 0.95,
    decoy_tendency = 0.85,
    error_probability = 0.03,
    fuel_saving_factor = 0.75,
    tyre_preservation = 0.88,
    undercut_preference = 0.92,
    overcut_preference = 0.40,
    racecraft_iq = 0.96,
    patience = 0.55
  },
  ["f1_hamilton"] = {
    name = "Lewis Hamilton",
    team = "Scuderia Ferrari",
    description = "Legendary race management, deadly switchback counter-puncher, pristine tyre whispering.",
    base_aggression = 0.84,
    base_caution = 0.75,
    pressure_resist = 0.96,
    mistake_resistance = 0.95,
    pressure_handling = 0.96,
    block_tendency = 0.85,
    decoy_tendency = 0.70,
    error_probability = 0.04,
    fuel_saving_factor = 0.88,
    tyre_preservation = 0.95,
    undercut_preference = 0.70,
    overcut_preference = 0.88,
    racecraft_iq = 0.97,
    patience = 0.88
  },
  ["f1_leclerc"] = {
    name = "Charles Leclerc",
    team = "Scuderia Ferrari",
    description = "Qualifying maestro, lightning reflex divebomber, passionate and high ceiling.",
    base_aggression = 0.90,
    base_caution = 0.55,
    pressure_resist = 0.78,
    mistake_resistance = 0.85,
    pressure_handling = 0.85,
    block_tendency = 0.88,
    decoy_tendency = 0.80,
    error_probability = 0.09,
    fuel_saving_factor = 0.65,
    tyre_preservation = 0.78,
    undercut_preference = 0.85,
    overcut_preference = 0.55,
    racecraft_iq = 0.90,
    patience = 0.60
  },
  ["f1_alonso"] = {
    name = "Fernando Alonso",
    team = "Aston Martin Aramco",
    description = "Grand master of racecraft, anticipates rivals 3 corners ahead, master of tire whispering & dirty line squeezing.",
    base_aggression = 0.88,
    base_caution = 0.68,
    pressure_resist = 0.92,
    mistake_resistance = 0.94,
    pressure_handling = 0.95,
    block_tendency = 0.96,
    decoy_tendency = 0.88,
    error_probability = 0.04,
    fuel_saving_factor = 0.82,
    tyre_preservation = 0.88,
    undercut_preference = 0.78,
    overcut_preference = 0.82,
    racecraft_iq = 0.98,
    patience = 0.85
  },
  ["f1_norris"] = {
    name = "Lando Norris",
    team = "McLaren F1 Team",
    description = "Super-fast pure pace, clinical overtakes, highly respectful yet relentless in DRS.",
    base_aggression = 0.86,
    base_caution = 0.65,
    pressure_resist = 0.80,
    mistake_resistance = 0.88,
    pressure_handling = 0.88,
    block_tendency = 0.82,
    decoy_tendency = 0.75,
    error_probability = 0.07,
    fuel_saving_factor = 0.72,
    tyre_preservation = 0.84,
    undercut_preference = 0.82,
    overcut_preference = 0.65,
    racecraft_iq = 0.89,
    patience = 0.72
  }
}

local _personaDB = {}
for k, v in pairs(_defaultPresets) do
  _personaDB[k] = v
end

local _driverMappings = {}
local _defaultPersona = _defaultPresets["balanced"]

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
  local candidatePaths = {
    configPath,
    "config/personas.json",
    "apps/lua/Ultimate-AI-Grand-Prix-Pro/config/personas.json",
    "apps/lua/Ultimate AI Grand Prix Pro/config/personas.json",
  }
  if __dirname then
    table.insert(candidatePaths, __dirname .. "/../../config/personas.json")
    table.insert(candidatePaths, __dirname .. "/config/personas.json")
  end
  if ac and ac.getFolder and ac.FolderID then
    local okRoot, root = pcall(ac.getFolder, ac.FolderID.Root)
    if okRoot and root then
      table.insert(candidatePaths, root .. "/apps/lua/Ultimate-AI-Grand-Prix-Pro/config/personas.json")
      table.insert(candidatePaths, root .. "/apps/lua/Ultimate AI Grand Prix Pro/config/personas.json")
    end
  end

  local fileContent = nil
  for _, path in ipairs(candidatePaths) do
    if path then
      if io and io.load then
        local ok, c = pcall(io.load, path)
        if ok and c and c ~= "" then
          fileContent = c
          break
        end
      end
      local f = io.open(path, "r")
      if f then
        fileContent = f:read("*a")
        f:close()
        if fileContent and fileContent ~= "" then
          break
        end
      end
    end
  end

  if fileContent then
    local data = jsonDecode(fileContent)
    if data and data.personas then
      for k, v in pairs(data.personas) do
        _personaDB[k] = v
      end
      if data.driver_mappings then
        _driverMappings = data.driver_mappings
      end
      -- Sanitize & normalize mistake resistance and pressure handling
      for _, p in pairs(_personaDB) do
        local mRes = p.mistake_resistance or p.pressure_resist or 0.70
        if mRes > 0.96 then mRes = 0.96 end -- Anti-immunization cap (strictly <= 0.96)
        if mRes < 0.0 then mRes = 0.0 end
        p.mistake_resistance = mRes

        local pHand = p.pressure_handling or p.pressure_resist or 0.70
        if pHand > 1.0 then pHand = 1.0 end
        if pHand < 0.0 then pHand = 0.0 end
        p.pressure_handling = pHand
      end
      local defKey = data.default_persona or "balanced"
      if _personaDB[defKey] then
        _defaultPersona = _personaDB[defKey]
      end
    end
  end
end

local _manualOverrides = {} -- carIndex -> personaKey
local _proceduralCache = {}  -- carIndex -> { driverName = string, persona = table }

--- Manually override persona for a car index (for Grid setup UI)
function M.setManualOverride(carIndex, personaKey)
  if not carIndex then return end
  _proceduralCache[carIndex] = nil
  if personaKey and personaKey ~= "" then
    _manualOverrides[carIndex] = personaKey
  else
    _manualOverrides[carIndex] = nil
  end
end

function M.getManualOverride(carIndex)
  return _manualOverrides[carIndex]
end

function M.reset()
  _manualOverrides = {}
  _proceduralCache = {}
end

--- Get the active persona key for a car (either manual override or mapped persona from personas.json)
---@param carIndex integer
---@param driverName string
---@return string|nil personaKey
function M.getActivePersonaKey(carIndex, driverName)
  if carIndex and _manualOverrides[carIndex] then
    return _manualOverrides[carIndex]
  end

  local nameLower = (driverName or ""):lower()
  for key, personaKey in pairs(_driverMappings) do
    if nameLower:find(key, 1, true) then
      return personaKey
    end
  end

  return nil
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
    mistake_resistance = math.min(0.95, math.max(0.35, 0.40 + r2 * 0.50)),
    pressure_handling = math.min(0.95, math.max(0.35, 0.35 + r4 * 0.55)),
    block_tendency = block,
    decoy_tendency = decoy,
    error_probability = errProb,
    tyre_management = 0.50 + r3 * 0.50, -- 0.50 ~ 1.0
    -- Strategy integration traits (AI Pit Control PRO)
    fuel_saving_factor = 0.30 + (1.0 - r1) * 0.60, -- 0.30 ~ 0.90
    tyre_preservation = 0.35 + (1.0 - r2) * 0.55,  -- 0.35 ~ 0.90
    undercut_preference = 0.30 + r1 * 0.65,        -- 0.30 ~ 0.95
    overcut_preference = 0.20 + (1.0 - r1) * 0.60, -- 0.20 ~ 0.80
    racecraft_iq = 0.50 + r3 * 0.45,               -- 0.50 ~ 0.95
    patience = 0.30 + r4 * 0.60,                   -- 0.30 ~ 0.90
  }
end

--- Resolve persona for a specific car based on manual override, driver mapping, or procedural DNA
---@param carIndex integer
---@param driverName string
---@return table
function M.getPersonaForCar(carIndex, driverName)
  if carIndex and _manualOverrides[carIndex] then
    local pKey = _manualOverrides[carIndex]
    local p = _personaDB[pKey] or _defaultPresets[pKey]
    if p then return p end
  end

  local nameLower = (driverName or ""):lower()
  for key, personaKey in pairs(_driverMappings) do
    if nameLower:find(key, 1, true) then
      local p = _personaDB[personaKey] or _defaultPresets[personaKey]
      if p then return p end
    end
  end

  -- Generate unique procedural DNA spectrum for driver based on name seed (with per-car caching)
  local dName = driverName or ""
  local idx = carIndex or 0
  local cached = _proceduralCache[idx]
  if cached and cached.driverName == dName then
    return cached.persona
  end

  local generated = generateProceduralDNA(dName, idx)
  _proceduralCache[idx] = { driverName = dName, persona = generated }
  return generated
end

function M.getAllPersonas()
  return _personaDB
end

return M
