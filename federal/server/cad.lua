-- The CAD: incidents, warrants, BOLOs, citizen records and evidence.
--
-- Every agency gets its own CAD, configured by its `cad` block: which modules
-- are enabled, the case-number prefix, and which other agencies may read its
-- records. Reads are filtered through Core.ReadableAgencies; writes always
-- require membership of the owning agency, so a shared read grant can never
-- become a write.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Util = Federal.Util
local Const = Federal.Constants
local Core = Federal.Core

local CAD = {}
Federal.CAD = CAD

local MAX_CHARGES = 20
local MAX_NARRATIVE = 12

local incidents = DAG.Repository.Create('federal_incidents')
local warrants = DAG.Repository.Create('federal_warrants')
local bolos = DAG.Repository.Create('federal_bolos')
local records = DAG.Repository.Create('federal_records')
local evidence = DAG.Repository.Create('federal_evidence')

CAD.incidents, CAD.warrants, CAD.bolos, CAD.records, CAD.evidence = incidents, warrants, bolos, records, evidence

local function fail(message)
    return nil, message
end

local function now()
    return os.time()
end

-- Charges arrive from a player-typed input box.
local function normalizeCharges(input)
    local list = {}
    if type(input) ~= 'table' then return list end
    for _, charge in ipairs(input) do
        local text = Util.Text(charge, 80)
        if text and #list < MAX_CHARGES then list[#list + 1] = text end
    end
    return list
end

-- A module can be switched off per agency; asking for a disabled one is an
-- error rather than an empty list, so the client menu and the server agree.
local function moduleEnabled(agency, name)
    local cad = agency and agency.cad
    return cad ~= nil and cad.enabled ~= false and cad.modules[name] ~= false
end

function CAD.RequireModule(source, permission, name, options)
    local membership = Core.Require(source, permission, options)
    if not membership then return nil end
    if not moduleEnabled(membership.agency, name) then
        Bridge.Notify(source, ('The %s module is disabled for your agency.'):format(name), 'error')
        return nil
    end
    return membership
end

-- Reading -------------------------------------------------------------------

local function readable(source)
    if not Core.Can(source, 'cad.view') then return nil end
    return Core.ReadableAgencies(source)
end

local function filterByAgency(repository, allowed, predicate)
    local list = {}
    for _, record in pairs(repository.all()) do
        if allowed[record.agency] and (not predicate or predicate(record)) then
            list[#list + 1] = record
        end
    end
    table.sort(list, function(a, b) return (a.createdAt or 0) > (b.createdAt or 0) end)
    return list
end

function CAD.Incidents(source, filter)
    local allowed = readable(source)
    if not allowed then return {} end
    filter = filter or {}
    return filterByAgency(incidents, allowed, function(record)
        if filter.status and record.status ~= filter.status then return false end
        if filter.open and record.status == 'closed' then return false end
        return true
    end)
end

function CAD.Incident(source, id)
    local allowed = readable(source)
    if not allowed then return nil end
    local record = incidents.get(id)
    if not record or not allowed[record.agency] then return nil end
    return record
end

function CAD.Warrants(source, filter)
    local allowed = readable(source)
    if not allowed then return {} end
    filter = filter or {}
    return filterByAgency(warrants, allowed, function(record)
        if filter.status then return record.status == filter.status end
        return true
    end)
end

function CAD.Bolos(source)
    local allowed = readable(source)
    if not allowed then return {} end
    return filterByAgency(bolos, allowed, function(record) return record.status == 'active' end)
end

function CAD.EvidenceFor(source, incidentId)
    local allowed = readable(source)
    if not allowed then return {} end
    return filterByAgency(evidence, allowed, function(record)
        return incidentId == nil or record.incidentId == incidentId
    end)
end

-- Any agency may look up an active warrant, whoever issued it: a warrant is
-- the one CAD record that is useless if it is not visible force-wide.
function CAD.ActiveWarrantFor(identifier)
    if type(identifier) ~= 'string' then return nil end
    for _, record in pairs(warrants.all()) do
        if record.status == 'active' and record.target and record.target.identifier == identifier then
            return record
        end
    end
    return nil
end

function CAD.Dashboard(source)
    local allowed = readable(source)
    if not allowed then return nil end

    local membership = Core.Membership(source)
    local open, activeWarrants, activeBolos = 0, 0, 0
    for _, record in pairs(incidents.all()) do
        if allowed[record.agency] and record.status ~= 'closed' then open = open + 1 end
    end
    for _, record in pairs(warrants.all()) do
        if allowed[record.agency] and record.status == 'active' then activeWarrants = activeWarrants + 1 end
    end
    for _, record in pairs(bolos.all()) do
        if allowed[record.agency] and record.status == 'active' then activeBolos = activeBolos + 1 end
    end

    return {
        openIncidents = open,
        activeWarrants = activeWarrants,
        activeBolos = activeBolos,
        units = membership and Core.Units(membership.agency.id) or {},
        agency = membership and membership.agency.short or nil
    }
end

-- Incidents ------------------------------------------------------------------

function CAD.FileIncident(source, payload)
    payload = type(payload) == 'table' and payload or {}
    local membership = CAD.RequireModule(source, 'cad.write', 'incidents')
    if not membership then return fail('not authorized') end

    local title = Util.Text(payload.title, 80)
    if not title then return fail('an incident requires a title') end

    local number, sequence = Core.NextNumber(membership.agency.id, 'incident')
    local record = {
        id = Util.RecordId('inc', sequence),
        number = number,
        agency = membership.agency.id,
        title = title,
        type = Util.Text(payload.type, 40, 'General'),
        status = 'open',
        priority = math.floor(Util.Clamp(tonumber(payload.priority) or 2, 1, 3)),
        charges = normalizeCharges(payload.charges),
        suspects = {},
        officers = { { identifier = membership.identifier, name = membership.name } },
        narrative = {},
        location = Util.ToCoords(payload.location),
        calloutId = Util.Text(payload.calloutId, 40),
        createdBy = membership.name,
        createdAt = now(),
        updatedAt = now()
    }

    local narrative = Util.Text(payload.narrative, 1000)
    if narrative then
        record.narrative[1] = { author = membership.name, text = narrative, at = now() }
    end

    incidents.save(record.id, record)
    return record
end

-- Shared guard for every incident mutation: the record must exist, and the
-- officer must belong to the agency that owns it. A shared read grant is not
-- a licence to edit another agency's case.
local function ownedIncident(source, id, permission)
    local membership = Core.Require(source, permission or 'cad.write')
    if not membership then return nil end

    local record = incidents.get(id)
    if not record then
        Bridge.Notify(source, 'That incident no longer exists.', 'error')
        return nil
    end
    if record.agency ~= membership.agency.id and not Core.IsAdmin(source) then
        Bridge.Notify(source, 'That case belongs to another agency.', 'error')
        return nil
    end
    return membership, record
end

function CAD.AddNarrative(source, id, text)
    local membership, record = ownedIncident(source, id)
    if not membership then return fail('not authorized') end

    local entry = Util.Text(text, 1000)
    if not entry then return fail('the narrative entry is empty') end
    if record.status == 'closed' then return fail('that case is closed') end

    record.narrative = record.narrative or {}
    -- Oldest entries fall off rather than letting one case grow without bound.
    if #record.narrative >= MAX_NARRATIVE then table.remove(record.narrative, 1) end
    record.narrative[#record.narrative + 1] = { author = membership.name, text = entry, at = now() }
    record.updatedAt = now()

    incidents.save(record.id, record)
    return record
end

function CAD.AttachSuspect(source, id, suspect)
    local membership, record = ownedIncident(source, id)
    if not membership then return fail('not authorized') end
    suspect = type(suspect) == 'table' and suspect or {}

    local identifier = Util.Text(suspect.identifier, 80)
    local name = Util.Text(suspect.name, 60, 'Unknown subject')
    if not identifier then return fail('a suspect requires an identifier') end

    record.suspects = record.suspects or {}
    for _, existing in ipairs(record.suspects) do
        if existing.identifier == identifier then return fail('that suspect is already on the case') end
    end

    record.suspects[#record.suspects + 1] = {
        identifier = identifier,
        name = name,
        charges = normalizeCharges(suspect.charges)
    }
    record.updatedAt = now()
    incidents.save(record.id, record)
    return record
end

function CAD.AssignOfficer(source, id, target)
    local membership, record = ownedIncident(source, id)
    if not membership then return fail('not authorized') end

    local identifier = Bridge.GetIdentifier(target)
    if not identifier then return fail('that officer is not online') end

    record.officers = record.officers or {}
    for _, officer in ipairs(record.officers) do
        if officer.identifier == identifier then return fail('already assigned') end
    end
    record.officers[#record.officers + 1] = { identifier = identifier, name = Bridge.GetName(target) }
    record.updatedAt = now()

    incidents.save(record.id, record)
    return record
end

function CAD.SetIncidentStatus(source, id, status)
    local membership, record = ownedIncident(source, id)
    if not membership then return fail('not authorized') end
    if not Util.Contains(Const.IncidentStatus, status) then return fail('unknown status') end

    record.status = status
    record.updatedAt = now()
    incidents.save(record.id, record)
    return record
end

function CAD.DeleteIncident(source, id)
    local membership, record = ownedIncident(source, id, 'cad.expunge')
    if not membership then return fail('not authorized') end
    incidents.delete(record.id)
    return record
end

-- Warrants -------------------------------------------------------------------

function CAD.IssueWarrant(source, payload)
    payload = type(payload) == 'table' and payload or {}
    local membership = CAD.RequireModule(source, 'cad.warrant', 'warrants')
    if not membership then return fail('not authorized') end

    local identifier = Util.Text(payload.identifier, 80)
    local reason = Util.Text(payload.reason, 300)
    if not identifier then return fail('a warrant requires a subject identifier') end
    if not reason then return fail('a warrant requires a stated reason') end

    if CAD.ActiveWarrantFor(identifier) then return fail('that subject already has an active warrant') end

    local number, sequence = Core.NextNumber(membership.agency.id, 'warrant')
    local record = {
        id = Util.RecordId('wnt', sequence),
        number = number,
        agency = membership.agency.id,
        target = { identifier = identifier, name = Util.Text(payload.name, 60, 'Unknown subject') },
        reason = reason,
        charges = normalizeCharges(payload.charges),
        status = 'active',
        incidentId = Util.Text(payload.incidentId, 40),
        issuedBy = membership.name,
        createdAt = now()
    }

    warrants.save(record.id, record)
    CAD.Note(identifier, record.target.name, ('Warrant %s issued by %s'):format(number, membership.agency.short))
    return record
end

function CAD.SetWarrantStatus(source, id, status)
    local membership = Core.Require(source, 'cad.warrant')
    if not membership then return fail('not authorized') end
    if not Util.Contains(Const.WarrantStatus, status) then return fail('unknown warrant status') end

    local record = warrants.get(id)
    if not record then return fail('that warrant no longer exists') end
    if record.agency ~= membership.agency.id and not Core.IsAdmin(source) then
        return fail('that warrant belongs to another agency')
    end

    record.status = status
    record.closedBy = membership.name
    record.closedAt = now()
    warrants.save(record.id, record)
    return record
end

-- BOLOs -----------------------------------------------------------------------

function CAD.CreateBolo(source, payload)
    payload = type(payload) == 'table' and payload or {}
    local membership = CAD.RequireModule(source, 'cad.write', 'bolos')
    if not membership then return fail('not authorized') end

    local kind = payload.kind
    if not Util.Contains(Const.BoloKinds, kind) then return fail('a BOLO is for a person or a vehicle') end

    local subject = Util.Text(payload.subject, 80)
    if not subject then return fail('a BOLO requires a subject') end

    local number, sequence = Core.NextNumber(membership.agency.id, 'bolo')
    local record = {
        id = Util.RecordId('blo', sequence),
        number = number,
        agency = membership.agency.id,
        kind = kind,
        subject = subject,
        plate = Util.Text(payload.plate, 12),
        description = Util.Text(payload.description, 300, 'No description given'),
        status = 'active',
        createdBy = membership.name,
        createdAt = now()
    }

    bolos.save(record.id, record)
    return record
end

function CAD.CloseBolo(source, id)
    local membership = Core.Require(source, 'cad.write')
    if not membership then return fail('not authorized') end

    local record = bolos.get(id)
    if not record then return fail('that BOLO no longer exists') end
    if record.agency ~= membership.agency.id and not Core.IsAdmin(source) then
        return fail('that BOLO belongs to another agency')
    end

    record.status = 'closed'
    record.closedBy = membership.name
    bolos.save(record.id, record)
    return record
end

-- Citizen records --------------------------------------------------------------

-- Records are keyed by the framework identifier, so they follow the character
-- rather than the player's current session.
function CAD.Record(identifier, name)
    if type(identifier) ~= 'string' or identifier == '' then return nil end
    local record = records.get(identifier)
    if record then
        if name and record.name ~= name then
            record.name = name
            records.save(identifier, record)
        end
        return record
    end

    record = {
        identifier = identifier,
        name = name or 'Unknown subject',
        arrests = {},
        fines = {},
        notes = {},
        printed = false
    }
    records.save(identifier, record)
    return record
end

function CAD.Note(identifier, name, text)
    local record = CAD.Record(identifier, name)
    if not record then return nil end
    local entry = Util.Text(text, 300)
    if not entry then return record end

    record.notes = record.notes or {}
    if #record.notes >= 30 then table.remove(record.notes, 1) end
    record.notes[#record.notes + 1] = { text = entry, at = now() }
    records.save(identifier, record)
    return record
end

function CAD.LogArrest(source, payload)
    payload = type(payload) == 'table' and payload or {}
    local membership = Core.Require(source, 'actions.arrest')
    if not membership then return fail('not authorized') end

    local identifier = Util.Text(payload.identifier, 80)
    if not identifier then return fail('an arrest requires a subject identifier') end

    local record = CAD.Record(identifier, Util.Text(payload.name, 60, 'Unknown subject'))
    record.arrests = record.arrests or {}
    record.arrests[#record.arrests + 1] = {
        agency = membership.agency.id,
        officer = membership.name,
        charges = normalizeCharges(payload.charges),
        incidentId = Util.Text(payload.incidentId, 40),
        at = now()
    }
    records.save(identifier, record)
    return record
end

function CAD.LogFine(source, identifier, name, amount, reason)
    local membership = Core.Require(source, 'actions.arrest')
    if not membership then return fail('not authorized') end

    local record = CAD.Record(Util.Text(identifier, 80), Util.Text(name, 60, 'Unknown subject'))
    if not record then return fail('a fine requires a subject identifier') end

    record.fines = record.fines or {}
    record.fines[#record.fines + 1] = {
        agency = membership.agency.id,
        officer = membership.name,
        amount = amount,
        reason = Util.Text(reason, 200, 'Federal citation'),
        at = now()
    }
    records.save(record.identifier, record)
    return record
end

function CAD.LookupRecord(source, identifier)
    if not readable(source) then return nil end
    local record = records.get(identifier)
    if not record then return nil end

    record.warrant = CAD.ActiveWarrantFor(identifier)
    return record
end

function CAD.SearchRecords(source, term)
    if not readable(source) then return {} end
    local needle = Util.Text(term, 60)
    if not needle then return {} end
    needle = needle:lower()

    local matches = {}
    for _, record in pairs(records.all()) do
        local name = tostring(record.name or ''):lower()
        if name:find(needle, 1, true) or tostring(record.identifier):lower():find(needle, 1, true) then
            matches[#matches + 1] = record
        end
    end
    table.sort(matches, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return matches
end

-- Evidence ---------------------------------------------------------------------

-- `subject` is the identifier the evidence came from. It is stored but not
-- revealed until the lab analyses the item, which is the whole point of having
-- a lab: collecting a DNA swab does not tell you whose it is.
function CAD.CollectEvidence(source, payload)
    payload = type(payload) == 'table' and payload or {}
    local membership = CAD.RequireModule(source, 'actions.evidence', 'evidence')
    if not membership then return fail('not authorized') end

    local kind = payload.kind
    if not Const.EvidenceKinds[kind] then return fail('unknown evidence kind') end

    local number, sequence = Core.NextNumber(membership.agency.id, 'evidence')
    local record = {
        id = Util.RecordId('evd', sequence),
        number = number,
        agency = membership.agency.id,
        kind = kind,
        label = Util.Text(payload.label, 80, Const.EvidenceKinds[kind].label),
        incidentId = Util.Text(payload.incidentId, 40),
        calloutId = Util.Text(payload.calloutId, 40),
        subject = Util.Text(payload.subject, 80),
        location = Util.ToCoords(payload.location),
        analysed = false,
        result = nil,
        collectedBy = membership.name,
        collectedAt = now(),
        chain = { { actor = membership.name, action = 'collected', at = now() } }
    }

    evidence.save(record.id, record)
    return record
end

function CAD.AnalyseEvidence(source, id)
    local membership = CAD.RequireModule(source, 'actions.evidence', 'evidence')
    if not membership then return fail('not authorized') end

    -- The lab is a place, not a menu item.
    local allowed = Core.RequireZone(source, membership, 'evidence')
    if not allowed then return fail('not at an evidence lab') end

    local record = evidence.get(id)
    if not record then return fail('that evidence item no longer exists') end
    if record.agency ~= membership.agency.id and not Core.IsAdmin(source) then
        return fail('that item belongs to another agency')
    end
    if record.analysed then return fail('that item has already been analysed') end

    local kind = Const.EvidenceKinds[record.kind]
    if not kind or not kind.analysable then return fail('that item cannot be analysed') end

    record.analysed = true
    if kind.identifies then
        -- An identifying kind only ever matches somebody who is already on
        -- file. A swab from a subject with no record is a dead end, which is
        -- what makes fingerprinting a suspect worth doing.
        local match = record.subject and records.get(record.subject) or nil
        if match then
            record.result = ('Match: %s'):format(match.name)
            record.match = record.subject
            CAD.Note(record.subject, match.name, ('%s %s matched this subject'):format(kind.label, record.number))
        else
            record.result = 'No match on file'
        end
    else
        record.result = ('%s processed; consistent with the scene'):format(kind.label)
    end

    record.chain[#record.chain + 1] = { actor = membership.name, action = 'analysed', at = now() }
    evidence.save(record.id, record)
    return record
end

function CAD.AttachEvidence(source, evidenceId, incidentId)
    local membership, record = ownedIncident(source, incidentId)
    if not membership then return fail('not authorized') end

    local item = evidence.get(evidenceId)
    if not item then return fail('that evidence item no longer exists') end
    if item.agency ~= membership.agency.id and not Core.IsAdmin(source) then
        return fail('that item belongs to another agency')
    end

    item.incidentId = record.id
    item.chain[#item.chain + 1] = { actor = membership.name, action = 'attached to ' .. record.number, at = now() }
    evidence.save(item.id, item)
    return item
end

-- Net wiring ---------------------------------------------------------------
--
-- Reads go through callbacks so the client gets the filtered result back;
-- writes go through callbacks too, because the officer who filed a case needs
-- its number to keep working with it.

local function readCallback(name, handler)
    Bridge.RegisterCallback(Federal.Net('cad:' .. name), function(source, reply, ...)
        reply(handler(source, ...))
    end)
end

readCallback('dashboard', CAD.Dashboard)
readCallback('incidents', function(source, filter) return CAD.Incidents(source, type(filter) == 'table' and filter or nil) end)
readCallback('incident', function(source, id) return CAD.Incident(source, id) end)
readCallback('warrants', function(source, filter) return CAD.Warrants(source, type(filter) == 'table' and filter or nil) end)
readCallback('bolos', CAD.Bolos)
readCallback('evidence', function(source, incidentId) return CAD.EvidenceFor(source, incidentId) end)
readCallback('records', function(source, term) return CAD.SearchRecords(source, term) end)
readCallback('record', function(source, identifier) return CAD.LookupRecord(source, identifier) end)

local function writeCallback(name, handler)
    Bridge.RegisterCallback(Federal.Net('cad:' .. name), function(source, reply, ...)
        local record, message = handler(source, ...)
        if not record and message then Bridge.Notify(source, message, 'error') end
        reply(record, message)
    end)
end

writeCallback('file', CAD.FileIncident)
writeCallback('narrative', CAD.AddNarrative)
writeCallback('suspect', CAD.AttachSuspect)
writeCallback('status', CAD.SetIncidentStatus)
writeCallback('expunge', CAD.DeleteIncident)
writeCallback('warrant', CAD.IssueWarrant)
writeCallback('warrantStatus', CAD.SetWarrantStatus)
writeCallback('bolo', CAD.CreateBolo)
writeCallback('boloClose', CAD.CloseBolo)
writeCallback('collect', CAD.CollectEvidence)
writeCallback('analyse', CAD.AnalyseEvidence)
writeCallback('attach', CAD.AttachEvidence)

return CAD
