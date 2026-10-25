local addonName, pluginNs = ...

-- Catalogue housing : découverte automatique.
-- Pour chaque recette du métier ouvert, remonte recipeInfo.categoryID via
-- GetCategoryInfo().parentCategoryID jusqu'à la catégorie "décoration de
-- logement", puis lit recipeID / itemID / nom / appris. Persisté dans
-- le store du module (catalog).
-- Gotchas API : GetCategories() renvoie des varargs (encapsuler { ... }) ;
-- GetRecipeItemLink n'existe pas → GetRecipeOutputItemData(recipeID, {}).itemID.

-- Indices de nom testés en remontant les catégories (≤ MAX_CATEGORY_DEPTH).
-- Verdict mis en cache par categoryID (numérique, stable entre sessions).
local HOUSING_CATEGORY_NAME_HINTS = {
    "house decor",             -- enUS
    "décoration de logement",  -- frFR — à confirmer via /vlhousing debug
    "décoration de maison",    -- frFR, variante possible
    "logement",                -- repli large si les deux précédents ne matchent pas
}
local MAX_CATEGORY_DEPTH = 6

local function GetDefKey(profName)
    return (pluginNs.PROF_RECIPE_KEY and pluginNs.PROF_RECIPE_KEY[profName]) or profName
end

-- ── Persistance : store.catalog ───────────────────────────────────
local function GetHousingDB()
    local store = pluginNs.GetStore()
    if not store then return nil end
    -- Chaque sous-champ garanti individuellement (compat tables anciennes).
    local hc = store.catalog or {}
    store.catalog = hc
    hc.categoryVerdict = hc.categoryVerdict or {}  -- [categoryID] = true/false (housing ou non), mémoïsé
    hc.recipes         = hc.recipes         or {}  -- [defKey] = { [recipeID] = { itemID=, name=, learned= } }
    return hc
end

local function NameLooksLikeHousing(name)
    if not name then return false end
    local lower = name:lower()
    for _, hint in ipairs(HOUSING_CATEGORY_NAME_HINTS) do
        if lower:find(hint, 1, true) then return true end
    end
    return false
end

-- ── Remonte categoryID → parent jusqu'à trouver "housing" ─────────
-- Mémoïse le verdict pour ce categoryID (recettes suivantes = cache).
local function IsHousingCategory(categoryID)
    if not categoryID or categoryID == 0 then return false end
    local db = GetHousingDB()
    if not db then return false end
    if db.categoryVerdict[categoryID] ~= nil then
        return db.categoryVerdict[categoryID]
    end

    local visited = {}
    local verdict = false
    local currentID = categoryID
    local depth = 0

    while currentID and depth < MAX_CATEGORY_DEPTH and not visited[currentID] do
        visited[currentID] = true
        local info = C_TradeSkillUI.GetCategoryInfo and C_TradeSkillUI.GetCategoryInfo(currentID)
        if not info then break end
        if NameLooksLikeHousing(info.name) then
            verdict = true
            break
        end
        currentID = info.parentCategoryID
        depth = depth + 1
    end

    db.categoryVerdict[categoryID] = verdict
    return verdict
end

-- ── itemID depuis un recipeID ──────────────────────────────────────
local function GetRecipeItemID(recipeID)
    local outputInfo = C_TradeSkillUI.GetRecipeOutputItemData
        and C_TradeSkillUI.GetRecipeOutputItemData(recipeID, {})
    return outputInfo and outputInfo.itemID or nil
end

-- ── Découverte (métier ouvert) ────────────────────────────────────
-- Retourne { [recipeID] = {itemID, name, learned} } ou nil si pas prêt.
function pluginNs.DiscoverHousingRecipes(profName)
    if not (C_TradeSkillUI.IsTradeSkillReady and C_TradeSkillUI.IsTradeSkillReady()) then
        return nil
    end

    local defKey = GetDefKey(profName)
    local db = GetHousingDB()
    if not db then return nil end
    db.recipes[defKey] = db.recipes[defKey] or {}
    local bucket = db.recipes[defKey]

    local allIDs = C_TradeSkillUI.GetAllRecipeIDs and C_TradeSkillUI.GetAllRecipeIDs()
    if not allIDs then return bucket end

    local found = 0
    for _, recipeID in ipairs(allIDs) do
        local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
        if info and IsHousingCategory(info.categoryID) then
            local existing = bucket[recipeID]
            bucket[recipeID] = {
                itemID  = (existing and existing.itemID) or GetRecipeItemID(recipeID),
                name    = info.name or (existing and existing.name),
                learned = info.learned or false,
            }
            found = found + 1
        end
    end

    pluginNs.Debug("|cff00ff00[VL-Housing]|r " .. pluginNs.L("DBG_HOUSING_DISCOVERED"), profName, found)
    return bucket
end

-- ── Lecture (Detect.lua et UI) ────────────────────────────────────
function pluginNs.GetDiscoveredHousingRecipes(profName)
    local db = GetHousingDB()
    if not db then return nil end
    return db.recipes[GetDefKey(profName)]
end

-- ── Diagnostic — /vlhousing debug ─────────────────────────────────
-- Liste les catégories top-level, la chaîne catégorie → parent de la 1ère
-- recette, et les clés d'un recipeInfo échantillon.
function pluginNs.DebugHousingCategories()
    if not (C_TradeSkillUI.IsTradeSkillReady and C_TradeSkillUI.IsTradeSkillReady()) then
        pluginNs.Say("|cffff8800[VL-Housing]|r " .. pluginNs.L("DBG_HOUSING_NO_WINDOW"))
        return
    end

    -- GetCategories() renvoie des varargs → encapsuler avec { ... }.
    local categoryIDs = { C_TradeSkillUI.GetCategories and C_TradeSkillUI.GetCategories() }
    pluginNs.Say("|cff00ff00[VL-Housing]|r " .. pluginNs.L("DBG_HOUSING_CATEGORY_LIST"))
    for _, catID in ipairs(categoryIDs) do
        local info = C_TradeSkillUI.GetCategoryInfo and C_TradeSkillUI.GetCategoryInfo(catID)
        pluginNs.Say(string.format("  [%s] %s (parent=%s)",
            tostring(catID), (info and info.name) or "?", tostring(info and info.parentCategoryID)))
    end

    local allIDs = (C_TradeSkillUI.GetAllRecipeIDs and C_TradeSkillUI.GetAllRecipeIDs()) or {}
    if allIDs[1] then
        local sample = C_TradeSkillUI.GetRecipeInfo(allIDs[1])
        if sample then
            pluginNs.Say("|cff00ff00[VL-Housing]|r " .. pluginNs.L("DBG_HOUSING_SAMPLE_KEYS"))
            local keys = {}
            for k in pairs(sample) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            pluginNs.Say("  " .. table.concat(keys, ", "))

            -- Chaîne catégorie → parent de la recette échantillon.
            if sample.categoryID then
                pluginNs.Say(string.format("  categoryID de la recette #%d : %s", allIDs[1], tostring(sample.categoryID)))
                local cur, depth = sample.categoryID, 0
                while cur and depth < MAX_CATEGORY_DEPTH do
                    local info = C_TradeSkillUI.GetCategoryInfo and C_TradeSkillUI.GetCategoryInfo(cur)
                    if not info then break end
                    pluginNs.Say(string.format("    -> [%s] %s", tostring(cur), tostring(info.name)))
                    cur = info.parentCategoryID
                    depth = depth + 1
                end
            end
        end
    end
end
