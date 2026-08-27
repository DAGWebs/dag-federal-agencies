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
        price = math.floor(Util.Clamp(tonumber(input.price) or 0, 0, 1000000)),
        category = Util.Text(input.category, 30, 'General')
    }
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
        shareWith = shareWith
    }
end

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

    return {
        id = id,
        label = Util.Text(input.label, 80),
        short = (Util.Text(input.short, 8, input.label) or id):upper(),
        jobs = jobs,
        bossGrade = math.floor(Util.Clamp(tonumber(input.bossGrade) or 4, 0, 100)),
        color = Util.Text(input.color, 9, '#4c8dff'),
        blip = Schema.Blip(input.blip),
        cad = Schema.Cad(input.cad),
        ranks = ranks,
        stations = stations,
        uniforms = uniforms,
        armory = armory,
        callouts = input.callouts ~= false
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
