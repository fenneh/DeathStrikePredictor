local addonName, DSP = ...

-- Initialize the database with our defaults
DSP.defaults = {
    profile = {
        overlayColor = {r = 0, g = 1, b = 0, a = 0.3},  -- Default green
        lineColor = {r = 1, g = 0.84, b = 0, a = 0.75}, -- Default yellow
    }
}

local function InitializeConfig()
    -- Initialize the database with our defaults
    DSP.db = LibStub("AceDB-3.0"):New("DeathStrikePredictorDB", DSP.defaults, true)
    
    local options = {
        name = "Death Strike Predictor",
        type = "group",
        args = {
            overlayColor = {
                type = "color",
                name = "Overlay Color",
                desc = "Color of the healing prediction overlay",
                hasAlpha = true,
                get = function()
                    local c = DSP.db.profile.overlayColor
                    return c.r, c.g, c.b, c.a
                end,
                set = function(_, r, g, b, a)
                    DSP.db.profile.overlayColor.r = r
                    DSP.db.profile.overlayColor.g = g
                    DSP.db.profile.overlayColor.b = b
                    DSP.db.profile.overlayColor.a = a
                    if DSP.overlay then
                        DSP.overlay:SetColorTexture(r, g, b, a)
                    end
                end,
                order = 1,
            },
            lineColor = {
                type = "color",
                name = "Line Color",
                desc = "Color of the prediction line",
                hasAlpha = true,
                get = function()
                    local c = DSP.db.profile.lineColor
                    return c.r, c.g, c.b, c.a
                end,
                set = function(_, r, g, b, a)
                    DSP.db.profile.lineColor.r = r
                    DSP.db.profile.lineColor.g = g
                    DSP.db.profile.lineColor.b = b
                    DSP.db.profile.lineColor.a = a
                    if DSP.line then
                        DSP.line:SetColorTexture(r, g, b, a)
                    end
                end,
                order = 2,
            },
        },
    }
    
    -- Register the options with AceConfig
    LibStub("AceConfig-3.0"):RegisterOptionsTable("DeathStrikePredictor", options)
    LibStub("AceConfigDialog-3.0"):AddToBlizOptions("DeathStrikePredictor", "Death Strike Predictor")
end

-- Create a frame to handle initialization
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        InitializeConfig()
        
        -- Add config option to slash command
        local originalSlashCommand = SlashCmdList["DSP"]
        SlashCmdList["DSP"] = function(msg)
            if msg == "config" then
                LibStub("AceConfigDialog-3.0"):Open("DeathStrikePredictor")
            elseif originalSlashCommand then
                originalSlashCommand(msg)
            end
        end
        
        self:UnregisterEvent("ADDON_LOADED")
    end
end) 