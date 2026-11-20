-- Broadcast Director SDK for Assetto Corsa (CSP)
-- Author: superD0ng / csp-sdk
-- Description: Headless Broadcast Director, Procedural Camera Synthesizer, Occlusion Check & Operator Dynamics
-- Version: 1.0.0

local M = {}

-- 1. 标准库与局部化加速 (Zero Allocation)
local min = math.min
local max = math.max
local abs = math.abs
local sqrt = math.sqrt
local sin = math.sin
local cos = math.cos
local rad = math.rad
local deg = math.deg
local tan = math.tan
local atan = math.atan
local exp = math.exp
local floor = math.floor
local format = string.format

-- 2. 常量与镜头风格枚举
M.Mode = {
  TELE = 'tele',          -- 长焦跟焦镜头 (Anchored Telephoto)
  CRANE = 'crane',        -- 高位吊臂镜头 (High Crane)
  KERB = 'kerb',          -- 路肩特写贴地镜头 (Low Kerb Apex)
  HELI2 = 'heli2',        -- 动态直升机跟踪 (Procedural Helicopter)
  TWOSHOT = 'twoshot',    -- 双车缠斗同框 (Two-Car Duel Composition)
  REARWING = 'rearwing',  -- 前车尾翼后视视角 (Leading Car Reverse Wing View)
  NOSE = 'nose',          -- 鼻翼低位向前视角 (Nosecone Forward)
  TCAM = 'tcam',          -- 车顶 T-Cam 视角 (Roll-hoop T-Cam)
  GRIDCAR = 'gridcar',    -- 发车格巡检环绕 (Grid Walk/Pan)
  DOLLY = 'dolly',        -- 赛道边缘平行推轨 (Parallel Track Dolly)
  CHASELOW = 'chaselow',  -- 低趴追击视角 (Low Dynamic Chase)
  POD = 'pod',            -- 侧箱后视/前视视角 (Sidepod Camera)
  ORBIT = 'orbit',        -- 慢速环绕运镜 (Hero Orbit)
  VISTA = 'vista'         -- 全景大广角 (Track Vista Panoramic)
}

M.StoryKind = {
  GRID = 'grid',
  START = 'start',
  BATTLE = 'battle',
  INCIDENT = 'incident',
  PIT = 'pit',
  SOLO = 'solo',
  FINISH = 'finish',
  LEADER = 'leader'
}

-- 纯向量数学加速层 (复用 vec3 / 内部标量，避免 gc)
local function v_set(out, x, y, z)
  out.x = x or 0
  out.y = y or 0
  out.z = z or 0
  return out
end

local function v_clone(v)
  return {x = v.x, y = v.y, z = v.z}
end

local function v_add(a, b)
  return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z}
end

local function v_sub(a, b)
  return {x = a.x - b.x, y = a.y - b.y, z = a.z - b.z}
end

local function v_mul(a, m)
  return {x = a.x * m, y = a.y * m, z = a.z * m}
end

local function v_dot(a, b)
  return a.x * b.x + a.y * b.y + a.z * b.z
end

local function v_len(a)
  return sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
end

local function v_norm(a)
  local l = v_len(a)
  if l < 1e-6 then return {x = 0, y = 0, z = 1} end
  return {x = a.x / l, y = a.y / l, z = a.z / l}
end

local function v_cross(a, b)
  return {
    x = a.y * b.z - a.z * b.y,
    y = a.z * b.x - a.x * b.z,
    z = a.x * b.y - a.y * b.x
  }
end

local function v_lerp(a, b, t)
  return {
    x = a.x + (b.x - a.x) * t,
    y = a.y + (b.y - a.y) * t,
    z = a.z + (b.z - a.z) * t
  }
end

local function clamp(v, minV, maxV)
  if v < minV then return minV end
  if v > maxV then return maxV end
  return v
end

local function damp(lambda, dt)
  return 1 - exp(-lambda * dt)
end

local UP_VEC = {x = 0, y = 1, z = 0}

-- 3. 摄像师人工手感预设 (Operator Dynamics Presets)
-- 包含 sway (云台呼吸晃动), vib (引擎/高速震颤), push (变焦阻尼), lr (横向提前量)
local OPERATOR_PROFILES = {
  tele = {lr = 0.30, dead = 0.12, push = 1.30, sway = 0.006, swf = 1.0},
  crane = {lr = 0.25, dead = 0.12, push = 1.20, sway = 0.005, swf = 0.7},
  kerb = {lr = 0.22, dead = 0.10, push = 1.15, sway = 0.005, swf = 1.2},
  vista = {lr = 0.20, dead = 0.15, push = 1.10, sway = 0.004, swf = 0.7},
  heli2 = {lr = 0.12, sway = 0.007, swf = 0.4},
  twoshot = {lr = 0.06, sway = 0.007, swf = 0.6},
  rearwing = {vib = 0.0035},
  pod = {vib = 0.0040},
  dolly = {lr = 0.18, sway = 0.003, swf = 0.8},
  chaselow = {lr = 0.05, sway = 0.006, swf = 0.9, vib = 0.0015},
  tcam = {vib = 0.0030},
  gridcar = {sway = 0.005, swf = 0.5},
  orbit = {sway = 0.004, swf = 0.5}
}

-- 4. 内部配置与状态表
local config = {
  maxRaysPerFrame = 40,
  enableRaycast = true,
  enableOperatorSway = true,
  strictAnchors = false,
  appName = "csp-sdk-director"
}

-- 射线预算管理
local _rayCount = 0
local _meshFinderInitialized = false
local _cachedMeshes = nil

local function resetRays()
  _rayCount = 0
end

-- CSP 物理光线追踪 (射线检测护墙/山体/建筑物)
local function raycastTrack(origin, dir, maxDist)
  if not config.enableRaycast or not physics or not physics.raycastTrack then
    return -1
  end
  if _rayCount >= config.maxRaysPerFrame then
    return -1
  end
  _rayCount = _rayCount + 1

  local oVec = (vec3 and vec3(origin.x, origin.y, origin.z)) or origin
  local dVec = (vec3 and vec3(dir.x, dir.y, dir.z)) or dir
  local ok, hitDist = pcall(physics.raycastTrack, oVec, dVec, maxDist)
  if not ok or type(hitDist) ~= "number" then
    return -1
  end
  return hitDist
end

-- 网格碰撞射线检测 (检测赛道建筑与障碍)
local function raycastMeshes(origin, dir, maxDist)
  if not config.enableRaycast or not ac or not ac.findMeshes or not render or not render.createRay then
    return -1
  end
  if not _meshFinderInitialized then
    _meshFinderInitialized = true
    pcall(function() _cachedMeshes = ac.findMeshes("?") end)
  end
  if not _cachedMeshes then return -1 end
  if _rayCount >= config.maxRaysPerFrame then return -1 end
  _rayCount = _rayCount + 1

  local oVec = (vec3 and vec3(origin.x, origin.y, origin.z)) or origin
  local dVec = (vec3 and vec3(dir.x, dir.y, dir.z)) or dir
  local ok, hitDist = pcall(function()
    return _cachedMeshes:raycast(render.createRay(oVec, dVec, maxDist))
  end)
  if not ok or type(hitDist) ~= "number" then
    return -1
  end
  return hitDist
end

-- 综合视线遮挡检测 (Line-of-Sight Occlusion Check)
-- 返回 true: 视线清晰无阻挡；false: 存在严重障碍物
function M.isLineOfSightClear(fromPos, toPos)
  local diff = v_sub(toPos, fromPos)
  local dist = v_len(diff)
  if dist < 1.0 then return true end

  local dir = v_mul(diff, 1.0 / dist)
  local hitTrack = raycastTrack(fromPos, dir, dist)
  if hitTrack >= 0 and hitTrack < (dist - 2.5) then
    return false
  end

  local hitMesh = raycastMeshes(fromPos, dir, dist)
  if hitMesh >= 0 and hitMesh < (dist - 2.5) then
    return false
  end

  return true
end

-- 地面/路面高度探测
local function getGroundHeight(pos)
  local skyPos = {x = pos.x, y = pos.y + 15.0, z = pos.z}
  local downDir = {x = 0, y = -1, z = 0}
  local hit = raycastTrack(skyPos, downDir, 35.0)
  if hit > 0 then
    return skyPos.y - hit
  end
  return pos.y
end

-- 提取车辆基础几何与物理快照 (Zero-GC 复用表)
local _carPool = {}
local function getCarSnapshot(carIndex)
  if not ac or not ac.getCar then return nil end
  local c = ac.getCar(carIndex)
  if not c then return nil end

  local rec = _carPool[carIndex]
  if not rec then
    rec = {
      pos = {x=0,y=0,z=0},
      look = {x=0,y=0,z=0},
      up = {x=0,y=0,z=0},
      side = {x=0,y=0,z=0},
      box = {x=0,y=0,z=0},
      base = {x=0,y=0,z=0},
      vel = {x=0,y=0,z=0},
      size = {x=1.9, y=1.3, z=4.6},
      speed = 0,
      spline = 0
    }
    _carPool[carIndex] = rec
  end

  local p = c.position
  if p then
    rec.pos.x, rec.pos.y, rec.pos.z = p.x or 0, p.y or 0, p.z or 0
  end

  local l = c.look
  if l then
    local lookNorm = v_norm({x=l.x or 0, y=l.y or 0, z=l.z or 1})
    rec.look.x, rec.look.y, rec.look.z = lookNorm.x, lookNorm.y, lookNorm.z
  else
    rec.look.x, rec.look.y, rec.look.z = 0, 0, 1
  end

  local u = c.up
  if u then
    local upNorm = v_norm({x=u.x or 0, y=u.y or 1, z=u.z or 0})
    rec.up.x, rec.up.y, rec.up.z = upNorm.x, upNorm.y, upNorm.z
  else
    rec.up.x, rec.up.y, rec.up.z = 0, 1, 0
  end

  local s = c.side
  if s then
    local sideNorm = v_norm({x=s.x or 1, y=s.y or 0, z=s.z or 0})
    rec.side.x, rec.side.y, rec.side.z = sideNorm.x, sideNorm.y, sideNorm.z
  else
    rec.side.x, rec.side.y, rec.side.z = 1, 0, 0
  end

  local v = c.velocity
  if v then
    rec.vel.x, rec.vel.y, rec.vel.z = v.x, v.y, v.z
  else
    rec.vel.x, rec.vel.y, rec.vel.z = 0, 0, 0
  end

  local sz = c.aabbSize
  if sz and sz.z and sz.z >= 2.0 then
    rec.size.x, rec.size.y, rec.size.z = sz.x, sz.y, sz.z
  else
    rec.size.x, rec.size.y, rec.size.z = 1.9, 1.3, 4.6
  end

  rec.speed = (c.speedKmh or 0) / 3.6
  rec.spline = c.splinePosition or 0

  -- 估算车辆物理中心 (Box) 与贴地基准 (Base)
  rec.box.x = rec.pos.x + rec.up.x * (rec.size.y * 0.5)
  rec.box.y = rec.pos.y + rec.up.y * (rec.size.y * 0.5)
  rec.box.z = rec.pos.z + rec.up.z * (rec.size.y * 0.5)

  rec.base.x = rec.pos.x
  rec.base.y = rec.pos.y
  rec.base.z = rec.pos.z

  return rec
end

-- 获取赛道坐标 (带安全 fallback)
local function getTrackWorldPos(spline)
  if not ac or not ac.trackProgressToWorldCoordinate then return nil end
  local ok, res = pcall(ac.trackProgressToWorldCoordinate, spline % 1.0)
  if not ok or not res then return nil end
  return {x = res.x, y = res.y, z = res.z}
end

-- 获取赛道半宽 (Half Width)
local function getTrackHalfWidth(spline)
  if not ac or not ac.getTrackAISplineSides then return 6.0 end
  local ok, res = pcall(ac.getTrackAISplineSides, spline % 1.0)
  if ok and res and res.x and res.x > 0 then
    return clamp(max(res.x, res.y), 3.5, 18.0)
  end
  return 6.0
end

-- 计算视场角 FOV 使得给定包围圈尺寸能够恰好充满画面
local function computeFramingFov(targetSpanMeters, distanceMeters)
  local dist = max(distanceMeters, 1.0)
  return deg(2.0 * atan(targetSpanMeters / (2.0 * dist)))
end

-- 5. 运镜合成器：10+ 种电影级机位生成逻辑
local PROCEDURAL_MODES = {}

-- (1) TELE: 赛道长焦追踪
PROCEDURAL_MODES.tele = {
  anchored = true,
  init = function(state, targetCar, otherCar, trackLen)
    local leadDist = clamp(targetCar.speed * 4.5, 70.0, 260.0)
    local targetSpline = (targetCar.spline + leadDist / trackLen) % 1.0
    local pCenter = getTrackWorldPos(targetSpline)
    local pAhead = getTrackWorldPos((targetSpline + 5.0 / trackLen) % 1.0)
    if not pCenter or not pAhead then return false end

    local trackDir = v_norm(v_sub(pAhead, pCenter))
    local trackNormal = v_norm(v_cross(trackDir, UP_VEC))
    local halfW = getTrackHalfWidth(targetSpline)

    local sideSign = state.sideSign or 1
    local camGround = v_add(pCenter, v_mul(trackNormal, sideSign * (halfW + 6.0)))
    local actualY = max(getGroundHeight(camGround), pCenter.y - 1.0) + 3.2
    local camPos = {x = camGround.x, y = actualY, z = camGround.z}

    -- 视线检测
    local aimTarget = v_add(targetCar.pos, {x = 0, y = 0.8, z = 0})
    if not M.isLineOfSightClear(camPos, aimTarget) then
      -- 换反侧重试
      camGround = v_add(pCenter, v_mul(trackNormal, -sideSign * (halfW + 6.0)))
      actualY = max(getGroundHeight(camGround), pCenter.y - 1.0) + 3.2
      camPos = {x = camGround.x, y = actualY, z = camGround.z}
      if not M.isLineOfSightClear(camPos, aimTarget) then
        return false
      end
      state.sideSign = -sideSign
    end

    state.camPos = camPos
    state.anchorSpline = targetSpline
    return true
  end,

  frame = function(state, targetCar, otherCar, dt)
    local aimPos = v_add(targetCar.pos, {x = 0, y = 0.7, z = 0})
    local span = 7.0

    -- 若有缠斗对手，视线兼顾双车中心
    if otherCar then
      local dToOther = v_len(v_sub(otherCar.pos, targetCar.pos))
      if dToOther < 45.0 then
        aimPos = v_lerp(aimPos, v_add(otherCar.pos, {x = 0, y = 0.7, z = 0}), 0.5)
        span = dToOther + 8.0
      end
    end

    state.aim = state.aim and v_lerp(state.aim, aimPos, damp(5.0, dt)) or aimPos
    local dist = v_len(v_sub(state.aim, state.camPos))
    local reqFov = clamp(computeFramingFov(span, dist) * 1.5, 6.0, 55.0)

    -- 判定是否超车/远离完成当前分镜
    local splineDiff = abs((targetCar.spline - state.anchorSpline + 0.5) % 1.0 - 0.5)
    local isPassed = (splineDiff * 3000.0 > 40.0) and (dist > 35.0)

    return state.camPos, state.aim, reqFov, dist, isPassed
  end
}

-- (2) KERB: 低角度弯心路肩特写
PROCEDURAL_MODES.kerb = {
  anchored = true,
  init = function(state, targetCar, otherCar, trackLen)
    local leadDist = clamp(targetCar.speed * 2.5, 45.0, 140.0)
    local targetSpline = (targetCar.spline + leadDist / trackLen) % 1.0
    local pCenter = getTrackWorldPos(targetSpline)
    local pAhead = getTrackWorldPos((targetSpline + 5.0 / trackLen) % 1.0)
    if not pCenter or not pAhead then return false end

    local trackDir = v_norm(v_sub(pAhead, pCenter))
    local trackNormal = v_norm(v_cross(trackDir, UP_VEC))
    local halfW = getTrackHalfWidth(targetSpline)

    local sideSign = state.sideSign or 1
    local camGround = v_add(pCenter, v_mul(trackNormal, sideSign * (halfW + 1.2)))
    local actualY = max(getGroundHeight(camGround), pCenter.y - 0.5) + 0.55
    local camPos = {x = camGround.x, y = actualY, z = camGround.z}

    local aimTarget = v_add(targetCar.pos, {x = 0, y = 0.5, z = 0})
    if not M.isLineOfSightClear(camPos, aimTarget) then
      return false
    end

    state.camPos = camPos
    state.anchorSpline = targetSpline
    return true
  end,

  frame = function(state, targetCar, otherCar, dt)
    local aimPos = v_add(targetCar.pos, {x = 0, y = 0.5, z = 0})
    state.aim = state.aim and v_lerp(state.aim, aimPos, damp(8.0, dt)) or aimPos
    local dist = v_len(v_sub(state.aim, state.camPos))
    local reqFov = clamp(computeFramingFov(8.5, dist) * 1.4, 20.0, 62.0)

    local splineDiff = abs((targetCar.spline - state.anchorSpline + 0.5) % 1.0 - 0.5)
    local isPassed = (splineDiff * 3000.0 > 15.0) and (dist > 18.0)

    return state.camPos, state.aim, reqFov, dist, isPassed
  end
}

-- (3) TWOSHOT: 双车对峙同框 (动态长焦压缩视角)
PROCEDURAL_MODES.twoshot = {
  anchored = false,
  init = function(state, targetCar, otherCar)
    if not otherCar then return false end
    local d = v_len(v_sub(otherCar.pos, targetCar.pos))
    return d < 35.0
  end,

  frame = function(state, targetCar, otherCar, dt)
    local leadCar = targetCar
    local followCar = otherCar
    local d = 25.0

    if otherCar then
      d = v_len(v_sub(otherCar.pos, targetCar.pos))
      local toOther = v_sub(otherCar.pos, targetCar.pos)
      if v_dot(toOther, targetCar.look) < 0 then
        -- otherCar 在后方
        leadCar = otherCar
        followCar = targetCar
      end
    end

    -- 镜头布置在后车侧后方斜上方
    local wantPos = v_add(v_add(leadCar.base, v_mul(leadCar.look, -10.0)), {x = 0, y = 3.5, z = 0})
    state.camPos = state.camPos and v_lerp(state.camPos, wantPos, damp(5.0, dt)) or wantPos

    -- 视线焦点处于两车中间偏前
    local aimPos = v_add(v_lerp(leadCar.base, followCar and followCar.base or leadCar.base, 0.4), {x = 0, y = 0.6, z = 0})
    state.aim = state.aim and v_lerp(state.aim, aimPos, damp(6.0, dt)) or aimPos

    local dist = v_len(v_sub(state.aim, state.camPos))
    local reqFov = clamp(computeFramingFov(min(d, 35.0) + 6.0, dist) * 1.3, 26.0, 60.0)

    local isDone = (d > 40.0)
    return state.camPos, state.aim, reqFov, dist, isDone
  end
}

-- (4) REARWING: 前车后视尾翼特写 (直击后车前脸)
PROCEDURAL_MODES.rearwing = {
  anchored = false,
  init = function(state, targetCar, otherCar)
    if not otherCar then return false end
    local diff = v_sub(otherCar.pos, targetCar.pos)
    local dist = v_len(diff)
    -- 对手必须在 25 米以内，且在车辆正后方方向
    return dist < 25.0 and v_dot(v_norm(diff), v_mul(targetCar.look, -1.0)) > 0.3
  end,

  frame = function(state, targetCar, otherCar, dt)
    -- 摄像机位置挂在前车尾翼上沿
    local camPos = v_add(v_add(targetCar.box, v_mul(targetCar.look, -(targetCar.size.z * 0.5 + 0.35))), v_mul(targetCar.up, targetCar.size.y * 0.35))
    local rearDir = v_mul(targetCar.look, -1.0)

    local aimDir = rearDir
    if otherCar then
      local toOther = v_norm(v_sub(otherCar.pos, camPos))
      if v_dot(toOther, rearDir) > 0.3 then
        aimDir = v_norm(v_lerp(rearDir, toOther, 0.6))
      end
    end

    local aimPos = v_add(camPos, v_mul(aimDir, 20.0))
    aimPos.y = aimPos.y - 0.7

    local isDone = false
    if otherCar and v_len(v_sub(otherCar.pos, targetCar.pos)) > 35.0 then
      isDone = true
    end

    return camPos, aimPos, 48.0, 20.0, isDone
  end
}

-- (5) HELI2: 动态直升机空中追拍
PROCEDURAL_MODES.heli2 = {
  anchored = false,
  init = function(state, targetCar, otherCar)
    state.t = 0
    return true
  end,

  frame = function(state, targetCar, otherCar, dt)
    state.t = (state.t or 0) + dt
    local lookFlat = v_norm({x = targetCar.look.x, y = 0, z = targetCar.look.z})
    local sideFlat = v_norm(v_cross(lookFlat, UP_VEC))

    local sideSign = state.sideSign or 1
    local sway = sin(state.t * 0.12 + sideSign) * 14.0

    -- 直升机布置在赛车斜后方 30 米、高度 24 米
    local wantPos = v_add(targetCar.pos, v_mul(lookFlat, -32.0 + targetCar.speed * 0.2))
    wantPos = v_add(wantPos, v_mul(sideFlat, sway + sideSign * 10.0))
    wantPos.y = wantPos.y + 24.0

    state.camPos = state.camPos and v_lerp(state.camPos, wantPos, damp(1.2, dt)) or wantPos
    local aimPos = targetCar.pos
    if otherCar and v_len(v_sub(otherCar.pos, targetCar.pos)) < 50.0 then
      aimPos = v_lerp(targetCar.pos, otherCar.pos, 0.5)
    end
    state.aim = state.aim and v_lerp(state.aim, aimPos, damp(4.0, dt)) or aimPos

    local dist = v_len(v_sub(state.aim, state.camPos))
    local fov = clamp(computeFramingFov(22.0, dist) * 1.3, 14.0, 48.0)

    return state.camPos, state.aim, fov, dist, false
  end
}

-- (6) CHASELOW: 低趴地面追逐镜头
PROCEDURAL_MODES.chaselow = {
  anchored = false,
  init = function(state, targetCar)
    return targetCar.speed > 6.0
  end,

  frame = function(state, targetCar, otherCar, dt)
    state.t = (state.t or 0) + dt
    local backDist = targetCar.size.z * 0.5 + 5.2
    local wantPos = v_add(v_add(targetCar.base, v_mul(targetCar.look, -backDist)), {x = 0, y = 0.75, z = 0})
    state.camPos = state.camPos and v_lerp(state.camPos, wantPos, damp(3.5, dt)) or wantPos

    local aimPos = v_add(v_add(targetCar.base, v_mul(targetCar.look, 3.0)), {x = 0, y = 0.5, z = 0})
    state.aim = state.aim and v_lerp(state.aim, aimPos, damp(7.0, dt)) or aimPos

    return state.camPos, state.aim, 52.0, backDist, false
  end
}

-- (7) TCAM: 顶部车载机位
PROCEDURAL_MODES.tcam = {
  anchored = false,
  init = function() return true end,
  frame = function(state, targetCar)
    local camPos = v_add(v_add(targetCar.box, v_mul(targetCar.up, targetCar.size.y * 0.5 + 0.25)), v_mul(targetCar.look, -0.3))
    local aimPos = v_add(v_add(camPos, v_mul(targetCar.look, 25.0)), v_mul(targetCar.up, -1.5))
    return camPos, aimPos, 60.0, 25.0, false
  end
}

-- 6. 摄像师人工手感注入 (Operator Dynamics Engine)
-- 模拟真人推焦迟滞、手持长焦云台微颤 (Zero GC)
local function applyOperatorDynamics(state, modeName, camPos, aimPos, fov, targetCar, dt)
  local profile = OPERATOR_PROFILES[modeName]
  if not profile or not config.enableOperatorSway then
    return aimPos, fov
  end

  state.op = state.op or {t = 0, fov = fov, p1 = 1.2, p2 = 2.4, p3 = 3.6}
  local op = state.op
  op.t = op.t + dt

  local diff = v_sub(aimPos, camPos)
  local dist = max(v_len(diff), 1.0)
  local lookDir = v_mul(diff, 1.0 / dist)
  local sideDir = v_norm(v_cross(lookDir, UP_VEC))
  local upDir = v_norm(v_cross(sideDir, lookDir))

  -- 1. 推焦死区与延迟变焦 (Push / Zoom Lag)
  if profile.dead then
    local ratio = fov / op.fov - 1.0
    if abs(ratio) > profile.dead then
      op.zooming = true
    end
    if op.zooming then
      op.fov = op.fov + (fov - op.fov) * damp(op.t < 1.5 and 1.8 or 2.5, dt)
      if abs(fov / op.fov - 1.0) < 0.02 then op.zooming = false end
    end
    fov = op.fov
  elseif profile.push then
    op.fov = op.fov + (fov - op.fov) * damp(1.6, dt)
    fov = op.fov
  end

  local frameSpan = dist * tan(rad(fov) * 0.5)

  -- 2. 云台手持呼吸微晃 (Sway)
  if profile.sway then
    local swf = profile.swf or 1.0
    local t = op.t
    local sX = sin(t * 0.37 * swf + op.p1) + 0.6 * sin(t * 0.83 * swf + op.p2)
    local sY = sin(t * 0.29 * swf + op.p3) + 0.5 * sin(t * 0.71 * swf + op.p1)
    local swayOffset = v_add(
      v_mul(sideDir, sX * profile.sway * frameSpan * 2.0),
      v_mul(upDir, sY * profile.sway * frameSpan * 1.4)
    )
    aimPos = v_add(aimPos, swayOffset)
  end

  -- 3. 高速震颤 (Vibration)
  if profile.vib and targetCar then
    local spdFactor = clamp(targetCar.speed / 50.0, 0.2, 1.4)
    local amp = profile.vib * spdFactor * frameSpan * 2.0
    local t = op.t
    local vX = sin(t * 41.0 + op.p1) * 0.6
    local vY = sin(t * 53.0 + op.p2) + 0.5 * sin(t * 97.0 + op.p3)
    local vibOffset = v_add(v_mul(sideDir, vX * amp), v_mul(upDir, vY * amp))
    aimPos = v_add(aimPos, vibOffset)
  end

  return aimPos, fov
end

-- 7. 模块主驱动器实例化
function M.new()
  return {
    grabHandle = nil,
    currentMode = nil,
    targetCar = 0,
    otherCar = nil,
    modeState = {},
    active = false,
    shotAge = 0,
    shotDuration = 8.0,
    overtakeHoldTimer = 0.0,
    occludedTimer = 0.0
  }
end

-- 初始化全局配置
function M.init(userConfig)
  if userConfig then
    for k, v in pairs(userConfig) do
      config[k] = v
    end
  end
end

-- 请求 CSP 原生接管自由相机 (ac.grabCamera)
local function acquireCameraGrab(director)
  if director.grabHandle and director.grabHandle:active() then
    return true
  end
  if not ac or not ac.grabCamera then
    return false, "ac.grabCamera unavailable"
  end
  local grab, err = ac.grabCamera(config.appName)
  if not grab then
    return false, err
  end
  director.grabHandle = grab
  return true
end

-- 释放自由相机控制权，无缝退回原生机位
function M.releaseCamera(director)
  if director.grabHandle then
    pcall(function() director.grabHandle:dispose() end)
    director.grabHandle = nil
  end
  director.active = false
  director.currentMode = nil
end

-- 开启新镜头 (Shot)
function M.startShot(director, modeName, targetCarIdx, otherCarIdx, trackLen)
  resetRays()
  local modeDef = PROCEDURAL_MODES[modeName]
  if not modeDef then
    return false, "unknown mode: " .. tostring(modeName)
  end

  local carA = getCarSnapshot(targetCarIdx)
  if not carA then
    return false, "target car invalid"
  end
  local carB = otherCarIdx and getCarSnapshot(otherCarIdx) or nil

  director.modeState = {
    sideSign = (targetCarIdx % 2 == 0) and 1 or -1,
    trackLen = trackLen or 3000.0
  }

  local ok = modeDef.init(director.modeState, carA, carB, trackLen or 3000.0)
  if not ok then
    return false, "mode init failed / blocked"
  end

  director.currentMode = modeName
  director.targetCar = targetCarIdx
  director.otherCar = otherCarIdx
  director.shotAge = 0
  director.occludedTimer = 0
  director.active = true
  return true
end

-- 通知超车动作发生：触发 Hold Until 画面保护
function M.notifyOvertake(director, holdSeconds)
  director.overtakeHoldTimer = max(director.overtakeHoldTimer, holdSeconds or 3.0)
end

-- 核心高频更新与相机驱动 (Zero GC Update Loop)
-- 返回状态: "ok" (平稳运行), "done" (镜头正常结束), "occluded" (被建筑/山体完全遮挡需要切镜), "fail" (异常)
function M.update(director, dt, trackLen)
  resetRays()
  if not director.active or not director.currentMode then
    return "inactive"
  end

  local safeDt = (type(dt) == "number" and dt > 0) and dt or 0.016
  director.shotAge = director.shotAge + safeDt

  if director.overtakeHoldTimer > 0 then
    director.overtakeHoldTimer = director.overtakeHoldTimer - safeDt
  end

  local modeDef = PROCEDURAL_MODES[director.currentMode]
  if not modeDef then
    M.releaseCamera(director)
    return "fail", "missing mode"
  end

  local carA = getCarSnapshot(director.targetCar)
  if not carA then
    M.releaseCamera(director)
    return "fail", "car missing"
  end
  local carB = director.otherCar and getCarSnapshot(director.otherCar) or nil

  -- 1. 获取机位理想位置与焦点
  local camPos, aimPos, fov, dist, isDone = modeDef.frame(director.modeState, carA, carB, safeDt)
  if not camPos or not aimPos then
    return "fail", "frame compute nil"
  end

  -- 2. 注入真实摄像师手感 (Sway & Vibration)
  aimPos, fov = applyOperatorDynamics(director.modeState, director.currentMode, camPos, aimPos, fov, carA, safeDt)

  -- 3. 视线阻挡保护 (Occlusion Check)
  local aimTarget = v_add(carA.pos, {x = 0, y = 0.8, z = 0})
  local clear = M.isLineOfSightClear(camPos, aimTarget)
  if not clear then
    director.occludedTimer = director.occludedTimer + safeDt
    -- 连续遮挡超过 0.6 秒，立即判定为遮挡，触发上层切镜
    if director.occludedTimer > 0.6 and director.shotAge > 0.8 and director.overtakeHoldTimer <= 0 then
      return "occluded"
    end
  else
    director.occludedTimer = 0.0
  end

  -- 4. 驱动 CSP 原生相机 (如果启用了 grabCamera)
  local okGrab = acquireCameraGrab(director)
  if okGrab and director.grabHandle then
    local grab = director.grabHandle
    local lookDir = v_norm(v_sub(aimPos, camPos))
    local sideDir = v_norm(v_cross(lookDir, UP_VEC))
    local upDir = v_norm(v_cross(sideDir, lookDir))

    grab.transform.position:set(camPos.x, camPos.y, camPos.z)
    grab.transform.look:set(lookDir.x, lookDir.y, lookDir.z)
    grab.transform.up:set(upDir.x, upDir.y, upDir.z)
    grab.fov = clamp(fov, 3.0, 75.0)
    grab.ownShare = 1.0
  end

  if isDone and director.overtakeHoldTimer <= 0 then
    return "done"
  end

  return "ok", camPos, aimPos, fov
end

return M
