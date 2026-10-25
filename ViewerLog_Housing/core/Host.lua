local addonName, pluginNs = ...

-- Hôte graphique optionnel : AltViewerLog (OptionalDeps → chargé avant).
-- Sans lui : pas de section Paramètres, aperçu 3D ancré sur UIParent, debug
-- dans le chat.

local host = _G.AltViewerLogAPI

function pluginNs.GetHost()
    return host
end

-- Fenêtre parente de l'aperçu 3D.
function pluginNs.GetHostFrame()
    return host and host.mainFrame or UIParent
end

-- Logs passifs : uniquement via DBG d'AltViewerLog. fmt formaté si hôte présent.
function pluginNs.Debug(fmt, ...)
    if host and host.DBG then
        host.DBG(select("#", ...) > 0 and fmt:format(...) or fmt)
    end
end

-- Sortie des commandes slash : DBG si hôte présent, sinon chat.
function pluginNs.Say(msg)
    if host and host.DBG then host.DBG(msg) else print(msg) end
end
