local ADDON_NAME = "Offload"

local RARITY_NAMES = {
    [0] = "Poor",
    [1] = "Common",
    [2] = "Uncommon",
    [3] = "Rare",
    [4] = "Epic",
}

local RARITY_COLORS = {
    [0] = "|cff9d9d9d",
    [1] = "|cffffffff",
    [2] = "|cff1eff00",
    [3] = "|cff0070dd",
    [4] = "|cffa335ee",
}

local GEAR_CLASS_IDS = {
    [Enum.ItemClass.Weapon] = true,
    [Enum.ItemClass.Armor]  = true,
}

local DEFAULTS = {
    enabled         = true,
    ilvlThreshold   = 0,   -- 0 = disabled (only grey items sold)
    rarityThreshold = 2,   -- Uncommon (green) and below
    gearOnly        = false,
    verbose         = true,
}

local PREFIX = "|cffFFD700[Offload]|r "

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

local function ColoredRarity(quality)
    local color = RARITY_COLORS[quality] or "|cffffffff"
    local name  = RARITY_NAMES[quality]  or ("Quality " .. quality)
    return color .. name .. "|r"
end

local function CopperToGoldString(copper)
    local gold   = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop    = copper % 100
    return string.format("|cffffD700%dg|r |cffc0c0c0%ds|r |cffb87333%dc|r", gold, silver, cop)
end

-- ── SavedVariables Init ───────────────────────────────────────────────────────

local Offload  = CreateFrame("Frame", ADDON_NAME .. "Frame")
local db       -- points to OffloadDB after ADDON_LOADED

Offload:RegisterEvent("ADDON_LOADED")
Offload:RegisterEvent("MERCHANT_SHOW")

Offload:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= ADDON_NAME then return end
        self:OnAddonLoaded()
    elseif event == "MERCHANT_SHOW" then
        self:OnMerchantShow()
    end
end)

function Offload:OnAddonLoaded()
    -- Merge saved variables with defaults
    OffloadDB = OffloadDB or {}
    for k, v in pairs(DEFAULTS) do
        if OffloadDB[k] == nil then
            OffloadDB[k] = v
        end
    end
    db = OffloadDB

    self:RegisterSettingsPanel()
    self:RegisterSlashCommands()
    Print("Loaded. Type |cffffd700/ol help|r for commands.")
end

-- ── Sell Logic ────────────────────────────────────────────────────────────────

local function Debug(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff888888[Offload DBG]|r " .. msg)
end

function Offload:OnMerchantShow()
    if not db then
        Print("|cffff4444Error: settings not loaded yet.|r")
        return
    end

    if not db.enabled then
        if db.verbose then
            Debug("Skipping — addon is disabled. (/ol toggle to enable)")
        end
        return
    end

    if db.verbose then
        Debug(string.format(
            "Vendor opened. Settings: ilvl < |cffffd700%s|r, rarity <= %s, gear only=%s",
            db.ilvlThreshold > 0 and tostring(db.ilvlThreshold) or "off",
            ColoredRarity(db.rarityThreshold),
            db.gearOnly and "|cff00ff00on|r" or "|cff888888off|r"
        ))
    end

    local totalSold    = 0
    local totalCopper  = 0
    local totalChecked = 0

    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.hyperlink then
                totalChecked = totalChecked + 1
                local quality  = info.quality
                local itemLink = info.hyperlink
                local shouldSell = false

                if info.hasNoValue then
                    if db.verbose then
                        Debug(string.format("SKIP  %s — no vendor value", itemLink))
                    end
                elseif db.gearOnly and not GEAR_CLASS_IDS[select(12, C_Item.GetItemInfo(itemLink))] then
                    if db.verbose then
                        Debug(string.format("SKIP  %s — not a weapon or armor (gear only mode)", itemLink))
                    end
                elseif quality == 0 then
                    shouldSell = true
                    if db.verbose then
                        Debug(string.format("SELL  %s — grey item", itemLink))
                    end
                elseif quality > db.rarityThreshold then
                    if db.verbose then
                        Debug(string.format("SKIP  %s — rarity %s above cap %s",
                            itemLink, ColoredRarity(quality), ColoredRarity(db.rarityThreshold)))
                    end
                elseif db.ilvlThreshold == 0 then
                    if db.verbose then
                        Debug(string.format("SKIP  %s — ilvl threshold is off (set with /ol ilvl)", itemLink))
                    end
                else
                    local effectiveIlvl = C_Item.GetDetailedItemLevelInfo(itemLink)
                    if not effectiveIlvl then
                        if db.verbose then
                            Debug(string.format("SKIP  %s — ilvl not cached yet", itemLink))
                        end
                    elseif effectiveIlvl < db.ilvlThreshold then
                        shouldSell = true
                        if db.verbose then
                            Debug(string.format("SELL  %s — ilvl |cffffd700%d|r < threshold |cffffd700%d|r",
                                itemLink, effectiveIlvl, db.ilvlThreshold))
                        end
                    else
                        if db.verbose then
                            Debug(string.format("SKIP  %s — ilvl |cffffd700%d|r >= threshold |cffffd700%d|r",
                                itemLink, effectiveIlvl, db.ilvlThreshold))
                        end
                    end
                end

                if shouldSell then
                    local sellPrice  = select(11, C_Item.GetItemInfo(itemLink)) or 0
                    local stackCount = info.stackCount or 1

                    local ok, err = pcall(C_Container.UseContainerItem, bag, slot)
                    if ok then
                        totalSold   = totalSold + 1
                        totalCopper = totalCopper + (sellPrice * stackCount)

                        if db.verbose then
                            Print(string.format("Sold %s (%s)", itemLink, ColoredRarity(quality)))
                        end
                    elseif db.verbose then
                        Debug(string.format("ERROR selling %s: %s", itemLink, tostring(err)))
                    end
                end
            end
        end
    end

    if db.verbose then
        Debug(string.format("Done. Checked |cffffd700%d|r items, sold |cffffd700%d|r.", totalChecked, totalSold))
    end

    if totalSold > 0 then
        Print(string.format(
            "Sold |cffffd700%d|r item%s for %s.",
            totalSold,
            totalSold == 1 and "" or "s",
            CopperToGoldString(totalCopper)
        ))
    end
end

-- ── Settings Panel ───────────────────────────────────────────────────────────

function Offload:RegisterSettingsPanel()
    local category = Settings.RegisterVerticalLayoutCategory("Offload")

    -- Enable / disable the addon
    local enabledSetting = Settings.RegisterProxySetting(category,
        "OFFLOAD_ENABLED", Settings.VarType.Boolean, "Enable Offload",
        Settings.Default.True,
        function() return db.enabled end,
        function(value) db.enabled = value end)
    Settings.CreateCheckbox(category, enabledSetting,
        "When enabled, Offload will automatically sell qualifying items each time you open a vendor.")

    -- Item level threshold slider (0 = off, 1–700 = sell below this ilvl)
    local ilvlSetting = Settings.RegisterProxySetting(category,
        "OFFLOAD_ILVL", Settings.VarType.Number, "Item Level Threshold",
        0,
        function() return db.ilvlThreshold end,
        function(value) db.ilvlThreshold = math.floor(value) end)
    local ilvlOptions = Settings.CreateSliderOptions(0, 700, 5)
    ilvlOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right,
        function(value)
            return value == 0 and "Off" or tostring(math.floor(value))
        end)
    Settings.CreateSlider(category, ilvlSetting, ilvlOptions,
        "Sell items below this item level. Set to 0 to only sell grey items regardless of item level.")

    -- Max rarity to sell (dropdown)
    local raritySetting = Settings.RegisterProxySetting(category,
        "OFFLOAD_RARITY", Settings.VarType.Number, "Max Rarity to Sell",
        2,
        function() return db.rarityThreshold end,
        function(value) db.rarityThreshold = value end)
    local function GetRarityOptions()
        local container = Settings.CreateControlTextContainer()
        container:Add(0, "Poor (Grey)")
        container:Add(1, "Common (White)")
        container:Add(2, "Uncommon (Green)")
        container:Add(3, "Rare (Blue)")
        container:Add(4, "Epic (Purple)")
        return container:GetData()
    end
    Settings.CreateDropdown(category, raritySetting, GetRarityOptions,
        "Items above this rarity will never be sold, even if they are below the item level threshold.")

    -- Gear only toggle
    local gearOnlySetting = Settings.RegisterProxySetting(category,
        "OFFLOAD_GEAR_ONLY", Settings.VarType.Boolean, "Gear Only",
        Settings.Default.False,
        function() return db.gearOnly end,
        function(value) db.gearOnly = value end)
    Settings.CreateCheckbox(category, gearOnlySetting,
        "When enabled, only weapons and armor are considered for selling. All other item types (consumables, crafting materials, etc.) will be ignored.")

    -- Verbose chat output
    local verboseSetting = Settings.RegisterProxySetting(category,
        "OFFLOAD_VERBOSE", Settings.VarType.Boolean, "Verbose Mode",
        Settings.Default.True,
        function() return db.verbose end,
        function(value) db.verbose = value end)
    Settings.CreateCheckbox(category, verboseSetting,
        "Print each sold item to the chat frame.")

    Settings.RegisterAddOnCategory(category)
    self.settingsCategory = category
end

-- ── Slash Commands ────────────────────────────────────────────────────────────

function Offload:RegisterSlashCommands()
    SLASH_OFFLOAD1 = "/offload"
    SLASH_OFFLOAD2 = "/ol"
    SlashCmdList["OFFLOAD"] = function(input)
        self:HandleCommand(input)
    end
end

function Offload:PrintStatus()
    local enabledStr  = db.enabled and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"
    local ilvlStr     = db.ilvlThreshold > 0
                        and ("|cffffd700" .. db.ilvlThreshold .. "|r")
                        or  "|cff888888Off (grey items only)|r"
    local rarityStr   = ColoredRarity(db.rarityThreshold)
    local verboseStr  = db.verbose and "|cff00ff00On|r" or "|cff888888Off|r"

    local gearOnlyStr = db.gearOnly and "|cff00ff00On|r" or "|cff888888Off|r"

    Print("Current settings:")
    Print("  Status:          " .. enabledStr)
    Print("  iLvl threshold:  " .. ilvlStr)
    Print("  Max rarity sold: " .. rarityStr .. " (" .. db.rarityThreshold .. ")")
    Print("  Gear only:       " .. gearOnlyStr)
    Print("  Verbose:         " .. verboseStr)
end

function Offload:PrintHelp()
    Print("Commands:")
    Print("  |cffffd700/ol|r               — Show current settings")
    Print("  |cffffd700/ol settings|r       — Open the Settings panel")
    Print("  |cffffd700/ol toggle|r         — Enable / disable Offload")
    Print("  |cffffd700/ol ilvl <number>|r  — Sell items below this item level (0 = off)")
    Print("  |cffffd700/ol rarity <0-4>|r   — Max rarity to sell (0=Grey 1=White 2=Green 3=Blue 4=Epic)")
    Print("  |cffffd700/ol gear|r            — Toggle gear-only mode (weapons & armor only)")
    Print("  |cffffd700/ol verbose|r        — Toggle per-item chat output")
    Print("  |cffffd700/ol help|r           — Show this message")
end

function Offload:HandleCommand(input)
    if not db then return end

    input = input and input:match("^%s*(.-)%s*$") or ""

    if input == "" then
        self:PrintStatus()
        return
    end

    local cmd, arg = input:match("^(%S+)%s*(.*)")
    cmd = cmd:lower()

    if cmd == "settings" or cmd == "config" then
        Settings.OpenToCategory(self.settingsCategory:GetID())

    elseif cmd == "toggle" then
        db.enabled = not db.enabled
        Print("Offload is now " .. (db.enabled and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r") .. ".")

    elseif cmd == "ilvl" then
        local value = tonumber(arg)
        if not value or value < 0 then
            Print("|cffff4444Invalid item level. Usage: /ol ilvl <number>|r")
            return
        end
        db.ilvlThreshold = value
        if value == 0 then
            Print("Item level threshold disabled (grey items only).")
        else
            Print(string.format("Will sell items below item level |cffffd700%d|r.", value))
        end

    elseif cmd == "rarity" then
        local value = tonumber(arg)
        if not value or value < 0 or value > 4 then
            Print("|cffff4444Invalid rarity. Usage: /ol rarity <0-4>  (0=Grey, 1=White, 2=Green, 3=Blue, 4=Epic)|r")
            return
        end
        db.rarityThreshold = math.floor(value)
        Print(string.format("Max rarity to sell set to %s.", ColoredRarity(db.rarityThreshold)))

    elseif cmd == "gear" then
        db.gearOnly = not db.gearOnly
        Print("Gear only mode " .. (db.gearOnly and "|cff00ff00On|r — only weapons and armor will be sold." or "|cff888888Off|r — all item types considered."))

    elseif cmd == "verbose" then
        db.verbose = not db.verbose
        Print("Verbose mode " .. (db.verbose and "|cff00ff00On|r" or "|cff888888Off|r") .. ".")

    elseif cmd == "help" then
        self:PrintHelp()

    else
        Print("|cffff4444Unknown command.|r Type |cffffd700/ol help|r for a list of commands.")
    end
end
