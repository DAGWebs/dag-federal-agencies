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

-- Which sub-department (division) a member belongs to, keyed by framework
-- identifier so it follows the character. The division catalog itself lives
-- on the agency record; this store only holds assignments.
local memberDivisions = DAG.Repository.Create('federal_member_divisions')

-- A member's callsign SUFFIX ('12', 'ADAM'), keyed by agency + identifier.
-- Only the suffix is stored: the prefix is composed at read time from the
-- member's division (or agency), so renaming a prefix or moving somebody
-- into SWAT re-brands their callsign without touching this store.
local callsigns = DAG.Repository.Create('federal_callsigns')

function Core.DivisionAssignment(identifier)
    if type(identifier) ~= 'string' then return nil end
    local record = memberDivisions.get(identifier)
    if not record then return nil end
    return record.division, tonumber(record.grade) or 0
end

-- Resolves the assignment against the agency's catalog: a stale assignment to
-- a deleted division reads as "no division" rather than a dangling id.
function Core.DivisionOf(identifier, agency)
    local divisionId = Core.DivisionAssignment(identifier)
    if not divisionId or type(agency) ~= 'table' then return nil end
    return Schema.FindById(agency.divisions or {}, divisionId)
end

-- The member's rank on the division's own ladder: the highest division rank
-- whose grade they have reached, like Core.Rank does for the agency ladder.
function Core.DivisionRankOf(identifier, division)
    if type(division) ~= 'table' or #(division.ranks or {}) == 0 then return nil end
    local _, grade = Core.DivisionAssignment(identifier)
    local best
    for _, rank in ipairs(division.ranks) do
        if (grade or 0) >= rank.grade and (not best or rank.grade > best.grade) then best = rank end
    end
    return best
end

function Core.AssignDivision(identifier, agencyId, divisionId, grade)
    if type(identifier) ~= 'string' or identifier == '' then return false, 'no identifier' end
    if divisionId == nil then
        memberDivisions.delete(identifier)
        return true
    end
    local saved, message = memberDivisions.save(identifier, {
        id = identifier, agency = agencyId, division = divisionId,
        grade = math.floor(Util.Clamp(tonumber(grade) or 0, 0, 100))
    })
    return saved ~= nil, message
end

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
                -- Baseline kit the config ships (the MDT tablet, evidence
                -- bags, test kits...) re-joins an edited agency's armory:
                -- an agency saved BEFORE a config addition would otherwise
                -- never see the new gear. Items a director deliberately
                -- removed stay removed via the armoryRemoved tombstones.
                local baseline = merged[agency.id]
                if baseline then
                    local removed = {}
                    for _, removedId in ipairs(stored.armoryRemoved or {}) do removed[removedId] = true end
                    agency.armoryRemoved = stored.armoryRemoved
                    for _, entry in ipairs(baseline.armory or {}) do
                        if not removed[entry.id] and not Schema.FindById(agency.armory or {}, entry.id) then
                            agency.armory = agency.armory or {}
                            agency.armory[#agency.armory + 1] = Util.Copy(entry)
                        end
                    end
                end
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
-- Borrowed terminal sessions --------------------------------------------------
--
-- A stolen MDT tablet or a stolen agency vehicle is still logged in as the
-- member who drew it. Whoever holds it works the CAD ON THE OWNER'S
-- identity: their filings carry the owner's name, they can read and write
-- (never expunge, never issue warrants), and the session dies on its own.

local borrowedSessions = {}

function Core.BorrowSession(source, session)
    if type(session) ~= 'table' or type(session.agency) ~= 'string' then return false end
    borrowedSessions[source] = {
        agency = session.agency,
        name = session.name or 'Unknown operator',
        identifier = session.identifier or ('terminal:%d'):format(source),
        callsign = session.callsign,
        expires = os.time() + 600
    }
    return true
end

function Core.BorrowedSession(source)
    local session = borrowedSessions[source]
    if session and session.expires > os.time() then return session end
    borrowedSessions[source] = nil
    return nil
end

AddEventHandler('playerDropped', function()
    borrowedSessions[source] = nil
end)

-- The membership a live borrowed session stands in for: the ORIGINAL
-- owner's identity with CAD-only permissions.
local function borrowedMembership(source)
    local session = Core.BorrowedSession(source)
    if not session then return nil end
    local stolen = registry().map[session.agency]
    if not stolen then return nil end
    return {
        source = source,
        identifier = session.identifier,
        name = session.name,
        agency = Util.Copy(stolen),
        grade = 0,
        rank = {
            grade = 0,
            label = 'Terminal session',
            permissions = { ['cad.view'] = true, ['cad.write'] = true }
        },
        isBoss = false,
        onDuty = true,
        borrowed = true
    }
end

local function borrowedStandIn(source, permission)
    if permission ~= 'cad.view' and permission ~= 'cad.write' then return nil end
    return borrowedMembership(source)
end

function Core.Membership(source)
    if not Core.Enabled() or type(source) ~= 'number' or source <= 0 then return nil end

    local job = Bridge.GetJob(source)
    local agency = job and Core.AgencyForJob(job.name) or nil

    if not agency then
        -- No real membership: an unexpired borrowed session stands in.
        return borrowedMembership(source)
    end

    local unit = units[source]
    local identifier = Bridge.GetIdentifier(source)
    local division = Core.DivisionOf(identifier, agency)
    return {
        source = source,
        identifier = identifier,
        name = Bridge.GetName(source),
        agency = agency,
        job = job,
        grade = job.grade,
        rank = Core.Rank(agency, job.grade),
        isBoss = job.grade >= (agency.bossGrade or 4),
        division = division,
        divisionRank = division and Core.DivisionRankOf(identifier, division) or nil,
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
        -- A member whose own rank cannot do this may still be holding a
        -- terminal that is signed in as somebody whose rank can.
        local standIn = borrowedStandIn(source, permission)
        if standIn then return standIn end
        Bridge.Notify(source, 'Your rank does not authorize that.', 'error')
        return nil
    end

    if options.duty ~= false and settings().requireDuty ~= false and not membership.onDuty and not Core.IsAdmin(source) then
        -- Off duty, but working a signed-in terminal: the SESSION is on
        -- duty even when the person holding it is not.
        local standIn = borrowedStandIn(source, permission)
        if standIn then return standIn end
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

-- Callsigns -----------------------------------------------------------------
--
-- A callsign belongs to the member, not to the clock-in: whoever signs on
-- gets THEIR callsign, not FIB-<whatever number they happened to be>. The
-- left half is a fixed prefix set per agency (and overridable per division)
-- in the config panel; nobody types around it. The right half is a stored
-- suffix - auto-numbered on first clock-in, changeable by roster managers
-- for anyone, and by members themselves only when their rank carries
-- 'callsign.self'.

local function callsignKey(agencyId, identifier)
    return ('%s:%s'):format(agencyId, identifier)
end

-- The forced left half for this member: division prefix, else agency prefix,
-- else the agency short code with a dash.
function Core.CallsignPrefix(membership)
    if membership.division and membership.division.callsignPrefix then
        return membership.division.callsignPrefix
    end
    return membership.agency.callsignPrefix or (membership.agency.short .. '-')
end

-- The lowest positive number no stored suffix in this agency already uses.
local function nextFreeSuffix(agencyId)
    local used = {}
    for key, record in pairs(callsigns.all()) do
        if key:sub(1, #agencyId + 1) == agencyId .. ':' then
            local number = tonumber(record.suffix)
            if number then used[number] = true end
        end
    end
    local candidate = 1
    while used[candidate] do candidate = candidate + 1 end
    return tostring(candidate)
end

-- The member's full callsign, assigning a numbered suffix on first use.
function Core.CallsignFor(membership)
    local key = callsignKey(membership.agency.id, membership.identifier)
    local record = callsigns.get(key)
    if not record then
        record = { suffix = nextFreeSuffix(membership.agency.id), at = os.time() }
        callsigns.save(key, record)
    end
    return Core.CallsignPrefix(membership) .. record.suffix
end

-- A typed suffix, cleaned: uppercased, spaces and punctuation dropped, and a
-- prefix the user typed anyway stripped off rather than doubled.
local function normalizeSuffix(prefix, input)
    local suffix = tostring(input or ''):upper():gsub('%s', '')
    if suffix:sub(1, #prefix) == prefix then suffix = suffix:sub(#prefix + 1) end
    suffix = suffix:gsub('[^%w]', '')
    if suffix == '' or #suffix > 8 then return nil end
    return suffix
end

-- Setting a callsign. With no target (or targeting yourself) this is the
-- self-service path and needs 'callsign.self'; pointing it at somebody else
-- is roster management. Either way the prefix is forced.
function Core.SetCallsign(source, targetSource, input)
    targetSource = tonumber(targetSource) or source
    local self = targetSource == source

    local actor = Core.Membership(source)
    if not actor then return nil, 'not a member of a federal agency' end

    if self then
        if not (Core.Can(source, 'callsign.self') or Core.Can(source, 'roster.manage') or Core.IsAdmin(source)) then
            return nil, 'your rank does not choose its own callsign'
        end
    elseif not (Core.Can(source, 'roster.manage') or Core.IsAdmin(source)) then
        return nil, 'setting callsigns is a roster action'
    end

    local target = self and actor or Core.Membership(targetSource)
    if not target then return nil, 'they are not a member of a federal agency' end
    if target.agency.id ~= actor.agency.id and not Core.IsAdmin(source) then
        return nil, 'they serve a different agency'
    end

    local prefix = Core.CallsignPrefix(target)
    local suffix = normalizeSuffix(prefix, input)
    if not suffix then return nil, ('a callsign is %s plus 1-8 letters or digits'):format(prefix) end

    -- One suffix per member; two units answering to the same callsign is a
    -- radio disaster, so a taken suffix is refused outright.
    local key = callsignKey(target.agency.id, target.identifier)
    for otherKey, record in pairs(callsigns.all()) do
        if otherKey ~= key and record.suffix == suffix
            and otherKey:sub(1, #target.agency.id + 1) == target.agency.id .. ':' then
            return nil, ('%s%s is already assigned'):format(prefix, suffix)
        end
    end

    callsigns.save(key, { suffix = suffix, setBy = actor.name, at = os.time() })

    -- A unit already on the air re-brands live.
    local unit = units[targetSource]
    if unit and unit.identifier == target.identifier then
        unit.callsign = prefix .. suffix
        Core.BroadcastRoster(unit.agency)
    end
    return prefix .. suffix
end

-- Duty roster ---------------------------------------------------------------

function Core.SetDuty(source, onDuty, stationId, callsign)
    -- Clocking off deliberately does NOT require membership. A dismissed
    -- officer's job has already changed by the time we get here, and any
    -- resource can change a job out from under us; someone who is no longer
    -- in the agency must still be able to leave its roster.
    if not onDuty then
        local unit = units[source]
        units[source] = nil
        Bridge.SetDuty(source, false)
        if unit then Core.BroadcastRoster(unit.agency) end
        return true
    end

    local membership = Core.Membership(source)
    if not membership then return false, 'not a member of a federal agency' end

    local station = Schema.FindById(membership.agency.stations, stationId) or membership.agency.stations[1]
    units[source] = {
        source = source,
        identifier = membership.identifier,
        name = membership.name,
        agency = membership.agency.id,
        station = station and station.id or nil,
        rank = membership.rank and membership.rank.label or 'Unranked',
        grade = membership.grade,
        division = membership.division and membership.division.label or nil,
        divisionRank = membership.divisionRank and membership.divisionRank.label or nil,
        -- Their callsign, not their clock-in number. The client-typed value
        -- is deliberately ignored: assignment goes through Core.SetCallsign.
        callsign = Core.CallsignFor(membership),
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

    -- Panic is not a status you drift out of by pressing something else; it
    -- clears only when the officer clears it.
    if status == 'panic' then return Core.SetPanic(source, true) end
    if unit.panic and status ~= 'available' then return false end
    if unit.panic then return Core.SetPanic(source, false) end

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

-- The roster with live positions attached, which is what a map needs. Kept
-- separate from Core.Units so a menu listing does not pay for a position read
-- per unit every time it opens.
function Core.UnitPositions(agencyId)
    local list = {}
    for source, unit in pairs(units) do
        if not agencyId or unit.agency == agencyId then
            local entry = Util.Copy(unit)
            entry.coords = Core.Coords(source)
            list[#list + 1] = entry
        end
    end
    return list
end

-- Agencies whose units this player should see: their own, plus any that share
-- records with them when the config allows it.
function Core.VisibleUnitAgencies(source)
    local membership = Core.Membership(source)
    if not membership then return {} end

    local visible = { [membership.agency.id] = true }
    if ((settings().units or {}).shared) ~= false then
        for agencyId in pairs(Core.ReadableAgencies(source)) do visible[agencyId] = true end
    end
    return visible
end

-- Panic is the one status that has to do something. It is held on the unit so
-- it survives a status change and only clears when the officer clears it.
function Core.SetPanic(source, active)
    local unit = units[source]
    if not unit then return false end

    unit.panic = active == true
    unit.status = active and 'panic' or 'available'
    unit.panicAt = active and os.time() or nil

    if active then
        local position = Core.Coords(source)
        for _, playerSource in ipairs(Core.OnDutySources(unit.agency)) do
            TriggerClientEvent(Federal.Net('panic'), playerSource, {
                source = source,
                name = unit.name,
                callsign = unit.callsign,
                agency = unit.agency,
                coords = position
            })
        end

        if Federal.Dispatch and position then
            Federal.Dispatch.Alert({
                id = ('panic-%d'):format(source),
                agency = unit.agency,
                title = 'Officer needs assistance',
                message = ('%s %s'):format(unit.callsign or '', unit.name or ''),
                coords = position,
                sprite = 161,
                colour = 1,
                priority = 3,
                code = '10-13'
            })
        end
    else
        for _, playerSource in ipairs(Core.OnDutySources(unit.agency)) do
            TriggerClientEvent(Federal.Net('panic:clear'), playerSource, source)
        end
    end

    Core.BroadcastRoster(unit.agency)
    return true
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
            division = membership.division and membership.division.label or nil,
            divisionId = membership.division and membership.division.id or nil,
            divisionRank = membership.divisionRank and membership.divisionRank.label or nil,
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

-- Live positions, pushed to each on-duty officer for the agencies they can
-- see. Sent per player rather than broadcast because who you may see depends
-- on which agencies share with yours.
function Core.BroadcastPositions()
    local unitSettings = settings().units or {}
    if unitSettings.enabled == false then return 0 end

    local sent = 0
    for source, unit in pairs(units) do
        local visible = Core.VisibleUnitAgencies(source)
        local payload = {}

        for agencyId in pairs(visible) do
            for _, entry in ipairs(Core.UnitPositions(agencyId)) do
                -- No point drawing a blip on yourself.
                if entry.source ~= source and entry.coords then payload[#payload + 1] = entry end
            end
        end

        TriggerClientEvent(Federal.Net('units'), source, payload)
        sent = sent + 1
        if unit.panic then payload.panic = true end
    end
    return sent
end

AddEventHandler('playerDropped', function()
    local dropped = source
    local unit = units[dropped]
    units[dropped] = nil
    if unit then
        -- A panicking officer who disconnects should not leave a beacon that
        -- nobody can clear.
        if unit.panic then
            for _, playerSource in ipairs(Core.OnDutySources(unit.agency)) do
                TriggerClientEvent(Federal.Net('panic:clear'), playerSource, dropped)
            end
        end
        Core.BroadcastRoster(unit.agency)
    end
end)

RegisterNetEvent(Federal.Net('panic'), function(active)
    local playerSource = source
    if type(active) ~= 'boolean' then return end
    Core.SetPanic(playerSource, active)
end)

CreateThread(function()
    while true do
        Wait(math.max(tonumber((settings().units or {}).interval) or 3000, 1000))
        if Core.Enabled() then Core.BroadcastPositions() end
    end
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

-- What the callsign dialog needs to render: the forced prefix, the current
-- callsign, and whether this player may self-serve at all.
Bridge.RegisterCallback(Federal.Net('callsign:info'), function(source, reply)
    local membership = Core.Membership(source)
    if not membership then return reply(nil) end
    reply({
        prefix = Core.CallsignPrefix(membership),
        current = Core.CallsignFor(membership),
        canSelf = Core.Can(source, 'callsign.self') or Core.Can(source, 'roster.manage') or Core.IsAdmin(source)
    })
end)

RegisterNetEvent(Federal.Net('callsign:set'), function(targetSource, suffix)
    local playerSource = source
    local callsign, message = Core.SetCallsign(playerSource, targetSource, suffix)
    Bridge.Notify(playerSource, callsign and ('Callsign set: %s'):format(callsign) or message,
        callsign and 'success' or 'error')
end)

-- Radio traffic: one keyed call sets the unit's status AND reads out on
-- every on-duty unit's screen, phrased on the phonetic callsign the way it
-- was spoken. The phrase set is server-owned; the client only names a
-- status, so nobody broadcasts arbitrary text on the working channel.
local RADIO_PHRASES = {
    enroute = 'show me en route',
    onscene = 'show me on scene',
    busy = 'show me code 6, out for investigation',
    available = 'show me back in service',
    panic = 'officer needs assistance, send everything'
}

local RADIO_PHONETIC = {
    A = 'Adam', B = 'Boy', C = 'Charles', D = 'David', E = 'Edward', F = 'Frank',
    G = 'George', H = 'Henry', I = 'Ida', J = 'John', K = 'King', L = 'Lincoln',
    M = 'Mary', N = 'Nora', O = 'Ocean', P = 'Paul', Q = 'Queen', R = 'Robert',
    S = 'Sam', T = 'Tom', U = 'Union', V = 'Victor', W = 'William',
    X = 'X-ray', Y = 'Young', Z = 'Zebra'
}

local function radioPhonetic(callsign)
    local parts = {}
    for character in tostring(callsign or ''):gmatch('%w') do
        parts[#parts + 1] = RADIO_PHONETIC[character:upper()] or character
    end
    return #parts > 0 and table.concat(parts, '-') or 'unit'
end

RegisterNetEvent(Federal.Net('radio:call'), function(status)
    local playerSource = source
    if type(status) ~= 'string' or not RADIO_PHRASES[status] then return end

    local membership = Core.Membership(playerSource)
    if not membership or membership.borrowed or not membership.onDuty then return end

    Core.SetStatus(playerSource, status)

    local unit = units[playerSource]
    local suffix = ''
    if (status == 'enroute' or status == 'onscene')
        and Federal.Callouts and Federal.Callouts.AssignedNumber then
        local number = Federal.Callouts.AssignedNumber(playerSource)
        if number then suffix = (' to %s'):format(number) end
    end

    local text = ('\u{1F4FB} %s: %s%s.'):format(
        radioPhonetic(unit and unit.callsign), RADIO_PHRASES[status], suffix)
    for _, target in ipairs(Core.OnDutySources(membership.agency.id)) do
        TriggerClientEvent(Federal.Net('radio:traffic'), target, text)
    end
end)

-- Setting a unit's status from the terminal: your own freely, somebody
-- else's only with roster.manage (the dispatch seat's prerogative).
RegisterNetEvent(Federal.Net('unit:status'), function(targetSource, status)
    local playerSource = source
    targetSource = tonumber(targetSource) or playerSource
    if type(status) ~= 'string' or not Const.UnitStatus[status] then return end

    if targetSource ~= playerSource then
        if not (Core.Can(playerSource, 'roster.manage') or Core.IsAdmin(playerSource)) then
            return Bridge.Notify(playerSource, "Setting another unit's status is a roster action.", 'error')
        end
        local actor = Core.Membership(playerSource)
        local unit = units[targetSource]
        if not actor or not unit or (unit.agency ~= actor.agency.id and not Core.IsAdmin(playerSource)) then
            return Bridge.Notify(playerSource, 'That unit is not on your roster.', 'error')
        end
    end

    if Core.SetStatus(targetSource, status) then
        Bridge.Notify(playerSource, ('Status set: %s'):format(Const.UnitStatus[status].label), 'inform')
    end
end)

RegisterNetEvent(Federal.Net('status'), function(status)
    local playerSource = source
    if type(status) ~= 'string' then return end
    if Core.SetStatus(playerSource, status) then
        Bridge.Notify(playerSource, ('Status: %s'):format(Const.UnitStatus[status].label), 'inform')
    end
end)

return Core
