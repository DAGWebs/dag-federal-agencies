-- Financial subpoenas.
--
-- An FIB agent (any officer with the warrant permission) can subpoena a
-- citizen's bank records. A judge or DOJ member signs it; if none is online it
-- is granted automatically ONLY when there is already sufficient evidence on
-- file -- counted from the financial-crime incidents the bank has filed against
-- that citizen. Once granted, the officer pulls the records straight from the
-- banking resource's read-only export.

DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Util = Federal.Util
local Core = Federal.Core

local Subpoena = {}
Federal.Subpoena = Subpoena

local subpoenas = DAG.Repository.Create('federal_subpoenas')
local incidents = DAG.Repository.Create('federal_incidents')
Subpoena.repository = subpoenas

-- Tuning. Editable here; kept local so it does not collide with any other
-- config table.
local SETTINGS = {
    permission = 'cad.warrant',          -- who may file (FIB grade >= 2 by default)
    -- Financial-crime incidents already on file against the target that make a
    -- judge unnecessary when none is online.
    autoGrantEvidence = 3,
    -- Jobs whose members can sign a subpoena. Falls back to the court config.
    judgeJobs = (Config.Federal and Config.Federal.court and Config.Federal.court.judgeJobs) or { 'judge', 'justice' },
    recordLimit = 200
}

local function judgeSet()
    local set = {}
    for _, job in ipairs(SETTINGS.judgeJobs) do set[job] = true end
    return set
end

local function judgeOnline()
    local set = judgeSet()
    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        local job = src and Bridge.GetJob(src)
        if job and set[job.name] then return true end
    end
    return false
end

local function notifyJudges(message)
    local set = judgeSet()
    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        local job = src and Bridge.GetJob(src)
        if job and set[job.name] then Bridge.Notify(src, message, 'inform', 12000) end
    end
end

-- Evidence = how many tips/reports name this citizen across the FIB's cases.
-- The bank consolidates a suspect's financial crime into one ongoing incident
-- and appends each new report as a narrative tip, so the weight of the case is
-- the number of tips, not the number of separate incidents. Each narrative
-- entry counts; an incident with no narrative still counts once for existing.
function Subpoena.EvidenceFor(identifier)
    local count = 0
    for _, incident in pairs(incidents.all()) do
        local named = false
        for _, suspect in ipairs(incident.suspects or {}) do
            if suspect.identifier == identifier then named = true break end
        end
        if named then
            local tips = #(incident.narrative or {})
            count = count + math.max(tips, 1)
        end
    end
    return count
end

-- Resolves a target from a command argument: an online server id, or a raw
-- identifier/citizenid string.
local function resolveTarget(ref)
    local src = tonumber(ref)
    if src and GetPlayerName(src) then
        return Bridge.GetIdentifier(src), Bridge.GetName(src)
    end
    if type(ref) == 'string' and ref ~= '' then
        return ref, nil
    end
    return nil, nil
end

function Subpoena.File(source, targetRef, reason)
    local membership = Core.Require(source, SETTINGS.permission)
    if not membership then return nil, 'not authorized' end

    local identifier, name = resolveTarget(targetRef)
    if not identifier then return nil, 'No such citizen. Give a player id or citizen id.' end

    reason = Util.Text(reason, 200) or 'Financial investigation'
    local evidence = Subpoena.EvidenceFor(identifier)
    -- 'subpoena' is not a core series, so NextNumber gives it its own counter
    -- (code REC) rather than consuming warrant numbers.
    local number, sequence = Core.NextNumber(membership.agency.id, 'subpoena')

    local record = {
        id = Util.RecordId('sub', sequence),
        number = number,
        agency = membership.agency.id,
        target = { identifier = identifier, name = name },
        reason = reason,
        evidence = evidence,
        status = 'pending',
        requestedBy = { identifier = membership.identifier, name = membership.name },
        createdAt = os.time()
    }

    if judgeOnline() then
        record.note = 'Awaiting a judge signature.'
        notifyJudges(('%s requests a financial subpoena on %s. Sign with /subpoena-sign %s'):format(
            membership.name, name or identifier, record.number))
    elseif evidence >= SETTINGS.autoGrantEvidence then
        record.status = 'granted'
        record.grantedBy = { name = 'Auto-granted (sufficient evidence)' }
        record.grantedAt = os.time()
        Bridge.Notify(source, ('Subpoena %s granted: %d incidents on file.'):format(record.number, evidence), 'success')
    else
        record.note = ('No judge online and only %d/%d incidents on file. Awaiting a judge or more evidence.'):format(
            evidence, SETTINGS.autoGrantEvidence)
        Bridge.Notify(source, record.note, 'error')
    end

    subpoenas.save(record.id, record)
    return record
end

function Subpoena.Sign(source, numberOrId)
    local job = Bridge.GetJob(source)
    if not job or not judgeSet()[job.name] then return nil, 'Only a judge may sign a subpoena.' end

    local record = subpoenas.get(numberOrId)
    if not record then
        for _, entry in pairs(subpoenas.all()) do
            if entry.number == numberOrId then record = entry break end
        end
    end
    if not record then return nil, 'No such subpoena.' end
    if record.status == 'granted' then return nil, 'That subpoena is already granted.' end

    record.status = 'granted'
    record.grantedBy = { identifier = Bridge.GetIdentifier(source), name = Bridge.GetName(source) }
    record.grantedAt = os.time()
    subpoenas.save(record.id, record)

    local requester = record.requestedBy and record.requestedBy.identifier
    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        if src and Bridge.GetIdentifier(src) == requester then
            Bridge.Notify(src, ('Subpoena %s was signed. Pull the records with /subpoena-records %s'):format(
                record.number, record.number), 'success')
        end
    end
    return record
end

local function findRecord(ref)
    local record = subpoenas.get(ref)
    if record then return record end
    for _, entry in pairs(subpoenas.all()) do
        if entry.number == ref then return entry end
    end
    return nil
end

function Subpoena.Pull(source, ref)
    local membership = Core.Require(source, 'cad.view')
    if not membership then return nil, 'not authorized' end

    local record = findRecord(ref)
    if not record then return nil, 'No such subpoena.' end
    if record.status ~= 'granted' then return nil, 'That subpoena has not been granted.' end
    if record.agency ~= membership.agency.id then return nil, 'That subpoena belongs to another agency.' end

    if GetResourceState('dag-banking') ~= 'started' then return nil, 'The bank is unreachable.' end
    local ok, profile = pcall(function()
        return exports['dag-banking']:GetFinancialProfile(record.target.identifier, { limit = SETTINGS.recordLimit })
    end)
    if not ok or not profile then return nil, 'No records were returned.' end

    profile.subpoena = { number = record.number, reason = record.reason }
    return profile
end

function Subpoena.List(source)
    local membership = Core.Membership(source)
    if not membership then return {} end
    local list = {}
    for _, entry in pairs(subpoenas.all()) do
        if entry.agency == membership.agency.id then list[#list + 1] = entry end
    end
    table.sort(list, function(a, b) return (a.createdAt or 0) > (b.createdAt or 0) end)
    return list
end

-- Net wiring -------------------------------------------------------------------

Bridge.RegisterCallback(Federal.Net('subpoena:file'), function(source, reply, targetRef, reason)
    local record, message = Subpoena.File(source, targetRef, reason)
    reply(record, message)
end)

Bridge.RegisterCallback(Federal.Net('subpoena:sign'), function(source, reply, ref)
    local record, message = Subpoena.Sign(source, ref)
    reply(record, message)
end)

Bridge.RegisterCallback(Federal.Net('subpoena:pull'), function(source, reply, ref)
    local profile, message = Subpoena.Pull(source, ref)
    reply(profile, message)
end)

Bridge.RegisterCallback(Federal.Net('subpoena:list'), function(source, reply)
    reply(Subpoena.List(source))
end)

return Subpoena
