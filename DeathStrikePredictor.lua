local addonName, DSP = ...

-- Check if player is a Death Knight
local _, class = UnitClass("player")
if class ~= "DEATHKNIGHT" then return end

-- Initialize variables
DSP.damagePool = 0
DSP.baseHealing = 0.25
DSP.minHealing = 0.07
DSP.mod = 1
DSP.versMod = 1
DSP.inCombat = false
DSP.updateThrottle = 0.1
DSP.timeSinceLastUpdate = 0
DSP.healAbsorbEnabled = true
DSP.trackHealing = false
DSP.debugMode = false  -- Add debug mode flag

local damageQueue = {}
local DEATH_STRIKE_SPELL_ID = 49998
local DAMAGE_BATCH_INTERVAL = 0.1 -- Process damage every 0.1 seconds
local damageUpdateTimer = 0

-----------------------------------------------------------------------------
-- Helper: Detect (or pretend to detect) Rune of Sanguination
-----------------------------------------------------------------------------
function DSP.HasRuneOfSanguination()
    -- TODO: Replace this with real detection code or a user toggle.
    -- For now, we'll just return true to *always* apply the bonus.
    return true
end

-----------------------------------------------------------------------------
-- Forward declare all functions that are used by other functions
-----------------------------------------------------------------------------
local UpdatePrediction
local FindPlayerHealthBar
local CreatePredictionOverlay
local ProcessDamageQueue
local CleanupFrames
local GetPredictedHealing

-----------------------------------------------------------------------------
-- 1. Get current predicted healing
-----------------------------------------------------------------------------
GetPredictedHealing = function()
    local maxHealth = UnitHealthMax("player")
    
    -- 1) Check Coagulating Blood aura (463730). If active, use that stored damage
    local cbAura = C_UnitAuras.GetPlayerAuraBySpellID(463730)
    local damagePoolToUse = DSP.damagePool
    if cbAura and cbAura.points and cbAura.points[1] then
        damagePoolToUse = cbAura.points[1]
    end
    
    -- 2) Calculate both potential healing sources
    local damagePortion = damagePoolToUse * DSP.baseHealing -- 25% of "effective" damage
    local healthPortion = maxHealth * DSP.minHealing        -- 7% of max health
    
    -- 3) Take the maximum of damage portion and health portion
    local healing = math.max(damagePortion, healthPortion)
    
    -- 4) Voracious (15%)
    if IsPlayerSpell(273953) then
        healing = healing * 1.15
    end
    
    -- 5) Hemostasis (8% per stack, up to 5 stacks)
    do
        local name, _, hemoCount = AuraUtil.FindAuraByName("Hemostasis", "player")
        if hemoCount and hemoCount > 0 then
            -- +8% per stack => multiplier = 1 + (stacks * 0.08)
            healing = healing * (1 + (hemoCount * 0.08))
        end
    end
    
    -- 6) Vampiric Blood (30% + 5% per Improved VB stack)
    local vbAura = C_UnitAuras.GetPlayerAuraBySpellID(55233)
    if vbAura then
        local _, _, vbCount = AuraUtil.FindAuraByName("Improved Vampiric Blood", "player")
        local stacks = vbCount or 0
        healing = healing * (1.3 + stacks * 0.05)
    end
    
    -- 7) Improved Death Strike (5% for Blood)
    if GetSpecialization() == 1 and IsPlayerSpell(374277) then
        healing = healing * 1.05
    end
    
    -- 8) Sanguine Ground (5%)
    if C_UnitAuras.GetPlayerAuraBySpellID(391459) then
        healing = healing * 1.05
    end

    -- 9) **Rune of Sanguination** (+up to 48% based on missing HP)
    if DSP.HasRuneOfSanguination() then
        local curHP = UnitHealth("player")
        local missingHPpct = 1 - (curHP / maxHealth)
        -- clamp so it doesn't exceed 1.0 if the game does something odd:
        if missingHPpct < 0 then missingHPpct = 0 end
        if missingHPpct > 1 then missingHPpct = 1 end
        
        -- up to +48% if completely missing HP
        local rosBonusMax = 0.48  -- 48%
        local rosMultiplier = 1 + (rosBonusMax * missingHPpct)
        healing = healing * rosMultiplier
    end
    
    -- 10) Apply versatility
    healing = healing * DSP.versMod
    
    -- 11) Dark Succor bonus if active (+10% max HP as a flat addition)
    if AuraUtil.FindAuraByName("Dark Succor", "player") then
        healing = healing + (maxHealth * 0.1)
    end
    
    return healing
end

-----------------------------------------------------------------------------
-- 2. Find the player's health bar
-----------------------------------------------------------------------------
FindPlayerHealthBar = function()
    -- Try to find SUF health bar by exact name from frame stack
    local healthBar = _G["SUFUnitplayer.healthBar"]
    if healthBar then
        return healthBar
    end
    
    -- Try alternative SUF frame paths
    local sufPlayer = _G["SUFUnitplayer"]
    if sufPlayer then
        healthBar = sufPlayer.healthBar or sufPlayer:GetChildren()
        if healthBar then
            return healthBar
        end
    end

    -- Fallback to default PlayerFrame
    return PlayerFrame.healthbar
end

-----------------------------------------------------------------------------
-- Helper functions
-----------------------------------------------------------------------------
local function UpdateColors()
    if DSP.overlay and DSP.db and DSP.db.profile then
        local oc = DSP.db.profile.overlayColor
        DSP.overlay:SetColorTexture(oc.r, oc.g, oc.b, oc.a)
    end
    if DSP.line and DSP.db and DSP.db.profile then
        local lc = DSP.db.profile.lineColor
        DSP.line:SetColorTexture(lc.r, lc.g, lc.b, lc.a)
    end
end

-----------------------------------------------------------------------------
-- 3. Create the prediction overlay
-----------------------------------------------------------------------------
CreatePredictionOverlay = function(healthBar)
    -- Clean up any existing frames first
    CleanupFrames()
    
    local container = CreateFrame("Frame", "DSPContainer", healthBar)
    container:SetFrameStrata("BACKGROUND")
    container:SetAllPoints(healthBar)
    container:SetFrameLevel(healthBar:GetFrameLevel() + 2)
    
    local overlay = container:CreateTexture("DSPOverlay", "ARTWORK", nil, 1)
    overlay:SetBlendMode("ADD")
    overlay:SetHeight(healthBar:GetHeight())
    
    local line = container:CreateTexture("DSPLine", "ARTWORK", nil, 2)
    line:SetHeight(healthBar:GetHeight())
    line:SetWidth(1)
    line:SetBlendMode("ADD")

    -- Store the container reference
    DSP.container = container
    DSP.overlay = overlay
    DSP.line = line
    
    -- Set initial colors
    UpdateColors()
    
    -- Hide everything initially
    container:Hide()
    overlay:Hide()
    line:Hide()
    
    return overlay, line
end

-----------------------------------------------------------------------------
-- 4. Update the prediction display
-----------------------------------------------------------------------------
UpdatePrediction = function()
    if not DSP.healthBar then
        DSP.healthBar = FindPlayerHealthBar()
        if not DSP.healthBar then
            return
        end
    end
    
    if not DSP.overlay or not DSP.line then
        if DSP.healthBar then
            DSP.overlay, DSP.line = CreatePredictionOverlay(DSP.healthBar)
        end
        if not DSP.overlay or not DSP.line then
            return
        end
    end

    -- Hide predictions if not in combat
    if not DSP.inCombat then
        if DSP.container then
            DSP.container:Hide()
        end
        if DSP.overlay then
            DSP.overlay:Hide()
        end
        if DSP.line then
            DSP.line:Hide()
        end
        return
    end

    -- Show container if we're in combat
    if DSP.container then
        DSP.container:Show()
    end
    
    local maxHealth = UnitHealthMax("player")
    local healing = GetPredictedHealing()
    
    -- Hide prediction if no valid healing amount
    if not healing or healing <= 0 then
        DSP.overlay:Hide()
        DSP.line:Hide()
        return
    end

    local healthBar = DSP.healthBar
    local width = healthBar:GetWidth()
    local health = UnitHealth("player")
    
    -- Handle heal absorbs
    if DSP.healAbsorbEnabled then
        health = math.max(0, health - UnitGetTotalHealAbsorbs("player"))
    end
    
    local startPos = (health / maxHealth) * width
    local endPos = ((health + healing) / maxHealth) * width
    
    -- Update overlay position
    DSP.overlay:ClearAllPoints()
    DSP.overlay:SetPoint("TOPLEFT", healthBar, "TOPLEFT", startPos, 0)
    DSP.overlay:SetWidth(math.max(1, endPos - startPos))
    DSP.overlay:Show()
    
    -- Update line position
    DSP.line:ClearAllPoints()
    DSP.line:SetPoint("TOPLEFT", healthBar, "TOPLEFT", endPos - 1, 0)
    DSP.line:Show()
end

-----------------------------------------------------------------------------
-- 5. Cleanup frames
-----------------------------------------------------------------------------
CleanupFrames = function()
    local oldContainer = _G["DSPContainer"]
    if oldContainer then
        oldContainer:Hide()
        oldContainer:SetParent(nil)
    end
    
    local oldOverlay = _G["DSPOverlay"]
    if oldOverlay then
        oldOverlay:Hide()
        oldOverlay:SetParent(nil)
    end
    
    local oldLine = _G["DSPLine"]
    if oldLine then
        oldLine:Hide()
        oldLine:SetParent(nil)
    end
    
    if DSP.container then
        DSP.container:Hide()
        DSP.container = nil
    end
    DSP.overlay = nil
    DSP.line = nil
    DSP.healthBar = nil
end

-----------------------------------------------------------------------------
-- 6. Process damage queue (rolling 5-sec damage)
-----------------------------------------------------------------------------
ProcessDamageQueue = function()
    local totalDamage = 0
    for _, damage in ipairs(damageQueue) do
        totalDamage = totalDamage + damage
    end
    if totalDamage > 0 then
        DSP.damagePool = DSP.damagePool + totalDamage
        UpdatePrediction()
    end
    wipe(damageQueue)
end

-----------------------------------------------------------------------------
-- 7. Talents for debug printing
-----------------------------------------------------------------------------
DSP.talentMods = {
    [273953] = 0.15, -- Voracious (+15%)
    [374277] = function() 
        return GetSpecialization() == 1 and 0.05 or 0.6 
    end, -- Improved Death Strike (+5% Blood, +60% Frost/Unholy)
    [454835] = 0.15, -- Osmosis: Anti-Magic Shell => +15% healing
    [273946] = function() -- Hemostasis (debug display)
        local name, _, count = AuraUtil.FindAuraByName("Hemostasis", "player")
        return count and (count * 0.08) or 0
    end
}

-----------------------------------------------------------------------------
-- 8. Auras for debug printing
-----------------------------------------------------------------------------
DSP.auraMods = {
    [391459] =  0.05,  -- Sanguine Ground (+5%)
    [64844]  =  0.04,  -- Divine Hymn (+4%)
    [47788]  =  0.60,  -- Guardian Spirit (+60%)
    [72221]  =  0.05,  -- Luck of the Draw (+5%)
    [139068] =  0.05,  -- Determination (+5%)
}

-----------------------------------------------------------------------------
-- 9. Main frame and event handling
-----------------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("UNIT_MAXHEALTH")
frame:RegisterEvent("UNIT_HEALTH")
frame:RegisterEvent("UNIT_HEAL_ABSORB_AMOUNT_CHANGED")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        DSP.healthBar = FindPlayerHealthBar()
        if DSP.healthBar then
            DSP.overlay, DSP.line = CreatePredictionOverlay(DSP.healthBar)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        DSP.healthBar = FindPlayerHealthBar()
        if DSP.healthBar then
            DSP.overlay, DSP.line = CreatePredictionOverlay(DSP.healthBar)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        DSP.inCombat = false
        UpdatePrediction()
    elseif event == "PLAYER_REGEN_DISABLED" then
        DSP.inCombat = true
        DSP.damagePool = 0
        wipe(damageQueue)
        UpdatePrediction()
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, subevent, _, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags, spellId, spellName, _, amount = CombatLogGetCurrentEventInfo()
        
        if destGUID == UnitGUID("player") and subevent == "SWING_DAMAGE" then
            amount = spellId -- In swing events, the damage is in the spellId parameter
            table.insert(damageQueue, amount)
        elseif destGUID == UnitGUID("player") and (subevent == "SPELL_DAMAGE" or subevent == "RANGE_DAMAGE") then
            table.insert(damageQueue, amount)
        end
    elseif event == "UNIT_MAXHEALTH" or event == "UNIT_HEALTH" or event == "UNIT_HEAL_ABSORB_AMOUNT_CHANGED" then
        local unit = ...
        if unit == "player" then
            UpdatePrediction()
        end
    end
end)

-- Update the damage pool every DAMAGE_BATCH_INTERVAL seconds
frame:SetScript("OnUpdate", function(self, elapsed)
    DSP.timeSinceLastUpdate = (DSP.timeSinceLastUpdate or 0) + elapsed
    if DSP.timeSinceLastUpdate >= DAMAGE_BATCH_INTERVAL then
        ProcessDamageQueue()
        DSP.timeSinceLastUpdate = 0
    end
end)

-- Register slash command
SLASH_DSP1 = "/dsp"
SlashCmdList["DSP"] = function(msg)
    if msg == "debug" then
        DSP.debugMode = not DSP.debugMode
        print("Death Strike Predictor debug mode:", DSP.debugMode and "ON" or "OFF")
    end
end

-- Initialize core variables
DSP.damagePool = 0
DSP.inCombat = false
DSP.timeSinceLastUpdate = 0
DSP.healAbsorbEnabled = true
