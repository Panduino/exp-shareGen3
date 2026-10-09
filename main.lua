return function(mod)
  if mod.generation ~= 3 then return end

  local Experience = require("src.core.game3.battle.experience")
  local Pokemon = require("src.core.game3.pokemon")
  local HeldItems = require("src.core.game3.battle.held_items")
  local ModRuntime = require("src.mods.Runtime")

  local originalAwardFoe = Experience.awardFoe
  if type(originalAwardFoe) ~= "function" then
    mod.log:error("Balanced EXP Share: Gen 3 EXP award function unavailable")
    return
  end

  local function alive(mon)
    return mon
      and (tonumber(mon.species or mon.speciesId) or 0) ~= 0
      and (tonumber(mon.hp) or 0) > 0
  end

  local function isEgg(mon)
    return mon and (mon.isEgg == true or mon.egg == true)
  end

  -- Passive awards should not amplify the trainer-scaling mod's high foe
  -- levels into disproportionate catch-up gains.
  local function catchupRate(monLevel, foeLevel)
    local diff = (tonumber(foeLevel) or 1) - (tonumber(monLevel) or 1)
    if diff >= 3 then return 0.12 end
    if diff >= 1 then return 0.08 end
    if diff == 0 then return 0.04 end
    if diff >= -2 then return 0.02 end
    return 0
  end

  local function participantSet(st, foe)
    local out = {}
    if foe and foe.participants and next(foe.participants) then
      for pi in pairs(foe.participants) do out[pi] = true end
    elseif st and st.player and st.player.mon and (tonumber(st.player.mon.hp) or 0) > 0 then
      out[st.player.partyIndex or 1] = true
    end
    return out
  end

  -- The vanilla held Exp. Share changes the participant pool itself.  This mod
  -- replaces that distribution rule, so hide Exp. Share items only while the
  -- engine computes the normal participant awards, then restore them exactly.
  local function vanillaParticipantsOnly(st, foe, opts)
    local saved = {}
    for i, mon in ipairs((st and st.playerParty) or {}) do
      if mon and HeldItems.effectOf(mon.item or mon.heldItem) == HeldItems.HOLD.EXP_SHARE then
        saved[#saved + 1] = {
          mon = mon,
          item = mon.item,
          heldItem = mon.heldItem,
        }
        mon.item = nil
        mon.heldItem = nil
      end
    end

    local ok, result = pcall(originalAwardFoe, st, foe, opts)

    for _, row in ipairs(saved) do
      row.mon.item = row.item
      row.mon.heldItem = row.heldItem
    end

    if not ok then error(result, 0) end
    return result
  end

  Experience.awardFoe = function(st, foe, opts)
    local awards = vanillaParticipantsOnly(st, foe, opts)
    if not st or not foe then return awards end

    local foeMon = foe.mon
    local foeSpecies = foe.species or (foeMon and (foeMon.species or foeMon.speciesId))
    local foeLevel = math.max(1, tonumber((foeMon and foeMon.level) or foe.level) or 1)
    local yield = Experience.expYield(foeSpecies)
    local base = math.floor((tonumber(yield) or 0) * math.min(foeLevel, 60) / 7)
    if base <= 0 then return awards end

    local participants = participantSet(st, foe)
    local isTrainer = opts and opts.trainer
    if isTrainer == nil then isTrainer = not st.wild end
    local friendshipCtx = { mapSec = Pokemon.currentMapSec(st.session) }

    for pi = 1, 6 do
      local mon = (st.playerParty or {})[pi]
      local level = tonumber(mon and mon.level) or 1
      if mon
        and not participants[pi]
        and alive(mon)
        and not isEgg(mon)
        and level < Experience.MAX_LEVEL
      then
        local rate = catchupRate(level, foeLevel)
        local amount = math.floor(base * rate)
        -- No trainer bonus for passive EXP. The active battler still gets
        -- the normal vanilla trainer award.

        if amount > 0 then
          -- Deliberately no EVs, Lucky Egg boost, or traded-Pokemon boost.
          local result = Experience.apply(mon, amount)

          for _ = 1, #(result.levels or {}) do
            Pokemon.adjustFriendship(mon, Pokemon.FRIENDSHIP_EVENT_GROW_LEVEL, friendshipCtx)
          end

          if ModRuntime.wants("battle.exp_gained") then
            ModRuntime.emit("battle.exp_gained", {
              battle = st,
              mon = mon,
              gained = result.gained,
              levels = result.levels,
              index = pi,
              battler = nil,
              battlerId = 0,
              passive = true,
            })
          end

          awards[#awards + 1] = {
            mon = mon,
            partyIndex = pi,
            battler = nil,
            expGetterBattlerId = 0,
            amount = amount,
            boosted = false,
            passive = true,
            result = result,
          }
        end
      end
    end

    return awards
  end

  mod.log:info("Balanced EXP Share active")
end
