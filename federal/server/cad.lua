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

-- Resolves stored link ids into what the terminal shows: number, title and
-- status of each linked case, live rather than a snapshot that drifts.
local function enrichLinks(record)
    local linked = {}
    for _, linkId in ipairs(record.links or {}) do
        local other = incidents.get(linkId)
        if other then
            linked[#linked + 1] = { id = other.id, number = other.number, title = other.title, status = other.status }
        end
    end
    record.linked = linked
    return record
end

function CAD.Incidents(source, filter)
    local allowed = readable(source)
    if not allowed then return {} end
    filter = filter or {}
    local list = filterByAgency(incidents, allowed, function(record)
        if filter.status and record.status ~= filter.status then return false end
        if filter.open and record.status == 'closed' then return false end
        return true
    end)
    for _, record in ipairs(list) do enrichLinks(record) end
    return list
end

function CAD.Incident(source, id)
    local allowed = readable(source)
    if not allowed then return nil end
    local record = incidents.get(id)
    if not record or not allowed[record.agency] then return nil end
    return enrichLinks(record)
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
    local list = filterByAgency(bolos, allowed, function(record) return record.status == 'active' end)

    -- A person BOLO carries the subject's photo off their record when one
    -- matches by name: officers should know the face they are looking for.
    local enriched = {}
    for index, bolo in ipairs(list) do
        local copy = Util.Copy(bolo)
        if copy.kind == 'person' and copy.subject then
            local wanted = copy.subject:lower()
            for _, record in pairs(records.all()) do
                if record.photo and record.name and record.name:lower() == wanted then
                    copy.photo = record.photo
                    break
                end
            end
        end
        enriched[index] = copy
    end
    return enriched
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

    -- Each unit carries its live checkout log, its portrait (the CAD photo
    -- on their own citizen record), a service history (arrests they made,
    -- cases they worked) and their place in the chain of command.
    local units = membership and Core.Units(membership.agency.id) or {}
    for _, unit in ipairs(units) do
        if Federal.Armory and Federal.Armory.CheckoutFor then
            unit.checkout = Federal.Armory.CheckoutFor(unit.identifier)
        end

        local own = records.get(unit.identifier)
        unit.photo = own and own.photo or nil

        local arrestCount, arrestees = 0, {}
        for _, record in pairs(records.all()) do
            for _, arrest in ipairs(record.arrests or {}) do
                if arrest.officer == unit.name then
                    arrestCount = arrestCount + 1
                    if #arrestees < 6 then
                        arrestees[#arrestees + 1] = {
                            name = record.name, identifier = record.identifier, at = arrest.at
                        }
                    end
                end
            end
        end

        local caseCount, cases = 0, {}
        for _, record in pairs(incidents.all()) do
            if record.agency == unit.agency then
                for _, officer in ipairs(record.officers or {}) do
                    if officer.identifier == unit.identifier then
                        caseCount = caseCount + 1
                        if #cases < 6 then
                            cases[#cases + 1] = { id = record.id, number = record.number, title = record.title }
                        end
                        break
                    end
                end
            end
        end
        unit.service = { arrestCount = arrestCount, arrestees = arrestees, caseCount = caseCount, cases = cases }

        if Federal.Personnel and Federal.Personnel.OrgFor then
            unit.org = Federal.Personnel.OrgFor(unit.identifier)
        end
        if Federal.Personnel and Federal.Personnel.CertsFor then
            unit.certs = Federal.Personnel.CertsFor(unit.identifier)
        end
    end

    return {
        openIncidents = open,
        activeWarrants = activeWarrants,
        activeBolos = activeBolos,
        units = units,
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

-- A durable incident filed by the system rather than by an officer, for
-- automated reports from other resources (a bank filing fraud, an alarm
-- panel, etc.). No membership is required because there is no player actor;
-- the record is opened against the named agency and marked auto-filed so
-- officers can see it was not raised by one of their own.
function CAD.FileSystemIncident(agencyId, payload)
    payload = type(payload) == 'table' and payload or {}
    local agency = Core.Agency(agencyId)
    if not agency then return fail('unknown agency') end
    if not moduleEnabled(agency, 'incidents') then return fail('CAD incidents disabled for that agency') end

    local title = Util.Text(payload.title, 80)
    if not title then return fail('an incident requires a title') end

    local number, sequence = Core.NextNumber(agency.id, 'incident')
    local author = Util.Text(payload.source, 40, 'Automated report')
    local record = {
        id = Util.RecordId('inc', sequence),
        number = number,
        agency = agency.id,
        title = title,
        type = Util.Text(payload.type, 40, 'Financial crime'),
        status = 'open',
        priority = math.floor(Util.Clamp(tonumber(payload.priority) or 2, 1, 3)),
        charges = normalizeCharges(payload.charges),
        suspects = {},
        officers = {},
        narrative = {},
        location = Util.ToCoords(payload.location),
        calloutId = Util.Text(payload.calloutId, 40),
        autoFiled = true,
        createdBy = author,
        createdAt = now(),
        updatedAt = now()
    }

    if type(payload.suspect) == 'table' and payload.suspect.name then
        record.suspects[1] = {
            identifier = Util.Text(payload.suspect.identifier, 64),
            name = Util.Text(payload.suspect.name, 64, 'Unknown'),
            charges = normalizeCharges(payload.suspect.charges)
        }
    end

    local narrative = Util.Text(payload.narrative, 1000)
    if narrative then
        record.narrative[1] = { author = author, text = narrative, at = now() }
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

-- Witnesses stand apart from suspects: they need a name, not necessarily an
-- identifier, because half of them are civilians with no record at all.
function CAD.AttachWitness(source, id, witness)
    local membership, record = ownedIncident(source, id)
    if not membership then return fail('not authorized') end
    witness = type(witness) == 'table' and witness or {}

    local name = Util.Text(witness.name, 60)
    if not name then return fail('a witness requires a name') end

    record.witnesses = record.witnesses or {}
    for _, existing in ipairs(record.witnesses) do
        if existing.name == name then return fail('that witness is already on the case') end
    end

    record.witnesses[#record.witnesses + 1] = {
        name = name,
        identifier = Util.Text(witness.identifier, 80),
        statement = Util.Text(witness.statement, 400)
    }
    record.updatedAt = now()
    incidents.save(record.id, record)
    return record
end

-- Where the case physically happened. Setting it puts the incident on the
-- live map and gives every officer on it a "route to scene" button.
function CAD.SetIncidentLocation(source, id, coords)
    local membership, record = ownedIncident(source, id)
    if not membership then return fail('not authorized') end
    if record.status == 'closed' then return fail('that case is closed') end

    local location = Util.ToCoords(coords)
    if not location then return fail('no usable position') end

    record.location = location
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

-- A charge logged after filing: real cases accumulate charges as the
-- investigation develops.
function CAD.AddCharge(source, id, charge)
    local membership, record = ownedIncident(source, id)
    if not membership then return fail('not authorized') end
    if record.status == 'closed' then return fail('that case is closed') end

    local text = Util.Text(charge, 80)
    if not text then return fail('the charge is empty') end

    record.charges = record.charges or {}
    if #record.charges >= 20 then return fail('that case already carries the maximum charges') end
    record.charges[#record.charges + 1] = text
    record.updatedAt = now()

    incidents.save(record.id, record)
    return record
end

-- Finds a case by the number officers actually quote (or by id), inside one
-- agency's records.
local function findByReference(agencyId, reference)
    reference = tostring(reference or ''):upper()
    if reference == '' then return nil end
    for _, record in pairs(incidents.all()) do
        if record.agency == agencyId
            and (record.id:upper() == reference or tostring(record.number or ''):upper() == reference) then
            return record
        end
    end
    return nil
end

-- Linking joins related cases into one investigation: each carries the other
-- in its links list, so either one opens the thread. Both cases must belong
-- to the officer's own agency - a shared read grant is not a licence to
-- write link entries into another agency's records.
function CAD.LinkIncidents(source, id, reference)
    local membership, record = ownedIncident(source, id)
    if not membership then return fail('not authorized') end

    local other = findByReference(record.agency, reference)
    if not other then return fail('no case by that number in your agency') end
    if other.id == record.id then return fail('a case cannot link to itself') end

    record.links = record.links or {}
    if Util.Contains(record.links, other.id) then return fail('those cases are already linked') end
    if #record.links >= 12 then return fail('that case already carries the maximum links') end

    record.links[#record.links + 1] = other.id
    record.updatedAt = now()
    incidents.save(record.id, record)

    other.links = other.links or {}
    if not Util.Contains(other.links, record.id) then
        other.links[#other.links + 1] = record.id
        other.updatedAt = now()
        incidents.save(other.id, other)
    end

    return enrichLinks(record)
end

function CAD.UnlinkIncidents(source, id, reference)
    local membership, record = ownedIncident(source, id)
    if not membership then return fail('not authorized') end

    local other = findByReference(record.agency, reference)
    if not other then return fail('no case by that number in your agency') end

    local function drop(list, needle)
        for index, value in ipairs(list or {}) do
            if value == needle then
                table.remove(list, index)
                return true
            end
        end
        return false
    end

    if not drop(record.links, other.id) then return fail('those cases are not linked') end
    record.updatedAt = now()
    incidents.save(record.id, record)

    if drop(other.links, record.id) then
        other.updatedAt = now()
        incidents.save(other.id, other)
    end

    return enrichLinks(record)
end

-- Chunked photo uploads -------------------------------------------------------
--
-- A full-resolution camera shot is a multi-megabyte string, and a single
-- net event that size is silently dropped. The client ships the image in
-- ~60KB chunks under an upload id, then files the record with an
-- `upload:<id>` token; the photo validator assembles and consumes it.

local uploads = {}

RegisterNetEvent(Federal.Net('photo:chunk'), function(uploadId, index, piece, total)
    local playerSource = source
    if type(uploadId) ~= 'string' or #uploadId > 24 then return end
    if type(piece) ~= 'string' or #piece == 0 or #piece > 65000 then return end
    index = tonumber(index)
    total = tonumber(total)
    if not index or not total or index < 1 or index > total or total > 220 then return end

    local key = ('%d:%s'):format(playerSource, uploadId)
    local entry = uploads[key]
    if not entry then
        entry = { pieces = {}, received = 0, total = total, at = os.time() }
        uploads[key] = entry
    end
    if entry.total ~= total then return end
    if not entry.pieces[index] then entry.received = entry.received + 1 end
    entry.pieces[index] = piece
end)

local function takeUpload(playerSource, token)
    local uploadId = token:match('^upload:([%w]+)$')
    if not uploadId then return nil end
    local key = ('%d:%s'):format(playerSource, uploadId)
    local entry = uploads[key]
    uploads[key] = nil
    if not entry or entry.received ~= entry.total or entry.total == 0 then return nil end
    return table.concat(entry.pieces)
end

-- Half-finished uploads do not live forever.
CreateThread(function()
    while true do
        Wait(60000)
        local cutoff = os.time() - 180
        for key, entry in pairs(uploads) do
            if (entry.at or 0) < cutoff then uploads[key] = nil end
        end
    end
end)

-- A usable photo source: an https link, an embedded data-URI image, or an
-- `upload:` token pointing at a chunked camera shot from this player.
local function photoSource(url, playerSource)
    if type(url) ~= 'string' then return nil end
    if url:match('^upload:') and playerSource then
        url = takeUpload(playerSource, url)
        if not url then return nil end
    end
    if url:match('^https://') and #url <= 400 then return url end
    -- The ceiling exists only to keep one record from swallowing tens of MB.
    if url:match('^data:image/') and #url <= 12000000 then return url end
    return nil
end

CAD.PhotoSource = photoSource

-- Photographs on the case: scene shots, mugshots, documents - an https
-- image URL or an in-game camera shot.
function CAD.AddPhoto(source, id, url, caption)
    local membership, record = ownedIncident(source, id)
    if not membership then return fail('not authorized') end
    if record.status == 'closed' then return fail('that case is closed') end

    local link = photoSource(url, source)
    if not link then
        return fail('photos are https image links or in-game camera shots')
    end

    record.photos = record.photos or {}
    if #record.photos >= 12 then return fail('that case already carries the maximum photos') end
    record.photos[#record.photos + 1] = {
        url = link,
        caption = Util.Text(caption, 80),
        by = membership.name,
        at = now()
    }
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

    -- Warrant kinds: an arrest warrant commands custody, a search warrant
    -- authorizes entry, a bench warrant issues from the court itself.
    local kind = payload.kind
    if kind ~= 'search' and kind ~= 'bench' then kind = 'arrest' end

    local number, sequence = Core.NextNumber(membership.agency.id, 'warrant')
    local record = {
        id = Util.RecordId('wnt', sequence),
        number = number,
        agency = membership.agency.id,
        kind = kind,
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
    if record.custody == 'field' then return fail('check that bag into the evidence locker first') end

    local kind = Const.EvidenceKinds[record.kind]
    if not kind or not kind.analysable then return fail('that item cannot be analysed') end

    record.analysed = true
    if kind.identifies then
        -- An identifying kind only ever matches somebody who is already on
        -- file. A swab from a subject with no record is a dead end, which is
        -- what makes fingerprinting a suspect worth doing.
        local system = record.kind == 'print' and 'AFIS' or 'CODIS'
        local match = record.subject and records.get(record.subject) or nil
        if match then
            record.result = ('%s hit: %s'):format(system, match.name)
            record.match = record.subject
            CAD.Note(record.subject, match.name, ('%s %s matched this subject'):format(kind.label, record.number))
        else
            record.result = ('%s search returned no candidates on file'):format(system)
        end
    elseif record.kind == 'substance' then
        record.result = 'Laboratory confirmation: controlled substance, composition on file'
    elseif record.kind == 'casing' then
        record.result = 'Ballistics processed; striations catalogued for comparison'
    else
        record.result = ('%s processed; consistent with the scene'):format(kind.label)
    end

    record.chain[#record.chain + 1] = { actor = membership.name, action = 'analysed', at = now() }
    evidence.save(record.id, record)

    -- Analysis is where evidence stops being a number on a list and starts
    -- pointing somewhere. The lead module owns what it points at.
    if Federal.Leads then
        local lead = Federal.Leads.FromEvidence(source, record)
        if lead then
            record.lead = lead.id
            evidence.save(record.id, record)
            Bridge.Notify(source, lead.summary, 'inform', 9000)
        end
    end

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

-- Bagging and custody -----------------------------------------------------------
--
-- The records above are the ledger; this is the physical side. An officer
-- carrying evidence bags can bag what they find anywhere in the world - not
-- just at a callout marker - and the sealed bag rides in their inventory
-- until it is checked into an evidence locker. The lab refuses anything still
-- in a pocket: chain of custody is a gate, not a footnote.

local function evidenceItems()
    local cfg = (Config.Federal or {}).evidence or {}
    return cfg.bagItem or 'evidence_bag',
        cfg.baggedItem or 'bagged_evidence',
        cfg.fieldTestItem or 'field_test_kit'
end

function CAD.BagEvidence(source, payload)
    payload = type(payload) == 'table' and payload or {}
    local membership = CAD.RequireModule(source, 'actions.evidence', 'evidence')
    if not membership then return fail('not authorized') end

    local kind = payload.kind
    if not Const.EvidenceKinds[kind] then return fail('unknown evidence kind') end

    local bagItem, baggedItem = evidenceItems()
    if not Bridge.RemoveItem(source, bagItem, 1) then
        return fail(('you need an %s to bag that'):format(bagItem))
    end

    local number, sequence = Core.NextNumber(membership.agency.id, 'evidence')
    local record = {
        id = Util.RecordId('evd', sequence),
        number = number,
        agency = membership.agency.id,
        kind = kind,
        label = Util.Text(payload.label, 80, Const.EvidenceKinds[kind].label),
        description = Util.Text(payload.description, 200),
        incidentId = Util.Text(payload.incidentId, 40),
        location = Util.ToCoords(payload.location),
        custody = 'field',
        heldBy = membership.identifier,
        analysed = false,
        collectedBy = membership.name,
        collectedAt = now(),
        chain = { { actor = membership.name, action = 'bagged and sealed at the scene', at = now() } }
    }

    evidence.save(record.id, record)
    -- The sealed bag itself. Best-effort: a full inventory does not lose the
    -- ledger entry, it just means there is nothing to hand over later.
    Bridge.AddItem(source, baggedItem, 1, {
        number = record.number,
        label = record.label,
        description = ('%s | sealed by %s'):format(record.number, membership.name)
    })
    return record
end

-- The sealed bags this officer is still carrying.
function CAD.HeldEvidence(source)
    local membership = Core.Membership(source)
    if not membership then return {} end

    local list = {}
    for _, record in pairs(evidence.all()) do
        if record.custody == 'field' and record.heldBy == membership.identifier then
            list[#list + 1] = record
        end
    end
    table.sort(list, function(a, b) return (a.collectedAt or 0) < (b.collectedAt or 0) end)
    return list
end

function CAD.CheckInEvidence(source, id)
    local membership = CAD.RequireModule(source, 'actions.evidence', 'evidence')
    if not membership then return fail('not authorized') end

    local allowed = Core.RequireZone(source, membership, 'evidence')
    if not allowed then return fail('not at an evidence locker') end

    local record = evidence.get(id)
    if not record then return fail('that evidence item no longer exists') end
    if record.custody ~= 'field' then return fail('that item is already in the locker') end
    if record.heldBy ~= membership.identifier and not Core.IsAdmin(source) then
        return fail('a different officer sealed that bag')
    end

    local _, baggedItem = evidenceItems()
    Bridge.RemoveItem(source, baggedItem, 1)

    record.custody = 'locker'
    record.heldBy = nil
    record.chain[#record.chain + 1] = { actor = membership.name, action = 'checked into the evidence locker', at = now() }
    evidence.save(record.id, record)
    return record
end

-- A reagent kit gives a presumptive answer at the roadside; the lab still has
-- the last word. Only substances react to a swab stick.
function CAD.FieldTestEvidence(source, id)
    local membership = CAD.RequireModule(source, 'actions.evidence', 'evidence')
    if not membership then return fail('not authorized') end

    local record = evidence.get(id)
    if not record then return fail('that evidence item no longer exists') end
    if record.agency ~= membership.agency.id and not Core.IsAdmin(source) then
        return fail('that item belongs to another agency')
    end
    if record.kind ~= 'substance' then return fail('only a substance takes a reagent test') end
    if record.fieldTest then return fail('that sample has already been field tested') end

    local _, _, kitItem = evidenceItems()
    if not Bridge.RemoveItem(source, kitItem, 1) then
        return fail(('you need a %s'):format(kitItem))
    end

    record.fieldTest = 'Presumptive positive - controlled substance indicated'
    record.chain[#record.chain + 1] = { actor = membership.name, action = 'field tested (presumptive)', at = now() }
    evidence.save(record.id, record)
    return record
end

-- Case files -----------------------------------------------------------------
--
-- An evidence board, not an incident: a named workspace an investigator pins
-- existing records onto - incidents, warrants, BOLOs, citizen records,
-- evidence - plus free-text notes. Nothing pinned is copied; the board holds
-- typed references, so it always reflects the live records.

local casefiles = DAG.Repository.Create('federal_casefiles')
CAD.casefiles = casefiles

local MAX_PINS = 60
local MAX_CASE_NOTES = 40

local function ownedCase(source, id)
    local membership = Core.Require(source, 'cad.write')
    if not membership then return nil end

    local board = casefiles.get(id)
    if not board then
        Bridge.Notify(source, 'That case file no longer exists.', 'error')
        return nil
    end
    if board.agency ~= membership.agency.id and not Core.IsAdmin(source) then
        Bridge.Notify(source, 'That case file belongs to another agency.', 'error')
        return nil
    end
    return membership, board
end

-- Accepts a plain title (older callers) or a form payload with a
-- classification and an opening summary, the way the creation modal files it.
function CAD.CaseCreate(source, titleOrPayload)
    local membership = CAD.RequireModule(source, 'cad.write', 'incidents')
    if not membership then return fail('not authorized') end

    local payload = type(titleOrPayload) == 'table' and titleOrPayload or { title = titleOrPayload }
    local text = Util.Text(payload.title, 80)
    if not text then return fail('a case file needs a title') end

    local number, sequence = Core.NextNumber(membership.agency.id, 'casefile')
    local board = {
        id = Util.RecordId('cf', sequence),
        number = number,
        agency = membership.agency.id,
        title = text,
        classification = Util.Text(payload.classification, 40),
        summary = Util.Text(payload.summary, 600),
        status = 'open',
        pins = {},
        notes = {},
        agents = { membership.name },
        createdBy = membership.name,
        createdAt = now(),
        updatedAt = now()
    }

    casefiles.save(board.id, board)
    return board
end

-- More than one agent works a case: the lead adds colleagues by name, and
-- the board shows who carries it.
function CAD.CaseAgent(source, id, agentName)
    local membership, board = ownedCase(source, id)
    if not membership then return fail('not authorized') end

    local name = Util.Text(agentName, 60)
    if not name then return fail('no agent named') end

    board.agents = board.agents or { board.createdBy }
    for _, existing in ipairs(board.agents) do
        if existing == name then return fail('they are already on the case') end
    end
    if #board.agents >= 8 then return fail('that case already carries the maximum agents') end

    board.agents[#board.agents + 1] = name
    board.updatedAt = now()
    casefiles.save(board.id, board)
    return board
end

-- A person profile: the criminal record joined with everything else the
-- system knows - vitals and licences from the framework, registered
-- vehicles, court history, warrants on file. One query, one document.
function CAD.Profile(source, identifier)
    local membership = Core.Membership(source)
    if not membership or not Core.Can(source, 'cad.view') then return nil end
    identifier = Util.Text(identifier, 80)
    if not identifier then return nil end

    local allowed = readable(source) or {}
    local profile = {
        identifier = identifier,
        record = records.get(identifier),
        citizen = Bridge.CitizenInfo and Bridge.CitizenInfo(identifier) or nil,
        vehicles = Bridge.VehiclesByOwner and Bridge.VehiclesByOwner(identifier) or {},
        court = (Federal.Court and Federal.Court.CasesFor) and Federal.Court.CasesFor(identifier) or {},
        warrants = {}
    }
    for _, warrant in pairs(warrants.all()) do
        if allowed[warrant.agency] and warrant.target and warrant.target.identifier == identifier then
            profile.warrants[#profile.warrants + 1] = {
                id = warrant.id, number = warrant.number, status = warrant.status,
                reason = warrant.reason, kind = warrant.kind
            }
        end
    end
    return profile
end

-- Every booking on file, newest first: the custody tab's arrest reports.
function CAD.ArrestReports(source)
    local allowed = readable(source)
    if not allowed then return {} end

    local list = {}
    for _, record in pairs(records.all()) do
        for _, arrest in ipairs(record.arrests or {}) do
            list[#list + 1] = {
                identifier = record.identifier,
                name = record.name,
                at = arrest.at,
                officer = arrest.officer,
                charges = arrest.charges or {},
                caseNumber = arrest.caseNumber
            }
        end
    end
    table.sort(list, function(a, b) return (a.at or 0) > (b.at or 0) end)

    local capped = {}
    for index = 1, math.min(#list, 40) do capped[index] = list[index] end
    return capped
end

-- A photograph on a person's file (mugshot, surveillance still). Creates the
-- record shell if the subject is a clean civilian.
function CAD.RecordPhoto(source, identifier, url, name)
    local membership = CAD.RequireModule(source, 'cad.write', 'records')
    if not membership then return fail('not authorized') end

    local link = photoSource(url, source)
    if not link then
        return fail('photos are https image links or in-game camera shots')
    end

    local record = CAD.Record(Util.Text(identifier, 80) or '', Util.Text(name, 60))
    if not record then return fail('no usable identifier') end

    record.photo = link
    records.save(record.identifier, record)
    return record
end

function CAD.Cases(source)
    local allowed = readable(source)
    if not allowed then return {} end
    return filterByAgency(casefiles, allowed)
end

-- Live search across everything pinnable, scoped to what the officer may
-- read. Matches come back typed so the board can group them.
function CAD.CaseSearch(source, term)
    local allowed = readable(source)
    if not allowed then return {} end

    local needle = tostring(term or ''):lower()
    if #needle < 2 then return {} end

    local results = {}
    local function push(kind, id, label, meta)
        if #results >= 25 then return end
        if label:lower():find(needle, 1, true) or (meta or ''):lower():find(needle, 1, true) then
            results[#results + 1] = { kind = kind, refId = id, label = label, meta = meta }
        end
    end

    for _, record in pairs(incidents.all()) do
        if allowed[record.agency] then
            push('incident', record.id, ('%s %s'):format(record.number, record.title or ''), record.status)
        end
    end
    for _, record in pairs(warrants.all()) do
        if allowed[record.agency] then
            push('warrant', record.id, ('%s %s'):format(record.number, record.target and record.target.name or ''), record.status)
        end
    end
    for _, record in pairs(bolos.all()) do
        if allowed[record.agency] then
            push('bolo', record.id, ('%s %s'):format(record.number, record.subject or ''), record.status)
        end
    end
    for _, record in pairs(CAD.evidence.all()) do
        if allowed[record.agency] then
            push('evidence', record.id, ('%s %s'):format(record.number or record.id, record.label or ''), record.kind)
        end
    end
    for _, record in pairs(records.all()) do
        push('record', record.identifier or record.id, record.name or 'Unknown', 'citizen record')
    end

    return results
end

-- The one-move filing the field asked for: put an incident on a case file's
-- board - creating the case file on the spot when handed a title instead of
-- an id - and optionally sweep every incident LINKED to it onto the board in
-- the same motion, so a chain of related incidents cases up all at once.
function CAD.CaseAttachIncident(source, caseRef, incidentId, includeLinked)
    local membership, incident = ownedIncident(source, incidentId)
    if not membership then return fail('not authorized') end

    local board
    if caseRef and casefiles.get(caseRef) then
        local _, owned = ownedCase(source, caseRef)
        if not owned then return fail('not authorized') end
        board = owned
    else
        local created, message = CAD.CaseCreate(source, caseRef)
        if not created then return fail(message) end
        board = casefiles.get(created.id)
    end

    local function pinIncident(target)
        for _, existing in ipairs(board.pins) do
            if existing.kind == 'incident' and existing.refId == target.id then return false end
        end
        if #board.pins >= MAX_PINS then return false end
        board.pins[#board.pins + 1] = {
            kind = 'incident', refId = target.id,
            label = ('%s %s'):format(target.number, target.title or ''),
            by = membership.name, at = now()
        }
        return true
    end

    local pinned = pinIncident(incident) and 1 or 0
    if includeLinked then
        for _, linkId in ipairs(incident.links or {}) do
            local other = incidents.get(linkId)
            if other and pinIncident(other) then pinned = pinned + 1 end
        end
    end

    board.updatedAt = now()
    casefiles.save(board.id, board)
    return { id = board.id, number = board.number, title = board.title, pinned = pinned }
end

-- The Lookup console's one query: people (criminal records plus civilians
-- known to the framework), vehicles by plate or owner, and any warrant,
-- BOLO, incident or case file that matches. An empty term auto-populates
-- with what an officer scans first - everyone on file plus the active paper.
function CAD.Lookup(source, term)
    local membership = Core.Membership(source)
    if not membership or not Core.Can(source, 'cad.view') then return nil end
    local allowed = readable(source)
    if not allowed then return nil end

    term = tostring(term or '')
    local needle = term:lower():gsub('^%s+', ''):gsub('%s+$', '')
    local out = { term = needle, people = {}, vehicles = {}, hits = {} }

    -- People with a record on file.
    local seen = {}
    for _, record in pairs(records.all()) do
        if #out.people >= 40 then break end
        if needle == '' or (record.name or ''):lower():find(needle, 1, true)
            or (record.identifier or ''):lower():find(needle, 1, true) then
            out.people[#out.people + 1] = record
            seen[record.identifier] = true
        end
    end

    -- Civilians the framework knows who have no record yet: a lookup that
    -- can only see criminals is not a lookup.
    if needle ~= '' and Bridge.SearchCitizens then
        for _, citizen in ipairs(Bridge.SearchCitizens(term) or {}) do
            if #out.people >= 40 then break end
            if citizen.identifier and not seen[citizen.identifier] then
                seen[citizen.identifier] = true
                out.people[#out.people + 1] = {
                    identifier = citizen.identifier,
                    name = citizen.name,
                    civilian = true
                }
            end
        end
    end

    -- Vehicles: the framework's registration database, cross-checked against
    -- active BOLO plates so a flagged plate comes back screaming.
    if needle ~= '' and Bridge.LookupVehicles then
        out.vehicles = Bridge.LookupVehicles(term) or {}
    end
    local boloPlates = {}
    for _, record in pairs(bolos.all()) do
        if record.status == 'active' and allowed[record.agency] and record.plate then
            boloPlates[record.plate:upper():gsub('%s', '')] = record.number
        end
    end
    for _, vehicle in ipairs(out.vehicles) do
        local plate = tostring(vehicle.plate or ''):upper():gsub('%s', '')
        if boloPlates[plate] then vehicle.bolo = boloPlates[plate] end
    end

    -- Paper: warrants and BOLOs always, incidents and case files only when
    -- actually searching (auto-populate should not dump the whole caseload).
    local function push(kind, label, meta, autoInclude)
        if #out.hits >= 25 then return end
        if needle == '' then
            if autoInclude then out.hits[#out.hits + 1] = { kind = kind, label = label, meta = meta } end
        elseif label:lower():find(needle, 1, true) or (meta or ''):lower():find(needle, 1, true) then
            out.hits[#out.hits + 1] = { kind = kind, label = label, meta = meta }
        end
    end
    for _, record in pairs(warrants.all()) do
        if allowed[record.agency] then
            push('warrant', ('%s %s'):format(record.number, record.target and record.target.name or ''),
                record.status, record.status == 'active')
        end
    end
    for _, record in pairs(bolos.all()) do
        if allowed[record.agency] then
            push('bolo', ('%s %s'):format(record.number, record.subject or ''),
                record.plate or record.kind, record.status == 'active')
        end
    end
    for _, record in pairs(incidents.all()) do
        if allowed[record.agency] then
            push('incident', ('%s %s'):format(record.number, record.title or ''), record.status, false)
        end
    end
    for _, record in pairs(casefiles.all()) do
        if allowed[record.agency] then
            push('case', ('%s %s'):format(record.number, record.title or ''), record.status, false)
        end
    end

    return out
end

function CAD.CasePin(source, id, pin)
    local membership, board = ownedCase(source, id)
    if not membership then return fail('not authorized') end
    pin = type(pin) == 'table' and pin or {}

    local kind = Util.Text(pin.kind, 20)
    -- Photo pins carry the image itself as their reference - a URL or an
    -- in-game camera shot - so they escape the ordinary id length cap.
    local refId
    if kind == 'photo' then
        refId = photoSource(pin.refId, source)
    else
        refId = Util.Text(pin.refId, 80)
    end
    local label = Util.Text(pin.label, 120)
    if not kind or not refId or not label then return fail('nothing to pin') end
    if #board.pins >= MAX_PINS then return fail('that board is full') end

    for _, existing in ipairs(board.pins) do
        if existing.kind == kind and existing.refId == refId then
            return fail('that record is already on the board')
        end
    end

    board.pins[#board.pins + 1] = {
        kind = kind, refId = refId, label = label,
        by = membership.name, at = now()
    }
    board.updatedAt = now()
    casefiles.save(board.id, board)
    return board
end

function CAD.CaseUnpin(source, id, index)
    local membership, board = ownedCase(source, id)
    if not membership then return fail('not authorized') end

    index = math.floor(tonumber(index) or 0)
    if not board.pins[index] then return fail('no such pin') end

    table.remove(board.pins, index)
    board.updatedAt = now()
    casefiles.save(board.id, board)
    return board
end

-- Reordering the board: the client sends the new order as a permutation of
-- the current pin indices (drag and drop on the chips).
function CAD.CaseReorder(source, id, order)
    local membership, board = ownedCase(source, id)
    if not membership then return fail('not authorized') end
    if type(order) ~= 'table' or #order ~= #board.pins then return fail('bad pin order') end

    local seen, reordered = {}, {}
    for _, index in ipairs(order) do
        index = math.floor(tonumber(index) or 0)
        if not board.pins[index] or seen[index] then return fail('bad pin order') end
        seen[index] = true
        reordered[#reordered + 1] = board.pins[index]
    end

    board.pins = reordered
    board.updatedAt = now()
    casefiles.save(board.id, board)
    return board
end

function CAD.CaseNote(source, id, text)
    local membership, board = ownedCase(source, id)
    if not membership then return fail('not authorized') end

    local entry = Util.Text(text, 500)
    if not entry then return fail('the note is empty') end
    if #board.notes >= MAX_CASE_NOTES then table.remove(board.notes, 1) end

    board.notes[#board.notes + 1] = { author = membership.name, text = entry, at = now() }
    board.updatedAt = now()
    casefiles.save(board.id, board)
    return board
end

function CAD.CaseStatus(source, id, status)
    local membership, board = ownedCase(source, id)
    if not membership then return fail('not authorized') end
    if status ~= 'open' and status ~= 'closed' then return fail('unknown status') end

    board.status = status
    board.updatedAt = now()
    casefiles.save(board.id, board)
    return board
end

function CAD.CaseDelete(source, id)
    local membership = Core.Require(source, 'cad.expunge')
    if not membership then return fail('not authorized') end

    local board = casefiles.get(id)
    if not board then return fail('that case file no longer exists') end
    if board.agency ~= membership.agency.id and not Core.IsAdmin(source) then
        return fail('that case file belongs to another agency')
    end

    casefiles.delete(board.id)
    return board
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
readCallback('held', function(source) return CAD.HeldEvidence(source) end)
readCallback('records', function(source, term) return CAD.SearchRecords(source, term) end)
readCallback('record', function(source, identifier) return CAD.LookupRecord(source, identifier) end)
readCallback('cases', CAD.Cases)
readCallback('caseSearch', function(source, term) return CAD.CaseSearch(source, term) end)
readCallback('lookup', function(source, term) return CAD.Lookup(source, term) end)
readCallback('profile', function(source, identifier) return CAD.Profile(source, identifier) end)
readCallback('arrests', CAD.ArrestReports)

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
writeCallback('witness', CAD.AttachWitness)
writeCallback('caseAttach', CAD.CaseAttachIncident)
writeCallback('caseAgent', CAD.CaseAgent)
writeCallback('scene', CAD.SetIncidentLocation)
writeCallback('recordPhoto', CAD.RecordPhoto)
writeCallback('charge', CAD.AddCharge)
writeCallback('link', CAD.LinkIncidents)
writeCallback('unlink', CAD.UnlinkIncidents)
writeCallback('assign', CAD.AssignOfficer)
writeCallback('status', CAD.SetIncidentStatus)
writeCallback('expunge', CAD.DeleteIncident)
writeCallback('warrant', CAD.IssueWarrant)
writeCallback('warrantStatus', CAD.SetWarrantStatus)
writeCallback('bolo', CAD.CreateBolo)
writeCallback('boloClose', CAD.CloseBolo)
writeCallback('collect', CAD.CollectEvidence)
writeCallback('bag', CAD.BagEvidence)
writeCallback('checkin', CAD.CheckInEvidence)
writeCallback('fieldtest', CAD.FieldTestEvidence)
writeCallback('analyse', CAD.AnalyseEvidence)
writeCallback('attach', CAD.AttachEvidence)
writeCallback('photo', CAD.AddPhoto)
writeCallback('caseCreate', CAD.CaseCreate)
writeCallback('casePin', CAD.CasePin)
writeCallback('caseReorder', CAD.CaseReorder)
writeCallback('caseUnpin', CAD.CaseUnpin)
writeCallback('caseNote', CAD.CaseNote)
writeCallback('caseStatus', CAD.CaseStatus)
writeCallback('caseDelete', CAD.CaseDelete)

return CAD
