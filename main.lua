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

  -- Every eligible party member gets EXP based only on its level relative
  -- to the rest of the party, never on whether it participated.
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

    -- Suppress vanilla EXP while retaining battle cleanup and awards.
    -- EXP is distributed uniformly below, using one shared formula.
    local originalApply = Experience.apply
    Experience.apply = function(mon, amount, ...)
      return originalApply(mon, 0, ...)
    end
    local ok, result = pcall(originalAwardFoe, st, foe, opts)
    Experience.apply = originalApply

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
    local base = math.floor((tonumber(yield) or 0) * foeLevel / 7)
    if base <= 0 then return awards end

    local isTrainer = opts and opts.trainer
    if isTrainer == nil then isTrainer = not st.wild end
    local friendshipCtx = { mapSec = Pokemon.currentMapSec(st.session) }

    local lowest, highest = 100, 1
    for _, mon in ipairs(st.playerParty or {}) do
      if alive(mon) and not isEgg(mon) and (tonumber(mon.level) or 100) < Experience.MAX_LEVEL then
        local level = tonumber(mon.level) or 1
        lowest = math.min(lowest, level)
        highest = math.max(highest, level)
      end
    end

    for pi = 1, 6 do
      local mon = (st.playerParty or {})[pi]
      local level = tonumber(mon and mon.level) or 1
      if mon
        and alive(mon)
        and not isEgg(mon)
        and level < Experience.MAX_LEVEL
      then
        -- Lowest-level member gets 100% of base EXP, highest gets 15%.
        -- Equal-level parties receive an identical 60% share each.
        local rate = 0.60
        if highest > lowest then
          rate = 1.0 - 0.85 * (level - lowest) / (highest - lowest)
        end
        local amount = math.floor(base * rate)
        if isTrainer then amount = math.floor(amount * 1.5) end

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
