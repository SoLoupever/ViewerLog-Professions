local addonName, ns = ...

-- Scanner métiers — scan approfondi (propriétaire unique).
-- Ce qui requiert le panneau métier ouvert (TRADE_SKILL_SHOW) :
--   · Paliers d'extension (GetChildProfessionInfos)
--   · Préserve knownRecipes (propriété de ViewerLog_Housing)
-- Le scan de base (rang, icône, skillLine) est dans scanner/Professions.lua
-- (+8 s après PLAYER_LOGIN) ; celui-ci démarre son check à +10 s.
-- Écritures : charData.professions via ViewerLogAPI.GetCurrentCharData().
-- Déclencheurs (Init.lua) : ns.OnDeepLogin, ns.OnDeepSkillLinesChanged,
-- ns.OnTradeSkillShow. Consommé par AltViewerLog_Professions et
-- ProfessionViewerLog (UI) via ViewerLogAPI.ScanAllProfessions.

-- Logs : DBG d'AltViewerLog si présent, sinon silencieux.
function ns.Debug(fmt, ...)
    local host = _G.AltViewerLogAPI
    if host and host.DBG then
        host.DBG(select("#", ...) > 0 and fmt:format(...) or fmt)
    end
end

-- ── Point d'accès aux données du personnage courant ──────────────
local function GetCharData()
    local api = _G.ViewerLogAPI
    return api and api.GetCurrentCharData and api.GetCurrentCharData()
end

-- ── Itérateur sûr sur tous les métiers du personnage ─────────────
-- GetProfessions() peut retourner des nil intercalés (ex : pas
-- d'archéologie mais pêche active). ipairs() s'arrête au premier nil
-- → les métiers secondaires seraient ignorés. On appelle chaque slot
-- individuellement.
local function ForEachProf(callback)
    local p1, p2, ar, fi, co = GetProfessions()
    if p1 then callback(p1, false) end
    if p2 then callback(p2, false) end
    if ar then callback(ar, true)  end
    if fi then callback(fi, true)  end
    if co then callback(co, true)  end
end

-- ── État interne du scan séquentiel ──────────────────────────────
local scanQueue       = {}
local scanQueueIndex  = 0
local scanInProgress  = false
local AdvanceScanQueue  -- forward declaration

-- Cache local des rangs — évite la race condition avec le scan de base
-- (SKILL_LINES_CHANGED met aussi à jour basicRank en DB au même moment)
local lastKnownRanks = {}   -- { [profName] = rank }

-- Notifie les consommateurs (UI) : callbacks de RegisterProfessionsCallback.
local function NotifyChanged()
    for _, fn in ipairs(ns._profCallbacks) do fn() end
end

local function GetBaseSkillLineID(profName, fallbackSkillLine)
    if ns.PROFESSION_BASE_IDS and ns.PROFESSION_BASE_IDS[profName] then
        return ns.PROFESSION_BASE_IDS[profName]
    end
    return fallbackSkillLine
end

-- ── Collecte de tous les slots ────────────────────────────────────
local function CollectAllProfessionSlots()
    local slots = {}
    ForEachProf(function(idx, isSecondary)
        local name, icon, rank, maxRank, _, _, skillLine = GetProfessionInfo(idx)
        if name and skillLine then
            slots[#slots + 1] = {
                name         = name,
                icon         = icon,
                rank         = rank,
                maxRank      = maxRank,
                skillLine    = GetBaseSkillLineID(name, skillLine),
                rawSkillLine = skillLine,
                isSecondary  = isSecondary,
            }
        end
    end)
    return slots
end

-- ── Purge des métiers abandonnés ──────────────────────────────────
local function PurgeRemovedProfessions(charData, currentSlots)
    if not charData.professions then return end
    local currentNames = {}
    for _, slot in ipairs(currentSlots) do currentNames[slot.name] = true end
    local removed = {}
    for i = #charData.professions, 1, -1 do
        local p = charData.professions[i]
        if not currentNames[p.name] then
            removed[#removed + 1] = p.name
            table.remove(charData.professions, i)
        end
    end
    if #removed > 0 then
        ns.Debug("|cffff8800[VL-Prof]|r " .. ns.L("DBG_PROF_REMOVED"), table.concat(removed, ", "))
    end
end

-- ── Résolution du nom de palier courant ──────────────────────────
-- Retourne le 11e retour de GetProfessionInfo (ex : "Travailleur du
-- cuir de Minuit"), ou le nom brut du métier si indisponible.
local function ResolveTierName(profName)
    local tierName = profName
    local found = false
    ForEachProf(function(idx)
        if found then return end
        local n, _, _, _, _, _, _, _, _, _, skillLineName = GetProfessionInfo(idx)
        if n == profName and skillLineName and skillLineName ~= "" then
            tierName = skillLineName
            found    = true
        end
    end)
    return tierName
end

-- ── Sauvegarde de repli ───────────────────────────────────────────
-- Écrit un tier basique dans charData pour les métiers dont le
-- panneau n'a pas pu être ouvert pendant la file de scan.
local function SaveFallbackEntry(charData, slot)
    if not slot or not slot.rank or not slot.maxRank or slot.maxRank <= 0 then return end
    charData.professions = charData.professions or {}

    local tierName = ResolveTierName(slot.name)

    local found = false
    for _, p in ipairs(charData.professions) do
        if p.name == slot.name then
            if not p.scanned then
                p.tiers    = {{ name = tierName, level = slot.rank, max = slot.maxRank, manual = false }}
                -- Ne PAS passer scanned à true : c'est une entrée de repli (basique).
                -- Le scan approfondi (TRADE_SKILL_SHOW) doit encore pouvoir se déclencher.
                p.lastScan = time()
            end
            found = true
            break
        end
    end
    if not found then
        charData.professions[#charData.professions + 1] = {
            name         = slot.name,
            icon         = slot.icon,
            skillLine    = slot.skillLine,
            rawSkillLine = slot.rawSkillLine,
            secondary    = slot.isSecondary,
            tiers        = {{ name = tierName, level = slot.rank, max = slot.maxRank, manual = false }},
            knownRecipes = {},
            scanned      = false,   -- repli basique : le scan profond reste à faire
            lastScan     = time(),
        }
    end
    ns.Debug("|cff00ff00[VL-Prof]|r " .. ns.L("DBG_PROF_SAVED_BASIC"), slot.name, slot.rank, slot.maxRank)
end

-- ====================================================
-- SCAN COMPLET D'UNE PROFESSION OUVERTE
-- ====================================================
function ns.ScanOpenProfession(optionalProfName, optionalSlot)
    local charData = GetCharData()
    if not charData then return end
    charData.professions = charData.professions or {}

    -- ── Résolution du nom du métier ouvert ────────────────────────
    local profName = optionalProfName

    if not profName and C_TradeSkillUI.GetTradeSkillDisplayName then
        profName = C_TradeSkillUI.GetTradeSkillDisplayName()
    end

    if not profName then
        local currentLine = C_TradeSkillUI.GetTradeSkillLine and C_TradeSkillUI.GetTradeSkillLine()
        if currentLine then
            local foundName = false
            ForEachProf(function(idx)
                if foundName then return end
                local name, _, _, _, _, _, skillLine = GetProfessionInfo(idx)
                if skillLine == currentLine
                or (name and ns.PROFESSION_BASE_IDS
                         and ns.PROFESSION_BASE_IDS[name] == currentLine) then
                    profName  = name
                    foundName = true
                end
            end)
        end
    end

    if not profName then
        if scanInProgress then AdvanceScanQueue() end
        return
    end

    -- ── Métadonnées du métier ─────────────────────────────────────
    local profIcon, profSkillLine, profRawSkillLine, profSecondary
    if optionalSlot and optionalSlot.name == profName then
        profIcon         = optionalSlot.icon
        profSkillLine    = optionalSlot.skillLine
        profRawSkillLine = optionalSlot.rawSkillLine
        profSecondary    = optionalSlot.isSecondary
    else
        local foundMeta = false
        ForEachProf(function(idx, isSecondary)
            if foundMeta then return end
            local name, icon, _, _, _, _, skillLine = GetProfessionInfo(idx)
            if name == profName then
                profIcon         = icon
                profSkillLine    = GetBaseSkillLineID(name, skillLine)
                profRawSkillLine = skillLine
                profSecondary    = isSecondary
                foundMeta        = true
            end
        end)
    end

    -- ── Paliers d'extension ───────────────────────────────────────
    local autoTiers = {}

    -- API officielle TWW+ : GetChildProfessionInfos
    local childInfos = C_TradeSkillUI.GetChildProfessionInfos and C_TradeSkillUI.GetChildProfessionInfos()
    if childInfos and #childInfos > 0 then
        for _, info in ipairs(childInfos) do
            if (info.maxSkillLevel or 0) > 0 then
                autoTiers[#autoTiers + 1] = {
                    name   = info.professionName or profName,
                    level  = info.skillLevel     or 0,
                    max    = info.maxSkillLevel   or 1,
                    manual = false,
                }
            end
        end
    end

    -- Fallback : GetProfessionTiers / GetProfessionTierInfo
    if #autoTiers == 0 then
        local ok, tiers = pcall(C_TradeSkillUI.GetProfessionTiers)
        if ok and tiers and #tiers > 0 then
            for _, tierID in ipairs(tiers) do
                local ok2, info = pcall(C_TradeSkillUI.GetProfessionTierInfo, tierID)
                if ok2 and info and (info.maxSkillLevel or 0) > 0 then
                    autoTiers[#autoTiers + 1] = {
                        name   = info.name or profName,
                        level  = info.skillLevel   or 0,
                        max    = info.maxSkillLevel or 1,
                        tierID = tierID,
                        manual = false,
                    }
                end
            end
        end
    end

    -- Fallback ultime : GetProfessionInfo (rang basique)
    if #autoTiers == 0 then
        ForEachProf(function(idx)
            if #autoTiers > 0 then return end
            local name, _, rank, maxRank, _, _, _, _, _, _, skillLineName = GetProfessionInfo(idx)
            if name == profName and maxRank and maxRank > 0 then
                local tName = (skillLineName and skillLineName ~= "") and skillLineName or profName
                autoTiers[#autoTiers + 1] = { name=tName, level=rank or 0, max=maxRank, manual=false }
            end
        end)
    end

    if #autoTiers == 0 then
        if scanInProgress then AdvanceScanQueue() end
        return
    end

    -- ── Données existantes ────────────────────────────────────────
    local existingEntry = nil
    for _, p in ipairs(charData.professions) do
        if p.name == profName then existingEntry = p; break end
    end

    local manualTiers  = {}
    local knownRecipes = {}
    if existingEntry then
        for _, t in ipairs(existingEntry.tiers or {}) do
            if t.manual then manualTiers[#manualTiers + 1] = t end
        end
        knownRecipes = existingEntry.knownRecipes or {}
    end

    -- ── Recettes connues (housing) ────────────────────────────────
    -- La détection housing a été déplacée dans le module ViewerLog_Housing
    -- (scanner/Detect.lua), qui est désormais l'unique propriétaire du
    -- champ knownRecipes. Ce scanner de métier ne fait que PRÉSERVER la
    -- valeur existante (récupérée plus haut depuis existingEntry) sans la
    -- recalculer — aucune dépendance directe vers le module housing.

    -- ── Fusion tiers auto + manuels ───────────────────────────────
    local finalTiers = {}
    local seenNames  = {}
    for _, t in ipairs(autoTiers) do
        if not seenNames[t.name] then
            seenNames[t.name] = true
            finalTiers[#finalTiers + 1] = t
        end
    end
    for _, t in ipairs(manualTiers) do
        if not seenNames[t.name] then finalTiers[#finalTiers + 1] = t end
    end

    -- ── Mise à jour du rang basique ───────────────────────────────
    local basicRank, basicMax = 0, 1
    do
        local foundBasic = false
        ForEachProf(function(idx)
            if foundBasic then return end
            local n, _, r, mx = GetProfessionInfo(idx)
            if n == profName and mx and mx > 0 then
                basicRank  = r or 0
                basicMax   = mx
                foundBasic = true
            end
        end)
    end

    -- ── Écriture dans charData ────────────────────────────────────
    local newEntry = {
        name         = profName,
        icon         = profIcon        or (existingEntry and existingEntry.icon),
        skillLine    = profSkillLine   or (existingEntry and existingEntry.skillLine),
        rawSkillLine = profRawSkillLine or (existingEntry and existingEntry.rawSkillLine),
        secondary    = profSecondary,
        tiers        = finalTiers,
        knownRecipes = knownRecipes,
        scanned      = true,
        lastScan     = time(),
        basicRank    = basicRank,
        basicMax     = basicMax,
    }

    local found = false
    for i, p in ipairs(charData.professions) do
        if p.name == profName then charData.professions[i] = newEntry; found = true; break end
    end
    if not found then charData.professions[#charData.professions + 1] = newEntry end

    local tierNames = {}
    for _, t in ipairs(autoTiers) do
        tierNames[#tierNames + 1] = string.format("%s %d/%d", t.name, t.level, t.max)
    end
    ns.Debug("|cff00ff00[VL-Prof]|r " .. ns.L("DBG_PROF_SCANNED"), profName, table.concat(tierNames, " | "))

    NotifyChanged()
    if scanInProgress then AdvanceScanQueue() end
end

-- ====================================================
-- FILE DE SCAN SÉQUENTIELLE
-- ====================================================
AdvanceScanQueue = function()
    scanQueueIndex = scanQueueIndex + 1

    if scanQueueIndex > #scanQueue then
        scanInProgress = false
        scanQueue      = {}
        scanQueueIndex = 0
        ns.Debug("|cff00ff00[VL-Prof]|r " .. ns.L("DBG_FULL_SCAN_DONE"))
        NotifyChanged()
        return
    end

    local entry        = scanQueue[scanQueueIndex]
    local currentIndex = scanQueueIndex

    local alreadyOpen = C_TradeSkillUI.IsTradeSkillReady and C_TradeSkillUI.IsTradeSkillReady()
    if alreadyOpen then
        C_Timer.After(0.3, function()
            if not scanInProgress or scanQueueIndex ~= currentIndex then return end
            ns.ScanOpenProfession(entry.name, entry)
        end)
    else
        -- Panneau pas ouvert → sauvegarde basique et passage au suivant
        local foundFallback = false
        ForEachProf(function(idx)
            if foundFallback then return end
            local name, _, rank, maxRank = GetProfessionInfo(idx)
            if name == entry.name and maxRank and maxRank > 0 then
                foundFallback = true
                local charData = GetCharData()
                if charData then
                    entry.rank    = rank or 0
                    entry.maxRank = maxRank
                    SaveFallbackEntry(charData, entry)
                end
            end
        end)
        AdvanceScanQueue()
    end
end

-- ====================================================
-- SCAN DE TOUS LES MÉTIERS
-- ====================================================
function ns.ScanAllProfessions()
    if scanInProgress then
        ns.Debug("|cffff8800[VL-Prof]|r " .. ns.L("DBG_SCAN_IN_PROGRESS"))
        return
    end

    local slots = CollectAllProfessionSlots()
    if #slots == 0 then
        ns.Debug("|cffff8800[VL-Prof]|r " .. ns.L("DBG_NO_PROFESSION_FOUND"))
        return
    end

    ns.Debug("|cff00aaff[VL-Prof]|r " .. ns.L("DBG_SCAN_START"), #slots)

    local charData = GetCharData()
    if charData then PurgeRemovedProfessions(charData, slots) end

    scanQueue      = slots
    scanQueueIndex = 0
    scanInProgress = true
    AdvanceScanQueue()
end

-- ====================================================
-- HOOKS DES ÉVÉNEMENTS (appelés par Init.lua)
-- ====================================================

-- PLAYER_LOGIN :
-- · +9 s : initialise le cache local des rangs
-- · +10 s : déclenche le scan approfondi si des métiers n'ont pas encore
--   été scannés en profondeur (le scan de base a peuplé charData à +8 s).
function ns.OnDeepLogin()
    C_Timer.After(9, function()
        ForEachProf(function(idx)
            local name, _, rank = GetProfessionInfo(idx)
            if name then lastKnownRanks[name] = rank end
        end)
    end)

    C_Timer.After(10, function()
        local charData = GetCharData()
        if not charData or not charData.professions then return end
        local needsFirstScan = false
        for _, p in ipairs(charData.professions) do
            if not p.scanned then needsFirstScan = true; break end
        end
        if not needsFirstScan then return end
        ns.Debug("|cffffd700[VL-Prof]|r " .. ns.L("DBG_FIRST_SCAN"))
        ns.ScanAllProfessions()
    end)
end

-- SKILL_LINES_CHANGED — rescan sur progression de rang. lastKnownRanks
-- (cache local) détecte les changements sans dépendre de basicRank en base.
local skillUpdatePending = false

function ns.OnDeepSkillLinesChanged()
    if skillUpdatePending then return end
    skillUpdatePending = true
    C_Timer.After(3, function()
        skillUpdatePending = false
        if scanInProgress then return end

        local toRescan = {}
        ForEachProf(function(idx)
            local name, _, rank = GetProfessionInfo(idx)
            if name then
                if lastKnownRanks[name] ~= rank then
                    for _, s in ipairs(CollectAllProfessionSlots()) do
                        if s.name == name then
                            toRescan[#toRescan + 1] = s
                            break
                        end
                    end
                end
                lastKnownRanks[name] = rank
            end
        end)

        if #toRescan == 0 then return end
        ns.Debug("|cff00aaff[VL-Prof]|r " .. ns.L("DBG_PROGRESS_RESCAN"), #toRescan)
        scanQueue      = toRescan
        scanQueueIndex = 0
        scanInProgress = true
        AdvanceScanQueue()
    end)
end

-- TRADE_SKILL_SHOW — seul déclencheur légal du scan approfondi.
-- Pas de return prématuré si professions pas encore init :
-- ScanOpenProfession() crée l'entrée au besoin.
function ns.OnTradeSkillShow()
    local profName
    local baseInfo = C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo()
    if baseInfo and baseInfo.professionName and baseInfo.professionName ~= "" then
        profName = baseInfo.professionName
    else
        local skillLineID = C_TradeSkillUI.GetTradeSkillLine and C_TradeSkillUI.GetTradeSkillLine()
        if not skillLineID or skillLineID == 0 then return end
        profName = C_TradeSkillUI.GetTradeSkillDisplayName and C_TradeSkillUI.GetTradeSkillDisplayName(skillLineID)
    end
    if not profName then return end

    local charData = GetCharData()
    local entry = nil
    if charData and charData.professions then
        for _, p in ipairs(charData.professions) do
            if p.name == profName then entry = p; break end
        end
    end

    C_Timer.After(0.5, function()
        if not C_TradeSkillUI.IsTradeSkillReady or not C_TradeSkillUI.IsTradeSkillReady() then
            return
        end
        ns.Debug("|cff00aaff[VL-Prof]|r " .. ns.L("DBG_PASSIVE_SCAN"), profName)
        ns.ScanOpenProfession(profName, entry)
    end)
end
