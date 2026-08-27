-- Agency registry, rank resolution, permission gates, duty roster and record
-- numbering. Every other federal server module authorizes through this file.
--
-- The registry is a two-layer merge: the catalog in federal/config/agencies.lua
-- seeds it, and records written by the in-game editor replace a seeded agency
-- wholesale. Replacement rather than deep-merge is deliberate — an agency's
-- stations, ranks and uniforms are lists, and there is no sane way to
-- deep-merge a list edit ("the third zone was deleted") against a default.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Util = Federal.Util
local Const = Federal.Constants
local Schema = Federal.Schema

local Core = {}
Federal.Core = Core

local agencies = DAG.Repository.Create('federal_agencies', {
    validate = function(record)
        if record.deleted == true then return true end
        local normalized, message = Schema.Agency(record)
        return normalized ~= nil, message
    end
})

Core.agencies = agencies

-- Permissions a player holds by virtue of out-ranking `agency.bossGrade`,
-- whatever their rank happens to list. Without this a server that rewrites the
-- rank ladder can end up with an agency nobody can administer.
local BOSS_PERMISSIONS = {
    'uniform.manage', 'armory.manage', 'roster.manage', 'callout.manage', 'cad.expunge', 'cad.write', 'cad.view'
}

local cache, cacheValid = nil, false
local units = {}

local function settings()
    return Config.Federal or {}
end

function Core.Enabled()
    return settings().enabled ~= false
end

function Core.Invalidate()
    cache, cacheValid = nil, false
end

-- Config catalog + stored overrides, normalized. An invalid entry is skipped
-- with a printed reason rather than taking the whole registry down: one bad
-- agency in a hand-edited config must not stop the other three from working.
local function build()
    local merged, order = {}, {}

    for _, raw in ipairs(settings().Agencies or {}) do
        local agency, message = Schema.Agency(raw)
        if agency then
            if not merged[agency.id] then order[#order + 1] = agency.id end
            merged[agency.id] = agency
        else
            Bridge.Print('ignoring configured agency %s: %s', tostring(raw and raw.id), tostring(message))
        end
    end

    for id, stored in pairs(agencies.all()) do
        if stored.deleted == true then
            merged[id] = nil
        else
            local agency, message = Schema.Agency(stored)
            if agency then
                if not merged[agency.id] then order[#order + 1] = agency.id end
                merged[agency.id] = agency
            else
                Bridge.Print('ignoring stored agency %s: %s', tostring(id), tostring(message))
            end
        end
    end

    local list = {}
    for _, id in ipairs(order) do
        if merged[id] then list[#list + 1] = merged[id] end
    end
    return { map = merged, list = list }
end

local function registry()
    if not cacheValid then
        cache = build()
        cacheValid = true
    end
    return cache
end

function Core.Agencies()
    return Util.Copy(registry().list)
end

function Core.Agency(id)
    local agency = registry().map[id]
    return agency and Util.Copy(agency) or nil
end

function Core.AgencyForJob(jobName)
    if type(jobName) ~= 'string' then return nil end
    for _, agency in ipairs(registry().list) do
        if Util.Contains(agency.jobs, jobName) then return Util.Copy(agency) end
    end
    return nil
end

-- Highest rank whose grade the player has reached. A player above the top
-- rank keeps the top rank rather than falling through to nothing.
function Core.Rank(agency, grade)
    if type(agency) ~= 'table' then return nil end
    local best
    for _, rank in ipairs(agency.ranks or {}) do
        if grade >= rank.grade and (not best or rank.grade > best.grade) then best = rank end
    end
    return best
end

-- The player's agency membership, derived from the framework job. A job that
-- cannot be read is a denial: Bridge.GetJob returns nil on frameworks with no
-- job support, and treating that as "unemployed" would match a policy entry.
function Core.Membership(source)
    if not Core.Enabled() or type(source) ~= 'number' or source <= 0 then return nil end

    local job = Bridge.GetJob(source)
    if not job then return nil end

    local agency = Core.AgencyForJob(job.name)
    if not agency then return nil end

    local unit = units[source]
    return {
        source = source,
        identifier = Bridge.GetIdentifier(source),
        name = Bridge.GetName(source),
        agency = agency,
        job = job,
        grade = job.grade,
        rank = Core.Rank(agency, job.grade),
        isBoss = job.grade >= (agency.bossGrade or 4),
        onDuty = unit ~= nil,
        unit = unit and Util.Copy(unit) or nil
    }
end

-- Effective permission set. Computed once and shipped to the client so menus
-- can hide what a player cannot do; the server still re-checks every action.
function Core.Permissions(source)
    local membership = Core.Membership(source)
    local granted = {}
    if not membership then return granted, membership end

    if membership.rank then
        for name in pairs(membership.rank.permissions or {}) do granted[name] = true end
    end

    if membership.isBoss then
        for _, name in ipairs(BOSS_PERMISSIONS) do granted[name] = true end
    end

    return granted, membership
end

function Core.IsAdmin(source)
    if source == 0 then return true end
    return Bridge.HasPermission(source, settings().adminPermission or 'federal.admin') == true
end

-- The single gate. `permission` must be a name from Constants.Permissions;
-- an unknown name is a denial, never an accidental match.
function Core.Can(source, permission)
    if not Const.Permissions[permission] then return false end
    if Core.IsAdmin(source) then return true end

    local granted = Core.Permissions(source)
    return granted[permission] == true
end

-- Combined gate used by nearly every handler: membership, permission, and
-- (when the server requires it) being clocked on.
function Core.Require(source, permission, options)
    options = options or {}
    local membership = Core.Membership(source)

    if not membership then
        if not Core.IsAdmin(source) then
            Bridge.Notify(source, 'You are not a member of a federal agency.', 'error')
            return nil
        end
        return nil
    end

    if not Core.Can(source, permission) then
        Bridge.Notify(source, 'Your rank does not authorize that.', 'error')
        return nil
    end

    if options.duty ~= false and settings().requireDuty ~= false and not membership.onDuty and not Core.IsAdmin(source) then
        Bridge.Notify(source, 'Clock on at a station first.', 'error')
        return nil
    end

    return membership
end

-- Agencies whose records `source` may read: their own, plus any agency that
-- named theirs in `cad.shareWith`. Sharing is read-only in both directions.
function Core.ReadableAgencies(source)
    local membership = Core.Membership(source)
    local readable = {}

    if Core.IsAdmin(source) then
        for _, agency in ipairs(registry().list) do readable[agency.id] = true end
        return readable
    end
    if not membership then return readable end

    readable[membership.agency.id] = true
    for _, agency in ipairs(registry().list) do
        if Util.Contains(agency.cad and agency.cad.shareWith or {}, membership.agency.id) then
            readable[agency.id] = true
        end
    end
    return readable
end

-- Position ------------------------------------------------------------------

-- The player's real position, read on the server. Every zone and action check
-- uses this rather than a coordinate supplied by the client.
function Core.Coords(source)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return nil end
    return Util.ToCoords(GetEntityCoords(ped))
end

-- Finds the station zone of `kind` the player is standing in. Returns nil when
-- they are not at one, which is what gates armory, locker and boss actions.
function Core.ZoneAt(source, agency, kind)
    local position = Core.Coords(source)
    if not position or type(agency) ~= 'table' then return nil end

    local limit = tonumber(settings().zoneDistance) or 4.0
    for _, station in ipairs(agency.stations or {}) do
        for _, zone in ipairs(station.zones or {}) do
            if zone.kind == kind then
                local distance = Util.Distance(position, zone.coords)
                if distance and distance <= math.max(limit, zone.radius or 0) then
                    return zone, station, distance
                end
            end
        end
    end
    return nil
end

function Core.RequireZone(source, membership, kind)
    local zone, station = Core.ZoneAt(source, membership.agency, kind)
    if not zone then
        if Core.IsAdmin(source) then return true, nil, nil end
        local label = Const.ZoneKinds[kind] and Const.ZoneKinds[kind].label or kind
        Bridge.Notify(source, ('You must be at a %s to do that.'):format(label:lower()), 'error')
        return false
    end

    if membership.grade < (zone.minGrade or 0) then
        Bridge.Notify(source, 'That area is restricted to a higher grade.', 'error')
        return false
    end
    return true, zone, station
end

-- Duty roster ---------------------------------------------------------------

function Core.SetDuty(source, onDuty, stationId, callsign)
    local membership = Core.Membership(source)
    if not membership then return false, 'not a member of a federal agency' end

    if not onDuty then
        units[source] = nil
        Bridge.SetDuty(source, false)
        Core.BroadcastRoster(membership.agency.id)
        return true
    end

    local station = Schema.FindById(membership.agency.stations, stationId) or membership.agency.stations[1]
    units[source] = {
        source = source,
        identifier = membership.identifier,
        name = membership.name,
        agency = membership.agency.id,
        station = station and station.id or nil,
        rank = membership.rank and membership.rank.label or 'Unranked',
        grade = membership.grade,
        callsign = Util.Text(callsign, 12, ('%s-%d'):format(membership.agency.short, source)),
        status = 'available',
        since = os.time()
    }

    Bridge.SetDuty(source, true)
    Core.BroadcastRoster(membership.agency.id)
    return true
end

function Core.SetStatus(source, status)
    local unit = units[source]
    if not unit or not Const.UnitStatus[status] then return false end
    unit.status = status
    Core.BroadcastRoster(unit.agency)
    return true
end

function Core.Unit(source)
    return units[source] and Util.Copy(units[source]) or nil
end

function Core.Units(agencyId)
    local list = {}
    for _, unit in pairs(units) do
        if not agencyId or unit.agency == agencyId then list[#list + 1] = Util.Copy(unit) end
    end
    table.sort(list, function(a, b) return (a.callsign or '') < (b.callsign or '') end)
    return list
end

-- On-duty sources for an agency, used to dispatch callouts.
function Core.OnDutySources(agencyId)
    local sources = {}
    for source, unit in pairs(units) do
        if unit.agency == agencyId then sources[#sources + 1] = source end
    end
    return sources
end

function Core.BroadcastRoster(agencyId)
    for _, source in ipairs(Core.OnDutySources(agencyId)) do
        TriggerClientEvent(Federal.Net('roster'), source, Core.Units(agencyId))
    end
end

-- Record numbering -----------------------------------------------------------

-- Per-agency, per-series sequence. Persisted so numbers keep climbing across
-- restarts instead of colliding with records that already exist.
function Core.NextNumber(agencyId, series)
    local agency = registry().map[agencyId]
    local prefix = agency and agency.cad and agency.cad.prefix or 'FED'
    local code = Const.Series[series] or 'REC'
    local key = ('%s:%s'):format(agencyId, series)

    local counter = DAG.Storage.Get('federal_counters', key) or { value = 0 }
    local nextValue = (tonumber(counter.value) or 0) + 1
    DAG.Storage.Set('federal_counters', key, { value = nextValue })

    return ('%s-%s-%04d'):format(prefix, code, nextValue), nextValue
end

-- Client sync ---------------------------------------------------------------

function Core.Context(source)
    local granted, membership = Core.Permissions(source)
    return {
        enabled = Core.Enabled(),
        agencies = Core.Agencies(),
        permissions = granted,
        admin = Core.IsAdmin(source),
        membership = membership and {
            agencyId = membership.agency.id,
            grade = membership.grade,
            rank = membership.rank and membership.rank.label or 'Unranked',
            isBoss = membership.isBoss,
            onDuty = membership.onDuty,
            unit = membership.unit
        } or nil
    }
end

-- Pushed after any editor write so every client picks up new zones, blips,
-- uniforms and armory stock without a reconnect.
function Core.Sync(target)
    Core.Invalidate()
    if target then
        return TriggerClientEvent(Federal.Net('context'), target, Core.Context(target))
    end
    for _, playerId in ipairs(GetPlayers()) do
        local playerSource = tonumber(playerId)
        if playerSource then
            TriggerClientEvent(Federal.Net('context'), playerSource, Core.Context(playerSource))
        end
    end
end

AddEventHandler('playerDropped', function()
    local dropped = source
    local unit = units[dropped]
    units[dropped] = nil
    if unit then Core.BroadcastRoster(unit.agency) end
end)

Bridge.RegisterCallback(Federal.Net('context'), function(source, reply)
    reply(Core.Context(source))
end)

RegisterNetEvent(Federal.Net('duty'), function(onDuty, stationId, callsign)
    local playerSource = source
    if type(onDuty) ~= 'boolean' then return end

    local membership = Core.Membership(playerSource)
    if not membership then return Bridge.Notify(playerSource, 'You are not a member of a federal agency.', 'error') end

    -- Clocking on requires standing at a duty point; clocking off never does,
    -- so a player who logs in away from a station is not stuck on duty.
    if onDuty then
        local zone = Core.ZoneAt(playerSource, membership.agency, 'duty')
        if not zone and not Core.IsAdmin(playerSource) then
            return Bridge.Notify(playerSource, 'You must be at a sign-in desk to clock on.', 'error')
        end
    end

    Core.SetDuty(playerSource, onDuty, stationId, callsign)
    Bridge.Notify(playerSource, onDuty and 'You are now on duty.' or 'You are now off duty.', 'success')
    Core.Sync(playerSource)
end)

RegisterNetEvent(Federal.Net('status'), function(status)
    local playerSource = source
    if type(status) ~= 'string' then return end
    if Core.SetStatus(playerSource, status) then
        Bridge.Notify(playerSource, ('Status: %s'):format(Const.UnitStatus[status].label), 'inform')
    end
end)

return Core
