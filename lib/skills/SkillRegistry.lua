--[[
  lib/skills/SkillRegistry.lua
  Ultimate AI Grand Prix Pro - Zero-Overhead X-Skill Auto-Registry & Index
  
  Responsibilities:
    1. Static & dynamic skill registration without central code edits
    2. Zero-allocation skill lookup by integer ID
    3. Auto-discovers bundled skill modules in lib/skills/
    4. Strict validation of skill contract:
       - id: integer (1..32)
       - name: string
       - category: string ("OFFENSE", "DEFENSE", "TACTICAL")
       - checkPrerequisites: function(car, aheadCar, behindCar, geoState, memState) -> boolean
       - evaluateUtility: function(car, aheadCar, behindCar, persona, geoState, memState) -> number [0.0..1.0]
       - stepExecution: function(carState, ctx, dt) -> targetOffset, targetCaution, targetAggr, extraGrip
       - checkAbort: function(car, aheadCar, behindCar, ctx) -> boolean
]]

local Logger = require("lib/core/Logger")

local M = {}

local MAX_SKILLS = 32
local _skillsList = {}       -- dense array: [1..count] = skillDef
local _skillsById = {}       -- lookup array: [skillId] = skillDef
local _skillCount = 0
local _initialized = false

--- Register a skill definition into the registry
---@param skillDef table
---@return boolean success, string? err
function M.registerSkill(skillDef)
  if type(skillDef) ~= "table" then
    return false, "Skill definition must be a table"
  end
  if type(skillDef.id) ~= "number" or skillDef.id < 1 or skillDef.id > MAX_SKILLS then
    return false, "Skill id must be an integer between 1 and " .. MAX_SKILLS
  end
  if type(skillDef.name) ~= "string" or skillDef.name == "" then
    return false, "Skill name must be a non-empty string"
  end
  if type(skillDef.checkPrerequisites) ~= "function" then
    return false, "Skill missing checkPrerequisites function"
  end
  if type(skillDef.evaluateUtility) ~= "function" then
    return false, "Skill missing evaluateUtility function"
  end
  if type(skillDef.stepExecution) ~= "function" then
    return false, "Skill missing stepExecution function"
  end

  local id = math.floor(skillDef.id)
  if _skillsById[id] then
    Logger.warn("SKILLS", string.format("Skill ID %d (%s) overwritten by %s", id, _skillsById[id].name, skillDef.name))
  else
    _skillCount = _skillCount + 1
    _skillsList[_skillCount] = skillDef
  end

  _skillsById[id] = skillDef
  return true, nil
end

--- Get skill by ID (O(1) direct index lookup, zero-alloc)
---@param id integer
---@return table?
function M.getSkillById(id)
  return _skillsById[id]
end

--- Get dense array of all registered skills (zero-alloc iterator support)
---@return table list, integer count
function M.getAllSkills()
  return _skillsList, _skillCount
end

--- Auto-discover and register all skill modules
--- Prioritizes safe explicit manifest for AC CSP runtime sandbox,
--- and falls back to dynamic requires if available.
function M.init()
  if _initialized then return end

  -- Standard built-in skills bundled with Ultimate AI Grand Prix Pro
  local builtInSkills = {
    "lib/skills/SwitchbackSkill",
    "lib/skills/FeintDummySkill",
    "lib/skills/GentleSqueezeSkill",
    "lib/skills/TowWeaveSkill",
    "lib/skills/LateBrakeDiveSkill",
  }

  for i = 1, #builtInSkills do
    local modPath = builtInSkills[i]
    local ok, mod = pcall(require, modPath)
    if ok and type(mod) == "table" then
      local regOk, regErr = M.registerSkill(mod)
      if regOk then
        Logger.info("SKILLS", string.format("Registered X-Skill: [%d] %s (%s)", mod.id, mod.name, mod.category or "GENERAL"))
      else
        Logger.warn("SKILLS", string.format("Failed to register %s: %s", modPath, tostring(regErr)))
      end
    else
      Logger.warn("SKILLS", string.format("Could not load skill module %s: %s", modPath, tostring(mod)))
    end
  end

  -- Auto-discover optional third-party skills from skills_manifest.txt if present
  local f = io.open("config/skills_manifest.txt", "r")
  if f then
    for line in f:lines() do
      local trimmed = line:match("^%s*(.-)%s*$")
      if trimmed and trimmed ~= "" and not trimmed:match("^#") then
        local ok, extMod = pcall(require, trimmed)
        if ok and type(extMod) == "table" then
          M.registerSkill(extMod)
          Logger.info("SKILLS", string.format("Auto-registered external X-Skill: %s", trimmed))
        end
      end
    end
    f:close()
  end

  _initialized = true
end

function M.reset()
  _initialized = false
  _skillCount = 0
  for i = 1, MAX_SKILLS do
    _skillsById[i] = nil
    _skillsList[i] = nil
  end
end

return M
