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
    overlay:SetColorTexture(0, 1, 0, 0.3)
    overlay:SetBlendMode("ADD")
    overlay:SetHeight(healthBar:GetHeight())
    
    local line = container:CreateTexture("DSPLine", "ARTWORK", nil, 2)
    line:SetColorTexture(1, 0.84, 0, 0.75)
    line:SetHeight(healthBar:GetHeight())
    line:SetWidth(1)
    line:SetBlendMode("ADD")

    -- Store the container reference
    DSP.container = container
    DSP.overlay = overlay
    DSP.line = line
    
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
frame:SetScript("OnUpdate", function(self, elapsed)
    DSP.timeSinceLastUpdate = DSP.timeSinceLastUpdate + elapsed
    damageUpdateTimer = damageUpdateTimer + elapsed

    -- Process damage queue on interval only in combat
    if DSP.inCombat and damageUpdateTimer >= DAMAGE_BATCH_INTERVAL then
        ProcessDamageQueue()
        damageUpdateTimer = 0
    end
    
    if DSP.timeSinceLastUpdate >= DSP.updateThrottle then
        UpdatePrediction()
        DSP.timeSinceLastUpdate = 0
    end
end)

local function OnEvent(self, event, ...)
    if event == "PLAYER_REGEN_DISABLED" then
        DSP.inCombat = true
        UpdatePrediction()

    elseif event == "PLAYER_REGEN_ENABLED" then
        DSP.inCombat = false
        DSP.damagePool = 0  -- Clear damage pool when leaving combat
        if DSP.container then DSP.container:Hide() end
        if DSP.overlay then DSP.overlay:Hide() end
        if DSP.line then DSP.line:Hide() end
        UpdatePrediction()

    elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        local unit = ...
        if unit == "player" then
            UpdatePrediction()
        end

    elseif event == "PLAYER_LOGIN"
        or event == "PLAYER_ENTERING_WORLD"
        or event == "ADDON_LOADED"
    then
        CleanupFrames()
        
        -- If SUF is loaded but not initialized, wait a bit
        if event == "ADDON_LOADED" and ... == "ShadowedUnitFrames" then
            C_Timer.After(1, function()
                DSP.healthBar = FindPlayerHealthBar()
                if DSP.healthBar then
                    DSP.overlay, DSP.line = CreatePredictionOverlay(DSP.healthBar)
                    UpdatePrediction()
                end
            end)
            return
        end
        
        DSP.healthBar = FindPlayerHealthBar()
        if not DSP.healthBar then
            local retryCount = 0
            local function retryFind()
                DSP.healthBar = FindPlayerHealthBar()
                if DSP.healthBar then
                    DSP.overlay, DSP.line = CreatePredictionOverlay(DSP.healthBar)
                    UpdatePrediction()
                elseif retryCount < 5 then
                    retryCount = retryCount + 1
                    C_Timer.After(1, retryFind)
                end
            end
            C_Timer.After(1, retryFind)
        else
            DSP.overlay, DSP.line = CreatePredictionOverlay(DSP.healthBar)
            UpdatePrediction()
        end

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, subEvent, _, sourceGUID, _, _, _, destGUID, _, _, _, spellID, spellName, _, amount, overhealing = CombatLogGetCurrentEventInfo()
        
        -- Not player's action => possibly damage to the player
        if sourceGUID ~= UnitGUID("player") then
            if destGUID == UnitGUID("player") then
                local damage
                if subEvent == "SWING_DAMAGE" then
                    damage = select(12, CombatLogGetCurrentEventInfo())
                elseif subEvent == "SPELL_ABSORBED" then
                    damage = select(22, CombatLogGetCurrentEventInfo()) or select(19, CombatLogGetCurrentEventInfo())
                elseif subEvent:match("_DAMAGE$") then
                    damage = select(15, CombatLogGetCurrentEventInfo())
                end
                
                if damage then
                    table.insert(damageQueue, damage)
                    C_Timer.After(5, function()
                        DSP.damagePool = DSP.damagePool - damage
                        UpdatePrediction()
                    end)
                end
            end
            return
        end
        
        -- Handle Death Strike events
        if spellID == DEATH_STRIKE_SPELL_ID then
            if subEvent == "SPELL_CAST_SUCCESS" then
                DSP.lastPredicted = GetPredictedHealing()
                
                -- Debug info only when debug mode is enabled
                if DSP.debugMode then
                    local maxHealth = UnitHealthMax("player")
                    local spec = GetSpecialization()
                    print("=== Death Strike Cast Debug ===")
                    print("Spec:", (spec == 1 and "Blood" or spec == 2 and "Frost" or "Unholy"))
                    print("Max Health:", maxHealth)
                    print("=== Damage Tracking ===")
                    print("Damage Pool:", DSP.damagePool)
                    local totalQueuedDamage = 0
                    for _, dmg in ipairs(damageQueue) do
                        totalQueuedDamage = totalQueuedDamage + dmg
                    end
                    print("Queued Damage:", totalQueuedDamage)
                    print("Total Recent Damage:", DSP.damagePool + totalQueuedDamage)
                    print("=== Healing Calculations ===")
                    print("Base Min Healing:", maxHealth * DSP.minHealing)
                    print("Base Pool Healing:", DSP.damagePool * DSP.baseHealing)
                    
                    -- Check Coagulating Blood
                    if spec == 1 then
                        local aura = C_UnitAuras.GetPlayerAuraBySpellID(463730)
                        if aura and aura.points and aura.points[1] then
                            print("Coagulating Blood Value:", aura.points[1])
                        else
                            print("Coagulating Blood: Not active")
                        end
                    end
                    
                    -- Print active modifiers
                    print("=== Active Modifiers ===")
                    print("Base Healing:", DSP.baseHealing, "(25% of damage taken)")
                    print("Min Healing:", DSP.minHealing, "(7% of max health)")
                    print("Base Mod:", DSP.mod)
                    print("Vers Mod:", DSP.versMod)
                    
                    -- Print active talents
                    print("=== Active Talents ===")
                    for tid, modifier in pairs(DSP.talentMods) do
                        if IsPlayerSpell(tid) then
                            if type(modifier) == "function" then
                                print("Talent", tid, ":", modifier())
                            else
                                print("Talent", tid, ":", modifier)
                            end
                        end
                    end
                    
                    -- Print active auras
                    print("=== Active Auras ===")
                    for aid, modifier in pairs(DSP.auraMods) do
                        local aura = C_UnitAuras.GetPlayerAuraBySpellID(aid)
                        if aura then
                            if type(modifier) == "function" then
                                print("Aura", aid, ":", modifier())
                            else
                                print("Aura", aid, ":", modifier)
                            end
                        end
                    end
                    
                    -- Print predicted healing
                    print("=== Final Healing ===")
                    print("Predicted Healing:", DSP.lastPredicted)
                    print("Percent of Max Health:", string.format("%.1f%%", (DSP.lastPredicted / maxHealth) * 100))
                end
                
            elseif subEvent == "SPELL_HEAL" then
                local overhealing = select(16, CombatLogGetCurrentEventInfo())
                local effectiveHealing = amount - (overhealing or 0)
                
                if DSP.debugMode then
                    print("=== Death Strike Healing Results ===")
                    print(string.format("Effective Healing: %d", effectiveHealing))
                    print(string.format("Overhealing: %d", overhealing or 0))
                    print(string.format("Total Healing: %d", amount))
                    
                    if DSP.lastPredicted then
                        local accuracy = (amount / DSP.lastPredicted) * 100
                        print(string.format("Prediction Accuracy: %.1f%%", accuracy))
                    end
                    print("------------------------")
                end
            end
        end

    elseif event == "PLAYER_LOGOUT" then
        CleanupFrames()
    elseif event == "ADDON_LOADED" and ... == addonName then
        -- Register for disable callback
        frame:RegisterEvent("PLAYER_LOGOUT")
        if type(DSP.OnDisable) == "function" then
            local oldDisable = DSP.OnDisable
            DSP.OnDisable = function(...)
                CleanupFrames()
                oldDisable(...)
            end
        end
    else
        UpdatePrediction()
    end
end

local events = {
    "PLAYER_LOGIN",
    "PLAYER_ENTERING_WORLD",
    "PLAYER_SPECIALIZATION_CHANGED",
    "PLAYER_TALENT_UPDATE",
    "UNIT_STATS",
    "COMBAT_LOG_EVENT_UNFILTERED",
    "ADDON_LOADED",
    "UI_SCALE_CHANGED",
    "DISPLAY_SIZE_CHANGED",
    "PLAYER_REGEN_ENABLED",
    "PLAYER_REGEN_DISABLED",
    "UNIT_HEALTH",
    "UNIT_MAXHEALTH"
}

for _, event in ipairs(events) do
    frame:RegisterEvent(event)
end

frame:SetScript("OnEvent", OnEvent)

-----------------------------------------------------------------------------
-- 10. Slash command to toggle display / debug
-----------------------------------------------------------------------------
SLASH_DSP1 = "/dsp"
SlashCmdList["DSP"] = function(msg)
    if msg == "absorb" then
        DSP.healAbsorbEnabled = not DSP.healAbsorbEnabled
        print("Death Strike Predictor: Heal absorb handling "
            .. (DSP.healAbsorbEnabled and "enabled" or "disabled"))
        UpdatePrediction()

    elseif msg == "debug" then
        DSP.debugMode = not DSP.debugMode
        print("Death Strike Predictor: Debug mode " .. (DSP.debugMode and "enabled" or "disabled"))
        if DSP.debugMode then
            local maxHealth = UnitHealthMax("player")
            local spec = GetSpecialization()
            print("=== Death Strike Predictor Debug ===")
            print("Spec:", (spec == 1 and "Blood" or spec == 2 and "Frost" or "Unholy"))
            print("Max Health:", maxHealth)
            print("=== Damage Tracking ===")
            print("Damage Pool:", DSP.damagePool)
            local totalQueuedDamage = 0
            for _, dmg in ipairs(damageQueue) do
                totalQueuedDamage = totalQueuedDamage + dmg
            end
            print("Queued Damage:", totalQueuedDamage)
            print("Total Recent Damage:", DSP.damagePool + totalQueuedDamage)
            print("=== Healing Calculations ===")
            print("Base Min Healing:", maxHealth * DSP.minHealing)
            print("Base Pool Healing:", DSP.damagePool * DSP.baseHealing)
            
            -- Check Coagulating Blood
            if spec == 1 then
                local aura = C_UnitAuras.GetPlayerAuraBySpellID(463730)
                if aura and aura.points and aura.points[1] then
                    print("Coagulating Blood Raw Value:", aura.points[1])
                else
                    print("Coagulating Blood: Not active")
                end
            end
            
            -- Check modifiers
            print("=== Active Modifiers ===")
            print("Base Healing:", DSP.baseHealing, "(25% of damage taken)")
            print("Min Healing:", DSP.minHealing, "(7% of max health)")
            print("Base Mod:", DSP.mod)
            print("Vers Mod:", DSP.versMod)
            
            -- Talents
            print("=== Active Talents ===")
            for spellID, modifier in pairs(DSP.talentMods) do
                if IsPlayerSpell(spellID) then
                    if type(modifier) == "function" then
                        print("Talent", spellID, ":", modifier())
                    else
                        print("Talent", spellID, ":", modifier)
                    end
                end
            end
            
            -- Auras
            print("=== Active Auras ===")
            for spellID, modifier in pairs(DSP.auraMods) do
                local aura = C_UnitAuras.GetPlayerAuraBySpellID(spellID)
                if aura then
                    if type(modifier) == "function" then
                        print("Aura", spellID, ":", modifier())
                    else
                        print("Aura", spellID, ":", modifier)
                    end
                end
            end
            
            -- Final healing prediction
            local healing = GetPredictedHealing()
            print("=== Final Healing ===")
            print("Predicted Healing:", healing)
            print("Percent of Max Health:", string.format("%.1f%%", (healing / maxHealth) * 100))
        end

    else
        -- Toggle the overlay
        if DSP.overlay and DSP.line then
            if DSP.overlay:IsShown() then
                DSP.overlay:Hide()
                DSP.line:Hide()
            else
                DSP.overlay:Show()
                DSP.line:Show()
                UpdatePrediction()
            end
        end
    end
end
