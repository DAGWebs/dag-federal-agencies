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

-- Resolves the agency this player is allowed to edit. Admins may name any
-- agency; everyone else edits their own and nothing else.
local function editable(source, agencyId)
    if Core.IsAdmin(source) then
        local agency = Core.Agency(agencyId)
        if not agency then return nil, 'no such agency' end
        return agency
    end

    if not Core.Can(source, 'editor.manage') then return nil, 'not authorized' end

    local membership = Core.Membership(source)
    if not membership then return nil, 'not authorized' end
    if agencyId and agencyId ~= membership.agency.id then return nil, 'you may only edit your own agency' end
    return membership.agency
end

Editor.Editable = editable

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
    local station, stationMessage = Schema.Station({
        id = payload.id,
        label = payload.label or (existing and existing.label),
        coords = coords,
        blip = payload.blip or (existing and existing.blip),
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

return Editor
