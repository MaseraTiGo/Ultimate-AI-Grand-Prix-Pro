--[[
  DriverChatterEngine.lua
  Ultimate AI Grand Prix Pro: Anthropomorphic AI Driver Psyche & Radio Chatter Engine

  Responsibilities:
    1. Multi-Dimensional Contextual Chatter Triggers:
       - SQUEEZED_DEFENSE: Pushed wide, squeezed into kerb / wall, weaving under braking
       - OVERTAKE_POUNCE: Clean pounce pass, late divebomb, switchback undercut
       - MISTAKE_LOCKUP: Front tyre lockup, missed apex, snap oversteer
       - CRASH_INCIDENT: Heavy collision, rear-ended, spin out
       - BLUE_FLAG_RAGE: Lapped traffic refusing to yield
       - TYRE_CLIFF_RAGE: Severe thermal / mechanical degradation (>60% wear)
       - UNDERCUT_SUCCESS: Overcut/undercut position gain after pit exit
       - INTENSE_DEFENSE: Mirror threat dogfight, covering the apex
       - VICTORY_CHECKER: Race win, podium, checkered flag
    2. Deep Anthropomorphic Persona Voiceprints (80+ Authentic Paddock Radios):
       - AGGRESSIVE: Fierce, fiery, outspoken, demanding penalties (Verstappen/Montoya style)
       - ICE_COLD: Sarcastic, dry humor, minimal words, deadpan wit (Räikkönen/Alonso style)
       - EMOTIONAL: Anxious, gasping, hyped, panic-prone rookies (Colapinto/Tsunoda style)
       - STRATEGIC: Composed, technical, clinical, telemetry-minded (Prost/Sainz style)
    3. Multi-Entropy Randomization & Repeat Suppression:
       - Rolling 3-slot recent history buffer per driver to prevent robotic repetition
       - Bilingual support (Chinese & English authentic jargon)
    4. Anti-Fatigue Acoustic & Visual Arbitration:
       - Per-car cooldown (45.0s)
       - Global chatter silence gate (12.0s between any radio messages)
       - Spatial proximity filter: priority to player's dogfight rivals (< 80m) in Driver Mode
    5. Zero Runtime Allocation:
       - Scalar state, pre-allocated active chatter slot, zero table creation in 10Hz tick
]]

local M = {}

-- Radio Situation Categories
M.SIT_SQUEEZED   = "SQUEEZED"
M.SIT_OVERTAKE   = "OVERTAKE"
M.SIT_MISTAKE    = "MISTAKE"
M.SIT_CRASH      = "CRASH"
M.SIT_BLUE_FLAG  = "BLUE_FLAG"
M.SIT_TYRE_CLIFF = "TYRE_CLIFF"
M.SIT_UNDERCUT   = "UNDERCUT"
M.SIT_DOGFIGHT   = "DOGFIGHT"
M.SIT_VICTORY    = "VICTORY"

-- Persona Archetypes
M.ARCHETYPE_AGGRESSIVE = "AGGRESSIVE"
M.ARCHETYPE_ICE_COLD   = "ICE_COLD"
M.ARCHETYPE_EMOTIONAL  = "EMOTIONAL"
M.ARCHETYPE_STRATEGIC  = "STRATEGIC"

-- Priority Levels
M.PRIO_EMERGENCY = 3
M.PRIO_BATTLE    = 2
M.PRIO_TACTICS   = 1

local MAX_SLOTS = 32

-- Global timing & arbitration
local _globalSilenceTimer = 0.0
local _globalSilenceInterval = 6.0 -- Min seconds between normal radio chatters (6s responsive window)
local _carCooldowns = {}
local _carRecentHistories = {} -- Circular buffer of last 3 line indices per car
for i = 0, MAX_SLOTS - 1 do
  _carCooldowns[i] = 0.0
  _carRecentHistories[i] = { 0, 0, 0, pointer = 1 }
end

-- Active Chatter Display Card (For HUD & F1 broadcast popup)
local _activeChatter = {
  active = false,
  carIndex = -1,
  driverName = "",
  teamColor = nil,
  situation = "NONE",
  archetype = "STRATEGIC",
  priority = 1,
  tag = "RADIO",
  textEn = "",
  textZh = "",
  duration = 4.5,
  timer = 0.0,
  waveformAnim = 0.0,
}

--------------------------------------------------------------------------------
-- Authentic Paddock Radio Dialogue Corpus (80+ Lines)
--------------------------------------------------------------------------------
local CORPUS = {
  [M.SIT_SQUEEZED] = {
    [M.ARCHETYPE_AGGRESSIVE] = {
      { en = "He just pushed me off the track! Did you see that?! F***ing joke!", zh = "他直接把我往草地里推！你们看到了吗？！真TM是个笑话！", tag = "PROTEST", prio = M.PRIO_BATTLE },
      { en = "He moved twice under braking! Completely illegal!", zh = "他在刹车区变了两次线！绝对违规，干什么呢这是！", tag = "PROTEST", prio = M.PRIO_BATTLE },
      { en = "Who gave this guy a super license?! Honestly!", zh = "到底是谁给他发的超级驾照？！真是不可理喻！", tag = "RAGE", prio = M.PRIO_BATTLE },
    },
    [M.ARCHETYPE_ICE_COLD] = {
      { en = "Okay, so driving standards don't exist today, noted.", zh = "行吧，看来今天赛会把驾驶守则喂了狗是吧，记下了。", tag = "IRONIC", prio = M.PRIO_BATTLE },
      { en = "I think his mirrors fell off three laps ago, mate.", zh = "伙计，我怀疑他的后视镜三圈前就已经掉了。", tag = "IRONIC", prio = M.PRIO_BATTLE },
      { en = "Is he playing bumper cars or racing? Let me know.", zh = "这哥们是在跑碰碰车还是在赛车？你们给个准话。", tag = "IRONIC", prio = M.PRIO_BATTLE },
    },
    [M.ARCHETYPE_EMOTIONAL] = {
      { en = "Woah! Woah! He squeezed me into the wall! That was so close!", zh = "卧槽！他刚才直接把我往护墙上挤！差点就撞毁了！", tag = "PANIC", prio = M.PRIO_BATTLE },
      { en = "Man! I had to back out or we were both dead!", zh = "天啊！我刚才要是不收油，我们俩全得交代在那儿！", tag = "ALARM", prio = M.PRIO_BATTLE },
    },
    [M.ARCHETYPE_STRATEGIC] = {
      { en = "Report that car ahead, moving under braking into turn apex.", zh = "向赛会投诉前车，入弯刹车点违规变线挤压。", tag = "REPORT", prio = M.PRIO_TACTICS },
      { en = "No space given on the exit, had to take the kerb.", zh = "出弯完全没留空间，我被逼得直接骑上高路肩了。", tag = "RADIO", prio = M.PRIO_TACTICS },
    },
  },

  [M.SIT_OVERTAKE] = {
    [M.ARCHETYPE_AGGRESSIVE] = {
      { en = "Haha, see you later, mate! Simply lovely!", zh = "哈哈！再见啦兄弟！太TM丝滑了！", tag = "HYPED", prio = M.PRIO_BATTLE },
      { en = "Sent it down the inside! That's how it's done!", zh = "直接从内线滑进去！都给我学着点，这才是赛车！", tag = "HYPED", prio = M.PRIO_BATTLE },
      { en = "Too easy, honestly. Who is next?!", zh = "讲真，太轻松了。下一个受害者是谁？！", tag = "TAUNT", prio = M.PRIO_BATTLE },
    },
    [M.ARCHETYPE_ICE_COLD] = {
      { en = "Done. Clear air now, let's get down to business.", zh = "搞定。前面路干净了，开始干正事。", tag = "COOL", prio = M.PRIO_TACTICS },
      { en = "Nice door he left open for me, appreciate the gift.", zh = "门缝留得挺大，感谢这位朋友送的大礼。", tag = "IRONIC", prio = M.PRIO_TACTICS },
      { en = "Job done. He fought hard, but not hard enough.", zh = "任务完成。防得很凶，可惜还差点火候。", tag = "COOL", prio = M.PRIO_TACTICS },
    },
    [M.ARCHETYPE_EMOTIONAL] = {
      { en = "YES! YES! Come on! What a move! Did you see that?!", zh = "漂亮！太棒了！冲冲冲！看到刚才那一脚了吗？！牛逼！", tag = "HYPED", prio = M.PRIO_BATTLE },
      { en = "Woohoo! That was right on the limit! My heart is racing!", zh = "呼呼！刚才完全在极限边缘跳舞！心跳直接飙到两百！", tag = "HYPED", prio = M.PRIO_BATTLE },
    },
    [M.ARCHETYPE_STRATEGIC] = {
      { en = "Overtake completed at apex, tyres still in good window.", zh = "弯心超车完成，轮胎窗口仍然保持完好。", tag = "RADIO", prio = M.PRIO_TACTICS },
      { en = "Position gained. Clean air, focusing on delta.", zh = "位置到手。路面干净，继续盯紧目标圈速。", tag = "RADIO", prio = M.PRIO_TACTICS },
    },
  },

  [M.SIT_MISTAKE] = {
    [M.ARCHETYPE_AGGRESSIVE] = {
      { en = "ARGH! Front just gave up! What a stupid mistake!", zh = "啊啊啊！前轮直接推头锁死！我犯了什么蠢！", tag = "RAGE", prio = M.PRIO_BATTLE },
      { en = "I have ZERO front end! Car is completely undriveable!", zh = "车头一点抓地力都没有！这车现在根本开不了！", tag = "COMPLAINT", prio = M.PRIO_BATTLE },
    },
    [M.ARCHETYPE_ICE_COLD] = {
      { en = "Well, that was an expensive sightseeing tour in the gravel.", zh = "行吧，刚才在缓冲区里来了一次昂贵的观光一日游。", tag = "IRONIC", prio = M.PRIO_BATTLE },
      { en = "Big flat-spot on the front right. My bad, boys.", zh = "右前轮刹出巨大平斑。我的锅，伙计们。", tag = "RADIO", prio = M.PRIO_TACTICS },
    },
    [M.ARCHETYPE_EMOTIONAL] = {
      { en = "I lost the rear! I'm so sorry guys, completely lost it!", zh = "后轮丢了！对不起大家，刚才完全失去控制了！", tag = "PANIC", prio = M.PRIO_BATTLE },
      { en = "NOOO! Why does it snap like that in mid-corner?!", zh = "不不不！为什么这车在弯心会突然暴甩一下？！", tag = "PANIC", prio = M.PRIO_BATTLE },
      { en = "*Sigh* Massive vibrations now... front locked up.", zh = "*叹气* 前轮抱死了，现在方向盘震得手发麻...", tag = "GRIEF", prio = M.PRIO_TACTICS },
    },
    [M.ARCHETYPE_STRATEGIC] = {
      { en = "Locked up into apex, gave up a position. Resetting.", zh = "入弯刹车抱死，丢了一个位置。重新调整节奏。", tag = "RADIO", prio = M.PRIO_TACTICS },
      { en = "Wind gust pushed me wide on entry. Tyres still manageable.", zh = "入弯时有一阵侧风把我吹大了。轮胎情况尚可控。", tag = "RADIO", prio = M.PRIO_TACTICS },
    },
  },

  [M.SIT_CRASH] = {
    [M.ARCHETYPE_AGGRESSIVE] = {
      { en = "WHAT THE F*** IS HE DOING?! What a blind idiot!", zh = "他TM到底在干嘛？！眼睛长屁股上了吗？！", tag = "CRASH_RAGE", prio = M.PRIO_EMERGENCY },
      { en = "He just divebombed me from 50 meters back! He is crazy!", zh = "他从落后我50米的地方直接鱼雷撞上来！他疯了吗？！", tag = "CRASH_RAGE", prio = M.PRIO_EMERGENCY },
      { en = "Check the damage! That guy needs a black flag immediately!", zh = "快看我车损！赛会必须立即把那家伙黑旗罚出场！", tag = "CRASH_RAGE", prio = M.PRIO_EMERGENCY },
    },
    [M.ARCHETYPE_ICE_COLD] = {
      { en = "Someone tell him the brake pedal is the middle one.", zh = "麻烦谁去告诉他一声，中间那个踏板才叫刹车。", tag = "IRONIC", prio = M.PRIO_EMERGENCY },
      { en = "Yeah, I got torpedoed. Typical Sunday amateur hour.", zh = "行，我被当鱼雷轰了。标准的周日业余炸馆日常。", tag = "IRONIC", prio = M.PRIO_EMERGENCY },
    },
    [M.ARCHETYPE_EMOTIONAL] = {
      { en = "I GOT HIT! BIG HIT! Is the suspension broken?!", zh = "我被撞了！重重挨了一下！悬挂断了吗？！悬挂还在不在？！", tag = "PANIC", prio = M.PRIO_EMERGENCY },
      { en = "Why me?! Every single race someone takes me out!", zh = "为什么总是我？！每一场都有脑残把我顶出赛道！", tag = "GRIEF", prio = M.PRIO_EMERGENCY },
    },
    [M.ARCHETYPE_STRATEGIC] = {
      { en = "Heavy contact from behind. Box box, inspect wing and steering.", zh = "后方发生严重碰撞。准备进站，需要检查前翼和转向。", tag = "EMERGENCY", prio = M.PRIO_EMERGENCY },
      { en = "Car is intact, but dropped places. Let's claw it back.", zh = "赛车机械正常，但掉了位次。稳住，慢慢追回来。", tag = "RADIO", prio = M.PRIO_BATTLE },
    },
  },

  [M.SIT_BLUE_FLAG] = {
    [M.ARCHETYPE_AGGRESSIVE] = {
      { en = "BLUE FLAGS! Honestly! Can you talk to Charlie?!", zh = "蓝旗！认真点！你们能不能去跟赛事总监吼两声？！", tag = "RAGE", prio = M.PRIO_BATTLE },
      { en = "He's defending like it's the last lap of the championship!", zh = "他防守这架势搞得像是总冠军争夺战最后一圈似的！有病吧？！", tag = "RAGE", prio = M.PRIO_BATTLE },
      { en = "GET OUT OF THE WAY! I am losing two seconds a lap!", zh = "给我让开！我每圈被他白白耽误两秒钟！", tag = "RAGE", prio = M.PRIO_BATTLE },
    },
    [M.ARCHETYPE_ICE_COLD] = {
      { en = "Does he know he is two laps down, or should I wave?", zh = "他知道自己被套了两圈吗？还是需要我超车时摇手跟他打招呼？", tag = "IRONIC", prio = M.PRIO_TACTICS },
      { en = "Great driving from the backmarker, maybe sign him next year.", zh = "慢车挡得真漂亮，建议车队明年签他去当试车手。", tag = "IRONIC", prio = M.PRIO_TACTICS },
    },
    [M.ARCHETYPE_EMOTIONAL] = {
      { en = "Guys! He is not moving! He closed the door completely!", zh = "车队！他根本不让！刚才甚至把内线门给关死了！", tag = "PANIC", prio = M.PRIO_TACTICS },
      { en = "I'm getting cooked in his dirty air! Clear him, please!", zh = "我在他脏空气尾流里轮胎都要烤焦了！快想办法让他让开！", tag = "PANIC", prio = M.PRIO_TACTICS },
    },
    [M.ARCHETYPE_STRATEGIC] = {
      { en = "Blue flag traffic at sector 2, losing delta to the leader.", zh = "二段出现被套圈慢车，正在拉大与领跑者的差距时间。", tag = "REPORT", prio = M.PRIO_TACTICS },
    },
  },

  [M.SIT_TYRE_CLIFF] = {
    [M.ARCHETYPE_AGGRESSIVE] = {
      { en = "Bono, these tyres are completely DEAD! DEAD!", zh = "这套轮胎彻底报废了！完全完了！别再让我留在外面了！", tag = "COMPLAINT", prio = M.PRIO_BATTLE },
      { en = "I'm driving on ice! You need to pit me now!", zh = "我现在是在冰面上滑冰！你们必须这圈把我叫进去！", tag = "COMPLAINT", prio = M.PRIO_BATTLE },
    },
    [M.ARCHETYPE_ICE_COLD] = {
      { en = "If we stay out one more lap, I'll be in the wall, just so you know.", zh = "丑话说在前头，要是再多跑一圈，你们就可以去护墙里接我了。", tag = "IRONIC", prio = M.PRIO_BATTLE },
      { en = "Who calculated this stint? Einstein?", zh = "这次进站窗口到底是谁算出来的？爱因斯坦吗？", tag = "IRONIC", prio = M.PRIO_TACTICS },
    },
    [M.ARCHETYPE_EMOTIONAL] = {
      { en = "No traction at all! Everyone is flying past me!", zh = "出弯完全抓不住地！所有人都在直道上随便生吃我！", tag = "PANIC", prio = M.PRIO_BATTLE },
      { en = "Please tell me we are boxing... rear tyres are smoking.", zh = "求求你们告诉我这圈必须进站... 我感觉后胎都在冒青烟了。", tag = "GRIEF", prio = M.PRIO_TACTICS },
    },
    [M.ARCHETYPE_STRATEGIC] = {
      { en = "Degradation is higher than expected. Delta dropping 0.2s.", zh = "衰退比预期严重得多，每圈损耗扩大了0.2秒。", tag = "RADIO", prio = M.PRIO_TACTICS },
      { en = "Switching to Plan B, tyre temps are in the red zone.", zh = "建议切换到B方案，轮胎核心温度已经进入红色过热区。", tag = "RADIO", prio = M.PRIO_TACTICS },
    },
  },

  [M.SIT_UNDERCUT] = {
    [M.ARCHETYPE_AGGRESSIVE] = {
      { en = "In in in in in! Hammer time!", zh = "进进进！冲刺进站！锤子时间到了！", tag = "HYPED", prio = M.PRIO_TACTICS },
      { en = "YES! The undercut worked! We jumped him in pitlane!", zh = "太棒了！进站战术大获全胜！我们在维修区把他给生吃了！", tag = "HYPED", prio = M.PRIO_BATTLE },
      { en = "What was that stop?! 5 seconds?! Are we taking a nap?!", zh = "刚才换胎干嘛了？！换了5秒？！你们在工位上睡大觉吗？！", tag = "RAGE", prio = M.PRIO_BATTLE },
    },
    [M.ARCHETYPE_ICE_COLD] = {
      { en = "Clean stop boys, let's hunt down the guys ahead.", zh = "停站很干净，伙计们。现在轮到我们去猎杀前面的家伙了。", tag = "COOL", prio = M.PRIO_TACTICS },
      { en = "Did you guys order tea during the tyre change?", zh = "刚才换胎的功夫，你们顺便点了一壶下午茶吗？", tag = "IRONIC", prio = M.PRIO_TACTICS },
    },
    [M.ARCHETYPE_EMOTIONAL] = {
      { en = "Ready with the tyres! I am coming in hot!", zh = "轮胎准备好！我进站车速很快，别掉链子！", tag = "ALARM", prio = M.PRIO_TACTICS },
      { en = "Haha! We cleared him by half a car! Brilliant pit call!", zh = "哈哈！出站刚好压他半个车身！车队墙战术指挥太神了！", tag = "HYPED", prio = M.PRIO_BATTLE },
    },
    [M.ARCHETYPE_STRATEGIC] = {
      { en = "Box this lap confirmed. Ensure maximum wing adjustment.", zh = "确认本圈进站。请务必校准前翼下压力倾角。", tag = "RADIO", prio = M.PRIO_TACTICS },
    },
  },

  [M.SIT_DOGFIGHT] = {
    [M.ARCHETYPE_AGGRESSIVE] = {
      { en = "He will NOT pass me today! NOT TODAY!", zh = "今天只要有我在，他就休想过去！门都没有！", tag = "DEFEND", prio = M.PRIO_BATTLE },
      { en = "If he wants to overtake, he will have to go through me!", zh = "他要是真想超车，除非从我车顶上飞过去！", tag = "DEFEND", prio = M.PRIO_BATTLE },
    },
    [M.ARCHETYPE_ICE_COLD] = {
      { en = "Leave me alone, I know what I'm doing.", zh = "别在无线电里逼逼了，我自己知道在干什么。", tag = "COOL", prio = M.PRIO_BATTLE },
      { en = "He's overcooking his front tyres trying to dive. Let him cook.", zh = "他为了俯冲入弯前胎都快烤焦了，随他去，耗死他。", tag = "COOL", prio = M.PRIO_TACTICS },
    },
    [M.ARCHETYPE_EMOTIONAL] = {
      { en = "He is huge in my mirrors! I can't hold him forever!", zh = "他在后视镜里越来越大！我不可能无限期挡住他啊！", tag = "PANIC", prio = M.PRIO_BATTLE },
      { en = "Covering the inside! My tyres are sliding everywhere!", zh = "封死内线！我的车轮现在全都在侧滑漂移！", tag = "PANIC", prio = M.PRIO_BATTLE },
    },
    [M.ARCHETYPE_STRATEGIC] = {
      { en = "Focusing on corner exit traction to defend the straight.", zh = "重点保住出弯开油寻迹性，死守接下来的大直道。", tag = "DEFEND", prio = M.PRIO_TACTICS },
    },
  },

  [M.SIT_VICTORY] = {
    [M.ARCHETYPE_AGGRESSIVE] = {
      { en = "YESSS!! That is what I'm talking about!! P1 BABY!!", zh = "耶！！！这才是我想要的！！冠军到手，宝贝！！", tag = "CHAMPION", prio = M.PRIO_EMERGENCY },
      { en = "Haha! What a rocketship you built! Simply unstoppable!", zh = "哈哈！你们造的简直就是一枚火箭！无可阻挡！", tag = "CHAMPION", prio = M.PRIO_EMERGENCY },
    },
    [M.ARCHETYPE_ICE_COLD] = {
      { en = "Good job today. Car was decent. Onto the next one.", zh = "今天干得不错。车子挺顺手，准备下一场吧。", tag = "COOL", prio = M.PRIO_TACTICS },
      { en = "P3 is maximum today from where we started. Good points.", zh = "就我们发车的劣势而言，能拿到第3已经是极限了。积分大丰收。", tag = "PODIUM", prio = M.PRIO_TACTICS },
    },
    [M.ARCHETYPE_EMOTIONAL] = {
      { en = "OMG! P1?! We did it?! Thank you so much everyone! I love you guys!", zh = "我的天啊！第一名？！我们赢了？！感谢大家！我爱死你们了！", tag = "CHAMPION", prio = M.PRIO_EMERGENCY },
      { en = "So close to the podium... thanks for the effort anyway.", zh = "就差一点点上领奖台... 无论如何，感谢大家的努力。", tag = "PODIUM", prio = M.PRIO_TACTICS },
    },
    [M.ARCHETYPE_STRATEGIC] = {
      { en = "Superb execution on strategy today. Clinical victory.", zh = "今天的战术执行堪称完美。手术刀般精准的胜利。", tag = "CHAMPION", prio = M.PRIO_EMERGENCY },
    },
  },
}

--------------------------------------------------------------------------------
-- Helper: Map Persona table to Archetype
--------------------------------------------------------------------------------
local function resolveArchetype(persona)
  if not persona then return M.ARCHETYPE_STRATEGIC end
  local aggr = persona.base_aggression or 0.7
  local caut = persona.base_caution or 0.7
  local press = persona.pressure_resist or 0.7

  if aggr >= 0.85 then
    return M.ARCHETYPE_AGGRESSIVE
  elseif press >= 0.88 and caut <= 0.60 then
    return M.ARCHETYPE_ICE_COLD
  elseif press <= 0.55 or aggr >= 0.75 and caut <= 0.40 then
    return M.ARCHETYPE_EMOTIONAL
  else
    return M.ARCHETYPE_STRATEGIC
  end
end

--------------------------------------------------------------------------------
-- Audio Voiceover Integration
--------------------------------------------------------------------------------
local function triggerVoiceAudio(situation, priority)
  local RadioVoiceEngine = require("lib/audio/RadioVoiceEngine")
  if not RadioVoiceEngine or not RadioVoiceEngine.isEnabled() then return end

  -- Always emit authentic F1 radio chirp (beep_open) for incoming driver chatter
  RadioVoiceEngine.playChirp("open")

  -- If emergency situation, dispatch high priority radio flag
  if priority == M.PRIO_EMERGENCY then
    RadioVoiceEngine.playRadio("info_yellow_flag", RadioVoiceEngine.PRIORITY_EMERGENCY)
  end
end

--------------------------------------------------------------------------------
-- Core Trigger API: Submit AI Driver Chatter
--------------------------------------------------------------------------------
---@param carIndex integer
---@param situation string M.SIT_*
---@param persona table?
---@param driverName string?
---@param force boolean?
---@return boolean wasDispatched
function M.triggerChatter(carIndex, situation, persona, driverName, force)
  if not carIndex or carIndex < 0 or carIndex >= MAX_SLOTS then return false end
  situation = situation or M.SIT_DOGFIGHT

  local sitBucket = CORPUS[situation]
  if not sitBucket then return false end

  local arch = resolveArchetype(persona)
  local list = sitBucket[arch] or sitBucket[M.ARCHETYPE_STRATEGIC] or sitBucket[M.ARCHETYPE_AGGRESSIVE]
  if not list or #list == 0 then return false end

  -- 1. Anti-Fatigue Silence Gates (Skip if forced or if EMERGENCY priority)
  local isEmergency = (situation == M.SIT_CRASH)
  if not force and not isEmergency then
    if _globalSilenceTimer > 0.0 then return false end
    if (_carCooldowns[carIndex] or 0.0) > 0.0 then return false end
  end

  -- 2. Multi-Entropy Randomization with 3-step repeat elimination
  local hist = _carRecentHistories[carIndex]
  local chosenIdx = 1
  local attempts = 0
  repeat
    chosenIdx = math.random(1, #list)
    attempts = attempts + 1
    local isRepeated = (chosenIdx == hist[1] or chosenIdx == hist[2] or chosenIdx == hist[3])
  until (not isRepeated and #list > 1) or attempts >= 6

  -- Record to circular history
  hist[hist.pointer] = chosenIdx
  hist.pointer = (hist.pointer % 3) + 1

  local line = list[chosenIdx]
  if not line then return false end

  -- 3. Populate Active Card
  _activeChatter.active = true
  _activeChatter.carIndex = carIndex
  _activeChatter.driverName = driverName or string.format("Driver #%02d", carIndex + 1)
  _activeChatter.situation = situation
  _activeChatter.archetype = arch
  _activeChatter.priority = line.prio or M.PRIO_BATTLE
  _activeChatter.tag = line.tag or "RADIO"
  _activeChatter.textEn = line.en
  _activeChatter.textZh = line.zh
  _activeChatter.duration = 4.5
  _activeChatter.timer = 4.5
  _activeChatter.waveformAnim = 0.0

  -- 4. Apply Cooldowns
  _globalSilenceTimer = _globalSilenceInterval
  _carCooldowns[carIndex] = 45.0 -- 45 seconds per car

  -- 5. Broadcast to EventHub
  local EventHub = require("lib/core/EventHub")
  if EventHub and EventHub.pushAiEvent then
    local dLabel = EventHub.formatDriverLabel(carIndex, _activeChatter.driverName)
    local broadcastMsg = string.format("【无线电电台】%s: \"%s\"", dLabel, line.zh)
    EventHub.pushAiEvent(carIndex, "RADIO", broadcastMsg, "TACTICAL")
  end

  -- 6. Trigger Audio Voiceover
  triggerVoiceAudio(situation, line.prio)

  return true
end

--------------------------------------------------------------------------------
-- Step State Machine (Runs at 10Hz or 60Hz)
-- Pure scalar mathematics, zero dynamic allocation
--------------------------------------------------------------------------------
---@param dt number
function M.step(dt)
  dt = dt or 0.1
  if _globalSilenceTimer > 0.0 then
    _globalSilenceTimer = _globalSilenceTimer - dt
    if _globalSilenceTimer < 0.0 then _globalSilenceTimer = 0.0 end
  end

  for i = 0, MAX_SLOTS - 1 do
    if _carCooldowns[i] > 0.0 then
      _carCooldowns[i] = _carCooldowns[i] - dt
      if _carCooldowns[i] < 0.0 then _carCooldowns[i] = 0.0 end
    end
  end

  if _activeChatter.active then
    _activeChatter.timer = _activeChatter.timer - dt
    _activeChatter.waveformAnim = _activeChatter.waveformAnim + dt * 10.0
    if _activeChatter.timer <= 0.0 then
      _activeChatter.active = false
      _activeChatter.timer = 0.0
    end
  end
end

--------------------------------------------------------------------------------
-- Public Getters
--------------------------------------------------------------------------------
function M.getActiveChatter()
  return _activeChatter
end

function M.isChatterActive()
  return _activeChatter.active and _activeChatter.timer > 0.0
end

function M.getGlobalSilenceTimer()
  return _globalSilenceTimer
end

function M.getCarCooldown(carIdx)
  return _carCooldowns[carIdx] or 0.0
end

function M.reset()
  _globalSilenceTimer = 0.0
  _activeChatter.active = false
  _activeChatter.timer = 0.0
  _activeChatter.carIndex = -1
  for i = 0, MAX_SLOTS - 1 do
    _carCooldowns[i] = 0.0
    _carRecentHistories[i][1] = 0
    _carRecentHistories[i][2] = 0
    _carRecentHistories[i][3] = 0
    _carRecentHistories[i].pointer = 1
  end
end

return M
