-- Investigation leads.
--
-- Analysing evidence used to write a string and unlock nothing: the callout
-- ran the same five stages whatever you found, so collecting evidence was a
-- chore rather than a clue.
--
-- A lead is what an analysed item actually tells you, and it changes the case:
-- a partial plate you run in the CAD to get a keeper, an address that puts a
-- new search location on the map, a name that reveals who the suspect is. The
-- callout's optional stages open as leads are followed, so two runs of the
-- same template diverge on what the officers found.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Util = Federal.Util
local Const = Federal.Constants
local Core = Federal.Core
local CAD = Federal.CAD

local Leads = {}
Federal.Leads = Leads

local leads = DAG.Repository.Create('federal_leads')
Leads.repository = leads

local function fail(message)
    return nil, message
end

-- Plates are generated rather than read off a real vehicle: the lead is a
-- partial lifted from a document, and the point is that it has to be run.
local PLATE_LETTERS = 'ABCDEFGHJKLMNPQRSTUVWXYZ'

function Leads.GeneratePlate()
    local plate = {}
    for index = 1, 8 do
        if index <= 2 or index >= 7 then
            local pick = math.random(#PLATE_LETTERS)
            plate[index] = PLATE_LETTERS:sub(pick, pick)
        else
            plate[index] = tostring(math.random(0, 9))
        end
    end
    return table.concat(plate)
end

-- What a given evidence kind can yield. An item that cannot produce a lead is
-- still worth collecting -- it strengthens the case in court -- it just does
-- not move the investigation on.
local KIND_LEADS = {
    document  = { 'plate', 'address', 'ledger' },
    print     = { 'name', 'contact' },
    dna       = { 'name' },
    casing    = { 'contact' },
    substance = { 'address', 'contact' }
}

function Leads.KindsFor(evidenceKind)
    return KIND_LEADS[evidenceKind]
end

-- Raised when an item is analysed at the lab. Returns the lead it produced, or
-- nil when that kind yields nothing.
function Leads.FromEvidence(source, evidence)
    if type(evidence) ~= 'table' or not evidence.calloutId then return nil end

    local possible = KIND_LEADS[evidence.kind]
    if not possible or #possible == 0 then return nil end

    local membership = Core.Membership(source)
    if not membership then return nil end

    -- An identifying item that matched somebody always names them: that is
    -- what the match IS, and rolling for it would throw the result away.
    local kind = possible[math.random(#possible)]
    if evidence.match then kind = 'name' end

    return Leads.Create(membership, {
        calloutId = evidence.calloutId,
        kind = kind,
        evidenceId = evidence.id,
        subject = evidence.match or evidence.subject
    })
end

function Leads.Create(membership, payload)
    payload = type(payload) == 'table' and payload or {}
    local kind = payload.kind
    if not Const.LeadKinds[kind] then return fail('unknown lead kind') end

    local number, sequence = Core.NextNumber(membership.agency.id, 'lead')
    local lead = {
        id = Util.RecordId('led', sequence),
        number = number,
        agency = membership.agency.id,
        calloutId = payload.calloutId,
        evidenceId = payload.evidenceId,
        kind = kind,
        status = 'open',
        subject = payload.subject,
        createdAt = os.time()
    }

    -- Each kind carries the concrete thing the officer now has to act on.
    if kind == 'plate' then
        lead.plate = Leads.GeneratePlate()
        lead.summary = ('A partial plate: %s. Run it in the CAD.'):format(lead.plate)
    elseif kind == 'address' then
        local point = Leads.NearbyPoint(payload.calloutId)
        lead.location = point
        lead.summary = 'An address. A second location is marked on your map.'
    elseif kind == 'name' then
        local record = payload.subject and CAD.records.get(payload.subject)
        lead.name = record and record.name or nil
        lead.summary = record
            and ('The subject is named: %s.'):format(record.name)
            or 'A name, but nobody on file matches it.'
    elseif kind == 'contact' then
        lead.summary = 'A known associate is willing to talk. They are at the scene.'
    elseif kind == 'ledger' then
        lead.summary = 'Financial records tying the subject to the offence.'
    end

    leads.save(lead.id, lead)
    return lead
end

-- Where an "address" lead points. Offset from the callout so it is a genuine
-- second location rather than the same scene again.
function Leads.NearbyPoint(calloutId)
    local callout = Federal.Callouts and Federal.Callouts.Get(calloutId)
    local origin = callout and callout.location or { x = 0.0, y = 0.0, z = 0.0 }

    local angle = math.random() * math.pi * 2
    local distance = 120.0 + (math.random() * 180.0)
    return {
        x = origin.x + (math.cos(angle) * distance),
        y = origin.y + (math.sin(angle) * distance),
        z = origin.z
    }
end

function Leads.For(source, calloutId)
    if not Core.Can(source, 'cad.view') then return {} end

    local allowed = Core.ReadableAgencies(source)
    local list = {}
    for _, lead in pairs(leads.all()) do
        if allowed[lead.agency] and (calloutId == nil or lead.calloutId == calloutId) then
            list[#list + 1] = lead
        end
    end
    table.sort(list, function(a, b) return (a.createdAt or 0) < (b.createdAt or 0) end)
    return list
end

function Leads.Get(id)
    return leads.get(id)
end

-- Running a plate is the one lead that is worked in the CAD rather than in the
-- world, so it resolves here: it names a keeper and, when that keeper is the
-- suspect, reveals them.
function Leads.RunPlate(source, plate)
    local membership = Core.Require(source, 'cad.view')
    if not membership then return fail('not authorized') end

    local wanted = Util.Text(plate, 12)
    if not wanted then return fail('no plate given') end
    wanted = wanted:upper():gsub('%s', '')

    for _, lead in pairs(leads.all()) do
        if lead.kind == 'plate' and lead.plate == wanted then
            local callout = Federal.Callouts and Federal.Callouts.Get(lead.calloutId)
            local suspect = callout and callout.suspect

            lead.status = 'followed'
            lead.keeper = suspect and suspect.name or 'an unregistered keeper'
            leads.save(lead.id, lead)

            if callout then Federal.Callouts.Reveal(callout, lead) end
            return lead
        end
    end

    -- A plate that matches nothing is a real outcome, not an error.
    return { plate = wanted, status = 'cold', summary = 'No registered keeper on file.' }
end

function Leads.Follow(source, leadId)
    local membership = Core.Require(source, 'cad.view')
    if not membership then return fail('not authorized') end

    local lead = leads.get(leadId)
    if not lead then return fail('no such lead') end
    if lead.status ~= 'open' then return fail('that lead has already been worked') end

    lead.status = 'followed'
    lead.followedBy = membership.name
    leads.save(lead.id, lead)

    local callout = Federal.Callouts and Federal.Callouts.Get(lead.calloutId)
    if callout then Federal.Callouts.Reveal(callout, lead) end
    return lead
end

-- Net wiring -------------------------------------------------------------------

Bridge.RegisterCallback(Federal.Net('leads'), function(source, reply, calloutId)
    reply(Leads.For(source, calloutId))
end)

Bridge.RegisterCallback(Federal.Net('leads:plate'), function(source, reply, plate)
    local lead, message = Leads.RunPlate(source, plate)
    reply(lead, message)
end)

Bridge.RegisterCallback(Federal.Net('leads:follow'), function(source, reply, leadId)
    local lead, message = Leads.Follow(source, leadId)
    reply(lead, message)
end)

return Leads
