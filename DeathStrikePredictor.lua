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
DSP.updateThrottle = 0.1  -- Update every 0.1 seconds
DSP.timeSinceLastUpdate = 0
DSP.healAbsorbEnabled = true  -- Enable heal absorb handling by default
local damageQueue = {}
local DAMAGE_BATCH_INTERVAL = 0.1 -- Process damage every 0.1 seconds
local damageUpdateTimer = 0

-- Forward declare all functions that are used by other functions
local UpdatePrediction
local FindPlayerHealthBar
local CreatePredictionOverlay
local ProcessDamageQueue
local CleanupFrames

-- Function to find the player's health bar
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

    return PlayerFrame.healthbar
end

-- Create the prediction overlay
CreatePredictionOverlay = function(healthBar)
    -- Create a frame to hold our textures that's parented to the health bar itself
    local container = CreateFrame("Frame", nil, healthBar)
    container:SetFrameStrata("BACKGROUND")
    container:SetAllPoints(healthBar)
    container:SetFrameLevel(healthBar:GetFrameLevel() + 2)
    
    local overlay = container:CreateTexture(nil, "ARTWORK", nil, 1)
    overlay:SetColorTexture(0, 1, 0, 0.3)
    overlay:SetBlendMode("ADD")
    overlay:SetHeight(healthBar:GetHeight())
    
    local line = container:CreateTexture(nil, "ARTWORK", nil, 2)
    line:SetColorTexture(1, 0.84, 0, 0.75)
    line:SetHeight(healthBar:GetHeight())
    line:SetWidth(1)
    line:SetBlendMode("ADD")

    -- Store the container reference
    DSP.container = container
    
    return overlay, line
end

-- Update the prediction display
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
    
    local healing = max(DSP.damagePool * DSP.baseHealing * DSP.mod * DSP.versMod, 
                       UnitHealthMax("player") * DSP.minHealing * DSP.mod * DSP.versMod)
    
    -- Add Dark Succor bonus if active
    if AuraUtil.FindAuraByName("Dark Succor", "player") then
        healing = healing + (UnitHealthMax("player") * 0.1)
    end
    
    -- Hide prediction if there's no valid healing amount
    if not healing or healing <= 0 then
        DSP.overlay:Hide()
        DSP.line:Hide()
        return
    end

    local healthBar = DSP.healthBar
    local width = healthBar:GetWidth()
    local maxHealth = UnitHealthMax("player")
    local health = UnitHealth("player")
    
    -- Handle heal absorbs
    if DSP.healAbsorbEnabled then
        health = max(0, health - UnitGetTotalHealAbsorbs("player"))
    end
    
    local startPos = (health / maxHealth) * width
    local endPos = ((health + healing) / maxHealth) * width
    
    -- Update overlay position
    DSP.overlay:ClearAllPoints()
    DSP.overlay:SetPoint("TOPLEFT", healthBar, "TOPLEFT", startPos, 0)
    DSP.overlay:SetWidth(max(1, endPos - startPos))
    DSP.overlay:Show()
    
    -- Update line position
    DSP.line:ClearAllPoints()
    DSP.line:SetPoint("TOPLEFT", healthBar, "TOPLEFT", endPos - 1, 0)
    DSP.line:Show()
end

-- Cleanup frames function
CleanupFrames = function()
    if DSP.container then
        DSP.container:Hide()
        DSP.container = nil
    end
    DSP.overlay = nil
    DSP.line = nil
    DSP.healthBar = nil
end

-- Process damage queue function
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

-- Talents that affect healing done/taken
DSP.talentMods = {
    [273953] = 0.15, -- Voracious
    [374277] = function() return GetSpecialization() == 1 and 0.05 or 0.6 end -- Improved Death Strike
}

-- Auras that modify healing done/taken (per stack)
DSP.auraMods = {
    [391459] =  0.05, -- Sanguine Ground
    [273947] =  0.08, -- Hemostasis
    [64844]  =  0.04, -- Divine Hymn
    [47788]  =  0.60, -- Guardian Spirit
    [72221]  =  0.05, -- Luck of the Draw
    [139068] =  0.05, -- Determination
    [55233]  = function() -- Vampiric Blood
        local name, _, count = AuraUtil.FindAuraByName("Improved Vampiric Blood", "player")
        local stacks = count or 0
        return 0.3 + stacks * 0.05
    end,
    [411241] = -0.25, -- Sarkareth: Void Claws
    [408429] = -0.25, -- Sarkareth: Void Slash
    [389684] = 0.04,  -- Close to the heart, need to add support for 2/2 talent?
    
    -- TWW Season 1 Debuffs
    [333492] = -0.30, -- Amarth: Necrotic Ichor
    [333489] = -0.50, -- Amarth: Necrotic Breath
    [461842] = -0.30, -- The Coaglamation: Oozing Smash
    [434705] = -0.10, -- Ulgrax the Devourer: Tenderized
    [458212] = -0.10, -- Ovi'nax mutated spiders: Necrotic Wound
}

-- Create main frame and register events
local frame = CreateFrame("Frame")

-- Set up frame update
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

-- Handle events
local function OnEvent(self, event, ...)
    if event == "PLAYER_REGEN_DISABLED" then
        DSP.inCombat = true
        UpdatePrediction()
    elseif event == "PLAYER_REGEN_ENABLED" then
        DSP.inCombat = false
        DSP.damagePool = 0  -- Clear damage pool when leaving combat
        UpdatePrediction()
    elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        local unit = ...
        if unit == "player" then
            UpdatePrediction()
        end
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" or event == "ADDON_LOADED" then
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
        
        -- Try to find the health bar
        DSP.healthBar = FindPlayerHealthBar()
        
        -- If we couldn't find it, set up multiple retries
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
        local _, subEvent, hideCaster, _, _, _, _, destGUID = CombatLogGetCurrentEventInfo()
        
        if destGUID == UnitGUID("player") and not hideCaster then
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
                -- Still set up removal timer for each damage instance
                C_Timer.After(5, function()
                    DSP.damagePool = DSP.damagePool - damage
                    UpdatePrediction()
                end)
            end
        end
    elseif event == "PLAYER_LOGOUT" then
        CleanupFrames()
    elseif event == "ADDON_LOADED" and ... == addonName then
        -- Register for disable callback
        frame:RegisterEvent("PLAYER_LOGOUT")
        -- Add disable callback for Ace3 if you're using it
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

-- Register events
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

-- Create slash command to toggle display and features
SLASH_DSP1 = "/dsp"
SlashCmdList["DSP"] = function(msg)
    if msg == "absorb" then
        DSP.healAbsorbEnabled = not DSP.healAbsorbEnabled
        print("Death Strike Predictor: Heal absorb handling " .. (DSP.healAbsorbEnabled and "enabled" or "disabled"))
        UpdatePrediction()
    else
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
