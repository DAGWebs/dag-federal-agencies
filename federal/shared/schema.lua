-- Normalizing validators for every record the in-game editor can write.
--
-- Each function takes untrusted input and returns a freshly built record, or
-- `nil, message`. They never mutate or return the caller's table, so a handler
-- cannot be tricked into storing a field the schema does not know about, and a
-- rejected edit leaves the stored record untouched.
--
-- Collections are stored as ARRAYS of records carrying their own `id`/`slot`,
-- never as maps keyed by a number. A sparse numeric-keyed table changes shape
-- when it round-trips through JSON, which would silently rewrite a uniform's
-- component slots on the first save.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Util = Federal.Util
local Const = Federal.Constants
local Schema = {}
Federal.Schema = Schema

local MAX_ZONES = 32
local MAX_STATIONS = 24
local MAX_UNIFORMS = 40
local MAX_ARMORY = 60
local MAX_RANKS = 20
local MAX_DIVISIONS = 16

local function fail(message)
    return nil, message
end

-- Shared by every collection normalizer: rejects duplicates rather than
-- letting the later entry win, because a duplicate id in a station's zones
-- makes the editor's delete action ambiguous.
local function normalizeList(input, limit, label, normalizer, keyField)
    if input == nil then return {} end
    if type(input) ~= 'table' then return fail(('%s must be a list'):format(label)) end

    local list, seen = {}, {}
    for _, entry in ipairs(input) do
        if #list >= limit then return fail(('%s is limited to %d entries'):format(label, limit)) end
        local record, message = normalizer(entry)
        if not record then return fail(message) end

        local key = record[keyField]
        if seen[key] then return fail(('duplicate %s "%s"'):format(label, tostring(key))) end
        seen[key] = true
        list[#list + 1] = record
    end
    return list
end

function Schema.FindById(list, id)
    if type(list) ~= 'table' then return nil end
    for index, entry in ipairs(list) do
        if entry.id == id then return entry, index end
    end
    return nil
end

function Schema.Zone(input)
    if type(input) ~= 'table' then return fail('a zone must be a table') end

    local kind = input.kind
    if not Const.ZoneKinds[kind] then return fail('unknown zone kind "' .. tostring(kind) .. '"') end

    local coords = Util.ToCoords(input.coords)
    if not coords then return fail('a zone requires x, y and z coordinates') end

    local id = Util.IsSlug(input.id) and input.id or Util.Slug(input.label or kind, kind)
    return {
        id = id,
        kind = kind,
        label = Util.Text(input.label, 60, Const.ZoneKinds[kind].label),
        coords = coords,
        heading = Util.Clamp(tonumber(input.heading) or 0.0, 0.0, 360.0),
        radius = Util.Clamp(tonumber(input.radius) or 1.5, 0.5, 25.0),
        minGrade = math.floor(Util.Clamp(tonumber(input.minGrade) or 0, 0, 100))
    }
end

function Schema.Station(input)
    if type(input) ~= 'table' then return fail('a station must be a table') end
    if not Util.IsFilledString(input.label, 60) then return fail('a station requires a label') end

    local coords = Util.ToCoords(input.coords)
    if not coords then return fail('a station requires x, y and z coordinates') end

    local id = Util.IsSlug(input.id) and input.id or Util.Slug(input.label)
    if not id then return fail('a station requires a usable id') end

    local zones, message = normalizeList(input.zones, MAX_ZONES, 'zone', Schema.Zone, 'id')
    if not zones then return fail(message) end

    return {
        id = id,
        label = Util.Text(input.label, 60),
        -- 'hq' or 'field': one headquarters, any number of field offices.
        -- Purely descriptive plus a bigger map icon; every station carries
        -- the same eight room kinds.
        kind = input.kind == 'hq' and 'hq' or 'field',
        -- When false, only members of the agency see this station's blip.
        publicBlip = input.publicBlip ~= false,
        coords = coords,
        blip = Schema.Blip(input.blip),
        zones = zones
    }
end

function Schema.Blip(input)
    if type(input) ~= 'table' then return nil end
    if input.enabled == false then return { enabled = false } end
    return {
        enabled = true,
        sprite = math.floor(Util.Clamp(tonumber(input.sprite) or 60, 1, 826)),
        color = math.floor(Util.Clamp(tonumber(input.color) or 26, 0, 85)),
        scale = Util.Clamp(tonumber(input.scale) or 0.8, 0.2, 2.0),
        shortRange = input.shortRange ~= false
    }
end

-- One ped component or prop slot. Drawable and texture indexes are bounded
-- rather than trusted: an out-of-range index is a client crash, not an error.
local function componentEntry(slots, withPalette)
    return function(input)
        if type(input) ~= 'table' then return fail('a uniform slot must be a table') end

        local slot = tonumber(input.slot)
        if not Util.IsInteger(slot) or not Util.Contains(slots, slot) then
            return fail('unsupported uniform slot ' .. tostring(input.slot))
        end

        local entry = {
            slot = math.floor(slot),
            drawable = math.floor(Util.Clamp(tonumber(input.drawable) or 0, -1, 500)),
            texture = math.floor(Util.Clamp(tonumber(input.texture) or 0, 0, 200))
        }
        if withPalette then entry.palette = math.floor(Util.Clamp(tonumber(input.palette) or 0, 0, 20)) end
        return entry
    end
end

local normalizeComponent = componentEntry(Const.UniformComponents, true)
local normalizeProp = componentEntry(Const.UniformProps, false)

function Schema.Uniform(input)
    if type(input) ~= 'table' then return fail('a uniform must be a table') end
    if not Util.IsFilledString(input.label, 60) then return fail('a uniform requires a label') end

    local variant = input.variant or 'any'
    if not Util.Contains(Const.UniformVariants, variant) then return fail('unknown uniform variant "' .. tostring(variant) .. '"') end

    local components, message = normalizeList(input.components, #Const.UniformComponents, 'uniform component', normalizeComponent, 'slot')
    if not components then return fail(message) end

    local props, propMessage = normalizeList(input.props, #Const.UniformProps, 'uniform prop', normalizeProp, 'slot')
    if not props then return fail(propMessage) end

    if #components == 0 and #props == 0 then return fail('a uniform must set at least one component or prop') end

    local id = Util.IsSlug(input.id) and input.id or Util.Slug(input.label)
    if not id then return fail('a uniform requires a usable id') end

    return {
        id = id,
        label = Util.Text(input.label, 60),
        variant = variant,
        minGrade = math.floor(Util.Clamp(tonumber(input.minGrade) or 0, 0, 100)),
        -- When set, only members assigned to this division are issued it.
        division = Util.IsSlug(input.division) and input.division or nil,
        armour = math.floor(Util.Clamp(tonumber(input.armour) or 0, 0, 100)),
        components = components,
        props = props
    }
end

function Schema.ArmoryItem(input)
    if type(input) ~= 'table' then return fail('an armory entry must be a table') end
    if not Util.IsFilledString(input.item, 60) then return fail('an armory entry requires an item name') end

    local id = Util.IsSlug(input.id) and input.id or Util.Slug(input.item)
    if not id then return fail('an armory entry requires a usable id') end

    return {
        id = id,
        item = Util.Text(input.item, 60),
        label = Util.Text(input.label, 60, input.item),
        count = math.floor(Util.Clamp(tonumber(input.count) or 1, 1, 1000)),
        minGrade = math.floor(Util.Clamp(tonumber(input.minGrade) or 0, 0, 100)),
        -- When set, only members assigned to this division may draw it.
        division = Util.IsSlug(input.division) and input.division or nil,
        price = math.floor(Util.Clamp(tonumber(input.price) or 0, 0, 1000000)),
        category = Util.Text(input.category, 30, 'General')
    }
end

local MAX_DIVISION_RANKS = 10

-- A rank inside a division: a title on the taskforce's own ladder (SWAT
-- Operator, Team Lead...), independent of the agency job grade. Division
-- ranks carry no permissions - those stay on the agency ladder.
function Schema.DivisionRank(input)
    if type(input) ~= 'table' then return fail('a division rank must be a table') end
    if not Util.IsFilledString(input.label, 40) then return fail('a division rank requires a label') end

    local grade = tonumber(input.grade)
    if not Util.IsInteger(grade) or grade < 0 or grade > 100 then
        return fail('a division rank requires a grade between 0 and 100')
    end

    return {
        id = ('grade-%d'):format(math.floor(grade)),
        grade = math.floor(grade),
        label = Util.Text(input.label, 40)
    }
end

-- A sub-department inside an agency (a division): an id, a label, optionally
-- the agency grade it starts being joinable at, and its own rank ladder.
-- Assignment of members (and their division rank) is stored separately,
-- keyed by identifier.
function Schema.Division(input)
    if type(input) ~= 'table' then return fail('a division must be a table') end
    if not Util.IsFilledString(input.label, 40) then return fail('a division requires a label') end

    local id = Util.IsSlug(input.id) and input.id or Util.Slug(input.label)
    if not id then return fail('a division requires a usable id') end

    local ranks, message = normalizeList(input.ranks, MAX_DIVISION_RANKS, 'division rank', Schema.DivisionRank, 'id')
    if not ranks then return fail(message) end
    table.sort(ranks, function(a, b) return a.grade < b.grade end)

    return {
        id = id,
        label = Util.Text(input.label, 40),
        minGrade = math.floor(Util.Clamp(tonumber(input.minGrade) or 0, 0, 100)),
        callsignPrefix = Schema.CallsignPrefix(input.callsignPrefix),
        ranks = ranks
    }
end

-- A callsign prefix ('1F-'): the fixed left half every member's callsign is
-- forced onto. Blank means "no override here" - a division without one falls
-- back to the agency's, an agency without one falls back to its short code.
function Schema.CallsignPrefix(input)
    local prefix = Util.Text(input, 8)
    if not prefix then return nil end
    prefix = prefix:upper():gsub('%s', '')
    return prefix ~= '' and prefix or nil
end

function Schema.Rank(input)
    if type(input) ~= 'table' then return fail('a rank must be a table') end
    if not Util.IsFilledString(input.label, 40) then return fail('a rank requires a label') end

    local grade = tonumber(input.grade)
    if not Util.IsInteger(grade) or grade < 0 or grade > 100 then return fail('a rank requires a grade between 0 and 100') end

    local permissions = {}
    if input.permissions ~= nil then
        if type(input.permissions) ~= 'table' then return fail('rank permissions must be a table') end
        for name, enabled in pairs(input.permissions) do
            if enabled == true then
                if not Const.Permissions[name] then return fail('unknown permission "' .. tostring(name) .. '"') end
                permissions[name] = true
            end
        end
    end

    return {
        id = ('grade-%d'):format(math.floor(grade)),
        grade = math.floor(grade),
        label = Util.Text(input.label, 40),
        permissions = permissions
    }
end

-- Per-agency CAD configuration. `shareWith` is a read-only grant: naming
-- another agency lets its officers read this agency's records, never write.
function Schema.Cad(input)
    input = type(input) == 'table' and input or {}

    local modules = {}
    for _, name in ipairs({ 'incidents', 'warrants', 'bolos', 'evidence', 'records', 'units' }) do
        modules[name] = input.modules == nil or input.modules[name] ~= false
    end

    local shareWith = {}
    if type(input.shareWith) == 'table' then
        for _, agencyId in ipairs(input.shareWith) do
            if Util.IsSlug(agencyId) then shareWith[#shareWith + 1] = agencyId end
        end
    end

    return {
        enabled = input.enabled ~= false,
        prefix = (Util.IsSlug(input.prefix) and input.prefix or 'FED'):upper():sub(1, 6),
        modules = modules,
        shareWith = shareWith,
        -- The agency crest shown on the terminal. An https image link, same
        -- rule as CAD photos; anything else is dropped and the terminal
        -- renders the short-code badge instead.
        logo = (type(input.logo) == 'string' and input.logo:find('^https://')) and input.logo:sub(1, 300) or nil
    }
end

-- A certification the agency can award to members: Field Training, SWAT,
-- Firearms... The catalog lives on the agency; awards live per member.
function Schema.Certification(input)
    if type(input) ~= 'table' then return fail('a certification must be a table') end
    if not Util.IsFilledString(input.label, 40) then return fail('a certification requires a label') end

    local id = Util.IsSlug(input.id) and input.id or Util.Slug(input.label)
    if not id then return fail('a certification requires a usable id') end

    -- Prerequisite framework licences: an Aviation certification can demand
    -- practical_plane AND practical_heli before anyone may award it.
    -- Accepts an array of names or a {name = true} map.
    local licences = {}
    if type(input.licences) == 'table' then
        for key, value in pairs(input.licences) do
            local name = type(key) == 'number' and value or (value == true and key or nil)
            if type(name) == 'string' and #licences < 8 then
                name = name:lower():gsub('%s', '')
                if name ~= '' then licences[#licences + 1] = name end
            end
        end
        table.sort(licences)
    end

    return {
        id = id,
        label = Util.Text(input.label, 40),
        description = Util.Text(input.description, 120),
        licences = #licences > 0 and licences or nil
    }
end

local MAX_CERTIFICATIONS = 24

-- A configured witness flow for investigations: matched by keyword against
-- the case type; its statements (and pressable details) replace the
-- built-in ones when it matches. Lead lines may be plain text or
-- 'kind: text' where kind is contact/ledger/name/address.
function Schema.InvestigationFlow(input)
    if type(input) ~= 'table' then return fail('an investigation flow must be a table') end

    local match = Util.Text(input.match, 30)
    if not match then return fail('a flow requires a match keyword (e.g. fraud)') end
    match = match:lower():gsub('%s+$', '')

    local id = Util.IsSlug(input.id) and input.id or Util.Slug(match)
    if not id then return fail('a flow requires a usable id') end

    local statements = {}
    for _, line in ipairs(input.statements or {}) do
        local text = Util.Text(line, 240)
        if text and #statements < 10 then statements[#statements + 1] = text end
    end
    if #statements == 0 then return fail('a flow needs at least one statement') end

    local leads = {}
    for _, entry in ipairs(input.leads or {}) do
        local kind, text
        if type(entry) == 'table' then
            kind, text = entry.kind, entry.text
        elseif type(entry) == 'string' then
            kind, text = entry:match('^(%w+)%s*:%s*(.+)$')
            if not kind then kind, text = 'contact', entry end
        end
        text = Util.Text(text, 240)
        if text and #leads < 8 then
            leads[#leads + 1] = {
                kind = (kind == 'ledger' or kind == 'name' or kind == 'address') and kind or 'contact',
                text = text
            }
        end
    end

    return { id = id, match = match, statements = statements, leads = leads }
end

local MAX_INVESTIGATIONS = 12

function Schema.Agency(input)
    if type(input) ~= 'table' then return fail('an agency must be a table') end
    if not Util.IsFilledString(input.label, 80) then return fail('an agency requires a label') end

    local id = Util.IsSlug(input.id) and input.id or Util.Slug(input.short or input.label)
    if not id then return fail('an agency requires a usable id') end

    -- Framework job names that count as membership. Defaulting to the agency
    -- id keeps a freshly created agency usable before anyone edits it.
    local jobs = {}
    if type(input.jobs) == 'table' then
        for _, job in ipairs(input.jobs) do
            if Util.IsFilledString(job, 40) then jobs[#jobs + 1] = job end
        end
    end
    if #jobs == 0 then jobs[1] = id end

    local ranks, message = normalizeList(input.ranks, MAX_RANKS, 'rank', Schema.Rank, 'id')
    if not ranks then return fail(message) end
    table.sort(ranks, function(a, b) return a.grade < b.grade end)

    local stations, stationMessage = normalizeList(input.stations, MAX_STATIONS, 'station', Schema.Station, 'id')
    if not stations then return fail(stationMessage) end

    local uniforms, uniformMessage = normalizeList(input.uniforms, MAX_UNIFORMS, 'uniform', Schema.Uniform, 'id')
    if not uniforms then return fail(uniformMessage) end

    local armory, armoryMessage = normalizeList(input.armory, MAX_ARMORY, 'armory entry', Schema.ArmoryItem, 'id')
    if not armory then return fail(armoryMessage) end

    local divisions, divisionMessage = normalizeList(input.divisions, MAX_DIVISIONS, 'division', Schema.Division, 'id')
    if not divisions then return fail(divisionMessage) end

    local certifications, certMessage = normalizeList(
        input.certifications, MAX_CERTIFICATIONS, 'certification', Schema.Certification, 'id')
    if not certifications then return fail(certMessage) end

    local investigations, invMessage = normalizeList(
        input.investigations, MAX_INVESTIGATIONS, 'investigation flow', Schema.InvestigationFlow, 'id')
    if not investigations then return fail(invMessage) end

    -- NPC callout dispatch policy, configurable by the director. civilianLimit
    -- gates AUTOMATIC dispatch: NPC callouts only fire on their own while
    -- fewer than this many players who do NOT work for the agency are online
    -- (0 = no gate). Forced callouts bypass the gate.
    local npc = type(input.npcCallouts) == 'table' and input.npcCallouts or {}
    local npcCallouts = {
        enabled = npc.enabled ~= false,
        civilianLimit = math.floor(Util.Clamp(tonumber(npc.civilianLimit) or 0, 0, 1024)),
        -- Concurrency cap for this agency's callouts (0 = use the global
        -- default). Whatever it says, dispatch never exceeds one callout per
        -- officer on duty: nobody gets buried alone.
        maxActive = math.floor(Util.Clamp(tonumber(npc.maxActive) or 0, 0, 12))
    }

    return {
        id = id,
        label = Util.Text(input.label, 80),
        short = (Util.Text(input.short, 8, input.label) or id):upper(),
        callsignPrefix = Schema.CallsignPrefix(input.callsignPrefix),
        jobs = jobs,
        bossGrade = math.floor(Util.Clamp(tonumber(input.bossGrade) or 4, 0, 100)),
        color = Util.Text(input.color, 9, '#4c8dff'),
        blip = Schema.Blip(input.blip),
        cad = Schema.Cad(input.cad),
        ranks = ranks,
        stations = stations,
        uniforms = uniforms,
        armory = armory,
        divisions = divisions,
        certifications = certifications,
        investigations = investigations,
        callouts = input.callouts ~= false,
        npcCallouts = npcCallouts
    }
end

-- Courthouses ------------------------------------------------------------------

-- One placed seat. Seat roles that are not `multiple` are collapsed to a
-- single entry by Schema.Courthouse, so a courthouse cannot end up with two
-- benches and no way to tell which one the judge uses.
function Schema.Seat(input)
    if type(input) ~= 'table' then return fail('a seat must be a table') end
    if not Const.SeatRoles[input.role] then return fail('unknown seat role "' .. tostring(input.role) .. '"') end

    local coords = Util.ToCoords(input.coords)
    if not coords then return fail('a seat requires x, y and z coordinates') end

    local id = Util.IsSlug(input.id) and input.id or Util.Slug(input.label or input.role, input.role)
    return {
        id = id,
        role = input.role,
        label = Util.Text(input.label, 60, Const.SeatRoles[input.role].label),
        coords = coords,
        heading = Util.Clamp(tonumber(input.heading) or 0.0, 0.0, 360.0)
    }
end

local MAX_SEATS = 40

function Schema.Courthouse(input)
    if type(input) ~= 'table' then return fail('a courthouse must be a table') end
    if not Util.IsFilledString(input.label, 60) then return fail('a courthouse requires a label') end

    local coords = Util.ToCoords(input.coords)
    if not coords then return fail('a courthouse requires x, y and z coordinates') end

    local id = Util.IsSlug(input.id) and input.id or Util.Slug(input.label)
    if not id then return fail('a courthouse requires a usable id') end

    local seats, message = normalizeList(input.seats, MAX_SEATS, 'seat', Schema.Seat, 'id')
    if not seats then return fail(message) end

    -- Single-position roles keep the last one placed: re-placing the bench is
    -- how you move it, not how you get a second one.
    local singles, ordered = {}, {}
    for _, seat in ipairs(seats) do
        if Const.SeatRoles[seat.role].multiple then
            ordered[#ordered + 1] = seat
        else
            singles[seat.role] = seat
        end
    end
    for _, role in ipairs(Const.SeatRoleOrder) do
        if singles[role] then ordered[#ordered + 1] = singles[role] end
    end

    return {
        id = id,
        label = Util.Text(input.label, 60),
        coords = coords,
        blip = Schema.Blip(input.blip),
        seats = ordered
    }
end

function Schema.SeatsFor(courthouse, role)
    local matches = {}
    for _, seat in ipairs(courthouse and courthouse.seats or {}) do
        if seat.role == role then matches[#matches + 1] = seat end
    end
    return matches
end

return Schema
