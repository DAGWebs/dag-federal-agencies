-- The in-game editor.
--
-- Editing happens where the thing being edited is: adding a locker room means
-- walking to the locker room and pressing "place here", and the server writes
-- the position it reads for that player rather than a coordinate the client
-- typed. Every write goes through the schema, so an edit either produces a
-- fully valid agency or is rejected with a reason and changes nothing.
--
-- Scope: `editor.manage` lets a player edit THEIR OWN agency. Creating and
-- deleting whole agencies is an admin action, because an agency nobody belongs
-- to yet has no rank ladder that could authorize it.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Util = Federal.Util
local Const = Federal.Constants
local Schema = Federal.Schema
local Core = Federal.Core

local Editor = {}
Federal.Editor = Editor

local function fail(message)
    return nil, message
end

-- The top of an agency's rank ladder. The highest rank may configure the
-- agency whether or not its permission list happens to include editor.manage,
-- so a rewritten ladder can never lock the director out of the config panel.
local function topGrade(agency)
    local top = 0
    for _, rank in ipairs(agency and agency.ranks or {}) do
        if rank.grade > top then top = rank.grade end
    end
    return top
end

Editor.TopGrade = topGrade

-- Resolves the agency this player is allowed to edit. Admins may name any
-- agency; everyone else edits their own and nothing else, holding either
-- editor.manage or the agency's highest rank.
local function editable(source, agencyId)
    if Core.IsAdmin(source) then
        local agency = Core.Agency(agencyId)
        if not agency then return nil, 'no such agency' end
        return agency
    end

    local membership = Core.Membership(source)
    if not membership then return nil, 'not authorized' end

    local allowed = Core.Can(source, 'editor.manage')
        or membership.grade >= topGrade(membership.agency)
    if not allowed then return nil, 'not authorized' end

    if agencyId and agencyId ~= membership.agency.id then return nil, 'you may only edit your own agency' end
    return membership.agency
end

Editor.Editable = editable

-- Domain-scoped variant: an agency is also editable by a member holding the
-- named permission over it, so uniform.manage really does mean "create and
-- edit uniforms" without needing the whole editor.
function Editor.EditableFor(source, agencyId, permission)
    local agency, message = editable(source, agencyId)
    if agency then return agency end

    local membership = Core.Membership(source)
    if not membership then return nil, message end
    if agencyId and agencyId ~= membership.agency.id then return nil, 'you may only edit your own agency' end
    if not Core.Can(source, permission) then return nil, message end
    return membership.agency
end

local function persist(agency)
    return Federal.Uniforms.PersistAgency(agency)
end

-- Where a placement lands: the player's real position when they asked for
-- "here", otherwise whatever the payload carried.
local function placement(source, payload)
    if payload.here == true then
        local position = Core.Coords(source)
        if not position then return nil end
        local ped = GetPlayerPed(source)
        return position, ped and GetEntityHeading(ped) or 0.0
    end
    return Util.ToCoords(payload.coords), tonumber(payload.heading) or 0.0
end

Editor.Placement = placement

-- Agencies ---------------------------------------------------------------------

function Editor.CreateAgency(source, payload)
    if not Core.IsAdmin(source) then return fail('creating an agency is an admin action') end
    payload = type(payload) == 'table' and payload or {}

    local agency, message = Schema.Agency(payload)
    if not agency then return fail(message) end
    if Core.Agency(agency.id) then return fail('an agency with that id already exists') end

    -- A brand new agency with no ranks would be unadministerable, so it gets a
    -- minimal ladder: a starting rank and a director who can edit it.
    if #agency.ranks == 0 then
        agency.ranks = {
            Schema.Rank({ grade = 0, label = 'Agent', permissions = {
                ['cad.view'] = true, ['armory.use'] = true,
                ['actions.detain'] = true, ['actions.search'] = true, ['actions.evidence'] = true
            } }),
            Schema.Rank({ grade = agency.bossGrade, label = 'Director', permissions = {
                ['cad.view'] = true, ['cad.write'] = true, ['cad.warrant'] = true, ['cad.expunge'] = true,
                ['armory.use'] = true, ['armory.manage'] = true, ['uniform.manage'] = true,
                ['roster.manage'] = true, ['editor.manage'] = true, ['callout.manage'] = true,
                ['actions.detain'] = true, ['actions.search'] = true, ['actions.arrest'] = true,
                ['actions.evidence'] = true
            } })
        }
    end

    return persist(agency)
end

function Editor.UpdateAgency(source, agencyId, changes)
    local agency, message = editable(source, agencyId)
    if not agency then return fail(message) end
    changes = type(changes) == 'table' and changes or {}

    -- Only the descriptive fields are editable here. Stations, uniforms,
    -- armory and ranks each have their own operation so one careless payload
    -- cannot wipe a list.
    if changes.label ~= nil then agency.label = Util.Text(changes.label, 80, agency.label) end
    if changes.short ~= nil then agency.short = Util.Text(changes.short, 8, agency.short) end
    if changes.color ~= nil then agency.color = Util.Text(changes.color, 9, agency.color) end
    if changes.bossGrade ~= nil then agency.bossGrade = math.floor(Util.Clamp(tonumber(changes.bossGrade) or agency.bossGrade, 0, 100)) end
    if changes.callouts ~= nil then agency.callouts = changes.callouts == true end
    -- An empty string clears the prefix (fall back to the short code); nil
    -- leaves it untouched.
    if changes.callsignPrefix ~= nil then
        agency.callsignPrefix = Schema.CallsignPrefix(changes.callsignPrefix)
    end
    if type(changes.npcCallouts) == 'table' then
        agency.npcCallouts = Util.Merge(agency.npcCallouts or {}, changes.npcCallouts)
    end
    if type(changes.jobs) == 'table' then agency.jobs = changes.jobs end
    if type(changes.blip) == 'table' then agency.blip = changes.blip end
    if type(changes.cad) == 'table' then agency.cad = Util.Merge(agency.cad, changes.cad) end

    return persist(agency)
end

function Editor.DeleteAgency(source, agencyId)
    if not Core.IsAdmin(source) then return fail('deleting an agency is an admin action') end

    local agency = Core.Agency(agencyId)
    if not agency then return fail('no such agency') end

    -- A tombstone, not a delete: the agency may be seeded from config, and a
    -- plain delete would let the config resurrect it on the next restart.
    Core.agencies.save(agencyId, { deleted = true })
    Core.Sync()
    return agency
end

-- Stations -----------------------------------------------------------------------

function Editor.SaveStation(source, agencyId, payload)
    local agency, message = editable(source, agencyId)
    if not agency then return fail(message) end
    payload = type(payload) == 'table' and payload or {}

    local coords = placement(source, payload)
    if not coords then return fail('no position for that station') end

    local existing = payload.id and Schema.FindById(agency.stations or {}, payload.id) or nil
    -- An omitted flag keeps the stored value; `and/or` would turn a stored
    -- false into the schema default.
    local publicBlip = payload.publicBlip
    if publicBlip == nil and existing then publicBlip = existing.publicBlip end

    -- The map icon: a table sets it, `false` clears it back to the agency
    -- default, nil keeps whatever the station had.
    local blip = payload.blip
    if blip == false then
        blip = nil
    elseif type(blip) ~= 'table' then
        blip = existing and existing.blip or nil
    end

    local station, stationMessage = Schema.Station({
        id = payload.id,
        label = payload.label or (existing and existing.label),
        kind = payload.kind or (existing and existing.kind),
        publicBlip = publicBlip,
        coords = coords,
        blip = blip,
        -- Moving a station keeps its rooms; they are placed individually.
        zones = existing and existing.zones or {}
    })
    if not station then return fail(stationMessage) end

    agency.stations = agency.stations or {}
    local _, index = Schema.FindById(agency.stations, station.id)
    if index then
        agency.stations[index] = station
    else
        agency.stations[#agency.stations + 1] = station
    end

    local saved, saveMessage = persist(agency)
    if not saved then return fail(saveMessage) end
    return station
end

function Editor.DeleteStation(source, agencyId, stationId)
    local agency, message = editable(source, agencyId)
    if not agency then return fail(message) end

    local station, index = Schema.FindById(agency.stations or {}, stationId)
    if not index then return fail('no such station') end

    table.remove(agency.stations, index)
    local saved, saveMessage = persist(agency)
    if not saved then return fail(saveMessage) end
    return station
end

-- Zones ---------------------------------------------------------------------------

function Editor.SaveZone(source, agencyId, stationId, payload)
    local agency, message = editable(source, agencyId)
    if not agency then return fail(message) end
    payload = type(payload) == 'table' and payload or {}

    local station = Schema.FindById(agency.stations or {}, stationId)
    if not station then return fail('no such station') end
    if not Const.ZoneKinds[payload.kind] then return fail('unknown zone kind') end

    local coords, heading = placement(source, payload)
    if not coords then return fail('no position for that zone') end

    local zone, zoneMessage = Schema.Zone({
        id = payload.id,
        kind = payload.kind,
        label = payload.label,
        coords = coords,
        heading = heading,
        radius = payload.radius,
        minGrade = payload.minGrade
    })
    if not zone then return fail(zoneMessage) end

    station.zones = station.zones or {}
    local _, index = Schema.FindById(station.zones, zone.id)
    if index then
        station.zones[index] = zone
    else
        station.zones[#station.zones + 1] = zone
    end

    local saved, saveMessage = persist(agency)
    if not saved then return fail(saveMessage) end
    return zone
end

function Editor.DeleteZone(source, agencyId, stationId, zoneId)
    local agency, message = editable(source, agencyId)
    if not agency then return fail(message) end

    local station = Schema.FindById(agency.stations or {}, stationId)
    if not station then return fail('no such station') end

    local zone, index = Schema.FindById(station.zones or {}, zoneId)
    if not index then return fail('no such zone') end

    table.remove(station.zones, index)
    local saved, saveMessage = persist(agency)
    if not saved then return fail(saveMessage) end
    return zone
end

-- Divisions ------------------------------------------------------------------------

function Editor.SaveDivision(source, agencyId, payload)
    local agency, message = Editor.EditableFor(source, agencyId, 'roster.manage')
    if not agency then return fail(message) end
    payload = type(payload) == 'table' and payload or {}

    -- A meta edit (rename, joinable grade) must not wipe the division's own
    -- rank ladder; ranks have their own operations below.
    local existing = payload.id and Schema.FindById(agency.divisions or {}, payload.id) or nil
    if payload.ranks == nil and existing then payload = Federal.Util.Merge(existing, payload) end

    local division, divisionMessage = Schema.Division(payload)
    if not division then return fail(divisionMessage) end

    agency.divisions = agency.divisions or {}
    local _, index = Schema.FindById(agency.divisions, division.id)
    if index then
        agency.divisions[index] = division
    else
        agency.divisions[#agency.divisions + 1] = division
    end

    local saved, saveMessage = persist(agency)
    if not saved then return fail(saveMessage) end
    return division
end

-- Division ranks: a taskforce's own ladder (SWAT Operator, Team Lead...).
function Editor.SaveDivisionRank(source, agencyId, divisionId, payload)
    local agency, message = Editor.EditableFor(source, agencyId, 'roster.manage')
    if not agency then return fail(message) end

    local division = Schema.FindById(agency.divisions or {}, divisionId)
    if not division then return fail('no such division') end

    local rank, rankMessage = Schema.DivisionRank(payload)
    if not rank then return fail(rankMessage) end

    division.ranks = division.ranks or {}
    local _, index = Schema.FindById(division.ranks, rank.id)
    if index then
        division.ranks[index] = rank
    else
        division.ranks[#division.ranks + 1] = rank
    end

    local saved, saveMessage = persist(agency)
    if not saved then return fail(saveMessage) end
    return rank
end

function Editor.DeleteDivisionRank(source, agencyId, divisionId, grade)
    local agency, message = Editor.EditableFor(source, agencyId, 'roster.manage')
    if not agency then return fail(message) end

    local division = Schema.FindById(agency.divisions or {}, divisionId)
    if not division then return fail('no such division') end

    local rank, index = Schema.FindById(division.ranks or {}, ('grade-%d'):format(math.floor(tonumber(grade) or -1)))
    if not index then return fail('no such division rank') end

    table.remove(division.ranks, index)
    local saved, saveMessage = persist(agency)
    if not saved then return fail(saveMessage) end
    return rank
end

function Editor.DeleteDivision(source, agencyId, divisionId)
    local agency, message = Editor.EditableFor(source, agencyId, 'roster.manage')
    if not agency then return fail(message) end

    local division, index = Schema.FindById(agency.divisions or {}, divisionId)
    if not index then return fail('no such division') end

    table.remove(agency.divisions, index)
    local saved, saveMessage = persist(agency)
    if not saved then return fail(saveMessage) end
    return division
end

-- Ranks ----------------------------------------------------------------------------

function Editor.SaveRank(source, agencyId, payload)
    local agency, message = editable(source, agencyId)
    if not agency then return fail(message) end
    if not Core.IsAdmin(source) and not Core.Can(source, 'roster.manage') then return fail('not authorized') end

    local rank, rankMessage = Schema.Rank(payload)
    if not rank then return fail(rankMessage) end

    agency.ranks = agency.ranks or {}
    local _, index = Schema.FindById(agency.ranks, rank.id)
    if index then
        agency.ranks[index] = rank
    else
        agency.ranks[#agency.ranks + 1] = rank
    end

    local saved, saveMessage = persist(agency)
    if not saved then return fail(saveMessage) end
    return rank
end

function Editor.DeleteRank(source, agencyId, grade)
    local agency, message = editable(source, agencyId)
    if not agency then return fail(message) end
    if not Core.IsAdmin(source) and not Core.Can(source, 'roster.manage') then return fail('not authorized') end

    local rank, index = Schema.FindById(agency.ranks or {}, ('grade-%d'):format(math.floor(tonumber(grade) or -1)))
    if not index then return fail('no such rank') end
    -- An agency with no ranks cannot authorize anything, including putting a
    -- rank back, so the last one is not removable.
    if #agency.ranks <= 1 then return fail('an agency must keep at least one rank') end

    table.remove(agency.ranks, index)
    local saved, saveMessage = persist(agency)
    if not saved then return fail(saveMessage) end
    return rank
end

-- Net wiring ------------------------------------------------------------------------

-- Certifications: the awards catalog directors maintain (Field Training,
-- SWAT, Firearms...). Awarding them to members happens in Personnel.
function Editor.SaveCertification(source, agencyId, payload)
    local agency, message = Editor.EditableFor(source, agencyId, 'roster.manage')
    if not agency then return fail(message) end

    local cert, certMessage = Schema.Certification(type(payload) == 'table' and payload or {})
    if not cert then return fail(certMessage) end

    agency.certifications = agency.certifications or {}
    local _, index = Schema.FindById(agency.certifications, cert.id)
    if index then
        agency.certifications[index] = cert
    else
        agency.certifications[#agency.certifications + 1] = cert
    end

    local saved, saveMessage = persist(agency)
    if not saved then return fail(saveMessage) end
    return cert
end

function Editor.DeleteCertification(source, agencyId, certId)
    local agency, message = Editor.EditableFor(source, agencyId, 'roster.manage')
    if not agency then return fail(message) end

    local cert, index = Schema.FindById(agency.certifications or {}, certId)
    if not index then return fail('no such certification') end

    table.remove(agency.certifications, index)
    local saved, saveMessage = persist(agency)
    if not saved then return fail(saveMessage) end
    return cert
end

-- Investigation flows: what witnesses near a scene say, per case-type
-- keyword. Maintained in /fedconfig; the interview engine reads them.
function Editor.SaveInvestigation(source, agencyId, payload)
    local agency, message = Editor.EditableFor(source, agencyId, 'roster.manage')
    if not agency then return fail(message) end

    local flow, flowMessage = Schema.InvestigationFlow(type(payload) == 'table' and payload or {})
    if not flow then return fail(flowMessage) end

    agency.investigations = agency.investigations or {}
    local _, index = Schema.FindById(agency.investigations, flow.id)
    if index then
        agency.investigations[index] = flow
    else
        agency.investigations[#agency.investigations + 1] = flow
    end

    local saved, saveMessage = persist(agency)
    if not saved then return fail(saveMessage) end
    return flow
end

function Editor.DeleteInvestigation(source, agencyId, flowId)
    local agency, message = Editor.EditableFor(source, agencyId, 'roster.manage')
    if not agency then return fail(message) end

    local flow, index = Schema.FindById(agency.investigations or {}, flowId)
    if not index then return fail('no such investigation flow') end

    table.remove(agency.investigations, index)
    local saved, saveMessage = persist(agency)
    if not saved then return fail(saveMessage) end
    return flow
end

-- One handler shape for every editor operation: run it, report the reason on
-- failure, and let PersistAgency push the new registry to every client.
local function editorEvent(name, handler, describe)
    RegisterNetEvent(Federal.Net('editor:' .. name), function(...)
        local playerSource = source
        local result, message = handler(playerSource, ...)
        if not result then
            return Bridge.Notify(playerSource, message or 'that edit was refused', 'error')
        end
        Bridge.Notify(playerSource, describe(result), 'success')
    end)
end

editorEvent('agencyCreate', Editor.CreateAgency, function(agency) return ('Created %s.'):format(agency.label) end)
editorEvent('agencyUpdate', Editor.UpdateAgency, function(agency) return ('Updated %s.'):format(agency.label) end)
editorEvent('agencyDelete', Editor.DeleteAgency, function(agency) return ('Deleted %s.'):format(agency.label) end)
editorEvent('stationSave', Editor.SaveStation, function(station) return ('Saved station %s.'):format(station.label) end)
editorEvent('stationDelete', Editor.DeleteStation, function(station) return ('Deleted station %s.'):format(station.label) end)
editorEvent('zoneSave', Editor.SaveZone, function(zone) return ('Placed %s.'):format(zone.label) end)
editorEvent('zoneDelete', Editor.DeleteZone, function(zone) return ('Removed %s.'):format(zone.label) end)
editorEvent('rankSave', Editor.SaveRank, function(rank) return ('Saved rank %s.'):format(rank.label) end)
editorEvent('rankDelete', Editor.DeleteRank, function(rank) return ('Removed rank %s.'):format(rank.label) end)
editorEvent('divisionSave', Editor.SaveDivision, function(division) return ('Saved division %s.'):format(division.label) end)
editorEvent('divisionDelete', Editor.DeleteDivision, function(division) return ('Removed division %s.'):format(division.label) end)
editorEvent('divisionRankSave', Editor.SaveDivisionRank, function(rank) return ('Saved division rank %s.'):format(rank.label) end)
editorEvent('divisionRankDelete', Editor.DeleteDivisionRank, function(rank) return ('Removed division rank %s.'):format(rank.label) end)
editorEvent('certSave', Editor.SaveCertification, function(cert) return ('Saved certification %s.'):format(cert.label) end)
editorEvent('certDelete', Editor.DeleteCertification, function(cert) return ('Removed certification %s.'):format(cert.label) end)
editorEvent('invSave', Editor.SaveInvestigation, function(flow) return ('Saved investigation flow "%s".'):format(flow.match) end)
editorEvent('invDelete', Editor.DeleteInvestigation, function(flow) return ('Removed investigation flow "%s".'):format(flow.match) end)

return Editor
