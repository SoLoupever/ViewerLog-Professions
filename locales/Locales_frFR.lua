local addonName, ns = ...

-- Localisation ViewerLog_Professions. Table et ns.L propres à la dépendance.

ns.locales = ns.locales or {}

ns.locales["frFR"] = {
    DBG_PROF_REMOVED        = "Métier(s) retiré(s) : %s",
    DBG_PROF_SAVED_BASIC    = "%s sauvegardé (basique) : %d/%d",
    DBG_PROF_SCANNED        = "%s scanné : %s",
    DBG_FULL_SCAN_DONE      = "Scan complet terminé.",
    DBG_SCAN_IN_PROGRESS    = "Scan déjà en cours...",
    DBG_NO_PROFESSION_FOUND = "Aucun métier trouvé.",
    DBG_SCAN_START          = "Début du scan (%d métier(s))...",
    DBG_FIRST_SCAN          = "Premier scan des métiers...",
    DBG_PROGRESS_RESCAN     = "Progression détectée — rescan de %d métier(s)...",
    DBG_PASSIVE_SCAN        = "Scan passif : %s",
}

-- Traduction : langue AltViewerLog si dispo, sinon client ; repli enUS puis tag.
function ns.L(key)
    local lang = (_G.AltViewerLogDB and _G.AltViewerLogDB.settings and _G.AltViewerLogDB.settings.lang) or GetLocale()
    local tbl = ns.locales[lang] or ns.locales["enUS"]
    return (tbl and tbl[key]) or (ns.locales["enUS"] and ns.locales["enUS"][key]) or ("[VLP:" .. tostring(key) .. "]")
end
