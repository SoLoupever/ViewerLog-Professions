local addonName, ns = ...

-- Init ViewerLog_Professions : dépendance optionnelle de ViewerLog.
-- Scan de base (nom, icône, rang) + scan approfondi (paliers).
-- ns et event frame propres ; partage uniquement ViewerLogAPI.

local frame = CreateFrame("Frame", "ViewerLog_Professions_EventFrame")

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("SKILL_LINES_CHANGED")
frame:RegisterEvent("TRADE_SKILL_SHOW")

frame:SetScript("OnEvent", function(self, event, ...)

    -- PLAYER_LOGIN : GetProfessions() est fiable seulement ~8 s après
    -- login (délai géré en interne par ns.OnProfessionsLogin).
    if event == "PLAYER_LOGIN" then
        if ns.OnProfessionsLogin then ns.OnProfessionsLogin() end
        ns.OnDeepLogin()

    -- SKILL_LINES_CHANGED : gain de rang ou changement de métier.
    -- Dispatché à Professions.lua qui gère son propre debounce (3 s).
    elseif event == "SKILL_LINES_CHANGED" then
        if ns.OnSkillLinesChanged then ns.OnSkillLinesChanged() end
        ns.OnDeepSkillLinesChanged()

    -- Panneau métier ouvert : scan approfondi passif.
    elseif event == "TRADE_SKILL_SHOW" then
        ns.OnTradeSkillShow()
    end
end)

-- ── Exposition sur l'API partagée ───────────────────────────────
-- RegisterProfessionsCallback : notifié après chaque scan (UI).
-- ScanBasicProfessions : consommée par /vl scan (core).
-- ScanAllProfessions : scan approfondi, bouton Scanner des UI.
if _G.ViewerLogAPI then
    _G.ViewerLogAPI.RegisterProfessionsCallback = ns.RegisterProfessionsCallback
    _G.ViewerLogAPI.ScanBasicProfessions        = ns.ScanBasicProfessions
    _G.ViewerLogAPI.ScanAllProfessions          = ns.ScanAllProfessions
end
