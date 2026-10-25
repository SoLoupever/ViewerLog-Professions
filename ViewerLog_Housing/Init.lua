local addonName, pluginNs = ...

local vlAPI = _G.ViewerLogAPI

-- ViewerLog_Housing : données via ViewerLogAPI. Pas de vue propre : la barre
-- housing est dessinée par le consommateur (AltViewerLog_Professions, comme
-- pour ViewerLog_Recette) qui lit _G.ViewerLogAPI.GetHousingRecipes.
-- AltViewerLog est un hôte optionnel (section Paramètres, debug) : ce module
-- se charge sans lui.
if not vlAPI then
    print("|cffff0000[VL-Housing]|r " .. (pluginNs.L and pluginNs.L("ERR_API_MISSING") or "ViewerLogAPI not found."))
    return
end

pluginNs.Debug("|cffcc88ff[VL-Housing]|r " .. pluginNs.L("DBG_LOADED"))

-- ── Commandes slash ──────────────────────────────────────────────
SLASH_VLHOUSING1 = "/vlhousing"
SlashCmdList["VLHOUSING"] = function(msg)
    msg = msg and strtrim(msg:lower()) or ""
    if msg == "scan" then
        if pluginNs.DetectAllForCurrentChar then pluginNs.DetectAllForCurrentChar() end
        -- Rafraîchit la vue Métiers si ouverte (barre housing à jour).
        local host = pluginNs.GetHost()
        if host and host.RefreshActiveView then host.RefreshActiveView() end
    elseif msg == "debug" then
        if pluginNs.DebugHousingCategories then pluginNs.DebugHousingCategories() end
    elseif msg == "2d" then
        local store = pluginNs.GetStore()
        if store then
            store.disable2DPreview = not store.disable2DPreview
            pluginNs.Say(pluginNs.L(store.disable2DPreview and "CMD_2D_DISABLED" or "CMD_2D_ENABLED"))
        end
    else
        pluginNs.Say("|cffcc88ff[VL-Housing]|r " .. pluginNs.L("DBG_HELP"))
    end
end

-- ── Section Settings (option aperçu 2D) ──────────────────────────
-- Injectée dans le panneau Paramètres d'AltViewerLog, si présent.
local host = pluginNs.GetHost()
if host and host.RegisterSettingsSection then
    host.RegisterSettingsSection(function(scrollChild, y)
        if pluginNs.InjectHousingSettings then
            return pluginNs.InjectHousingSettings(scrollChild, y)
        end
        return y
    end)
end
