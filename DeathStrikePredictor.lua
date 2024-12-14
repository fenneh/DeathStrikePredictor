local addonName, DSP = ...

-- Create main frame and register events
local frame = CreateFrame("Frame")

-- Initialize variables
DSP.damagePool = 0
DSP.baseHealing = 0.25
DSP.minHealing = 0.07
DSP.mod = 1
DSP.versMod = 1

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
    [389684] = 0.04, -- Close to the heart, need to add support for 2/2 talent? 
}

-- Function to find the player's health bar
local function FindPlayerHealthBar()
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
local function CreatePredictionOverlay(healthBar)
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
    line:SetColorTexture(1, 1, 1, 0.8)
    line:SetHeight(healthBar:GetHeight())
    line:SetWidth(2)
    line:SetBlendMode("ADD")
    
    -- Store the container reference
    DSP.container = container
    
    return overlay, line
end

-- Update the prediction display
local function UpdatePrediction()
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
    
    local healing = max(DSP.damagePool * DSP.baseHealing * DSP.mod * DSP.versMod, 
                       UnitHealthMax("player") * DSP.minHealing * DSP.mod * DSP.versMod)
    
    local healthBar = DSP.healthBar
    local maxHealth = UnitHealthMax("player")
    local currentHealth = UnitHealth("player")
    
    -- Get the actual width of the health bar
    local width = healthBar:GetWidth()
    local predictedHealth = min(currentHealth + healing, maxHealth)
    
    -- Calculate positions based on health percentages
    local startPos = (currentHealth / maxHealth) * width
    local endPos = (predictedHealth / maxHealth) * width
    
    -- Update overlay position and size
    DSP.overlay:ClearAllPoints()
    DSP.overlay:SetPoint("TOPLEFT", healthBar, "TOPLEFT", startPos, 0)
    DSP.overlay:SetWidth(max(1, endPos - startPos))
    DSP.overlay:Show()
    
    -- Update line position
    DSP.line:ClearAllPoints()
    DSP.line:SetPoint("TOPLEFT", healthBar, "TOPLEFT", endPos - 1, 0)
    DSP.line:Show()
end

-- Handle events
local function OnEvent(self, event, ...)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" or event == "ADDON_LOADED" then
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
                DSP.damagePool = (DSP.damagePool or 0) + damage
                C_Timer.After(5, function()
                    DSP.damagePool = DSP.damagePool - damage
                    UpdatePrediction()
                end)
                UpdatePrediction()
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
    "DISPLAY_SIZE_CHANGED"
}

for _, event in ipairs(events) do
    frame:RegisterEvent(event)
end

frame:SetScript("OnEvent", OnEvent)

-- Create slash command to toggle display
SLASH_DSP1 = "/dsp"
SlashCmdList["DSP"] = function(msg)
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
