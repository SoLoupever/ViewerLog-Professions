local addonName, pluginNs = ...

-- Table persistante du module (catalog, fileIDs, options), via ViewerLogAPI.
-- Point d'accès unique : aucun autre fichier ne touche ViewerLogDB.

local vlAPI = _G.ViewerLogAPI

function pluginNs.GetStore()
    return vlAPI and vlAPI.GetModuleData and vlAPI.GetModuleData("housing")
end
