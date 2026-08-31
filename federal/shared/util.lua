-- Small pure helpers shared by both sides. Nothing here touches a native, so
-- the validation these back can be exercised directly by the test suite.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Util = {}
Federal.Util = Util

function Util.IsFilledString(value, maximum)
    return type(value) == 'string' and value ~= '' and #value <= (maximum or 120)
end

function Util.IsFiniteNumber(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

function Util.IsInteger(value)
    return Util.IsFiniteNumber(value) and value % 1 == 0
end

function Util.Clamp(value, minimum, maximum)
    if not Util.IsFiniteNumber(value) then return minimum end
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

-- Slugified identifier used for agency, station, zone and uniform ids. Ids end
-- up in menu ids, storage keys and case numbers, so they are restricted to
-- characters that are safe in all three.
function Util.Slug(value, fallback)
    if type(value) ~= 'string' then return fallback end
    local slug = value:lower():gsub('[^%w]+', '-'):gsub('^%-+', ''):gsub('%-+$', '')
    if slug == '' then return fallback end
    return slug:sub(1, 40)
end

function Util.IsSlug(value)
    return type(value) == 'string' and value ~= '' and #value <= 40 and value:match('^[%w][%w%-_]*$') ~= nil
end

-- Deterministic, collision-resistant enough for records that are also keyed by
-- an agency-scoped sequence number. Callers pass a monotonic counter so this
-- never depends on a random seed being set.
function Util.RecordId(prefix, sequence)
    return ('%s-%d'):format(prefix, sequence)
end

function Util.Copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, inner in pairs(value) do copy[key] = Util.Copy(inner, seen) end
    return copy
end

-- Recursive merge used to lay in-game edits over the config defaults. A nil in
-- `patch` leaves the default alone; removing something is done with an explicit
-- tombstone at the record level, never by writing nil.
function Util.Merge(base, patch)
    if type(patch) ~= 'table' then
        if patch == nil then return Util.Copy(base) end
        return patch
    end
    if type(base) ~= 'table' then return Util.Copy(patch) end

    local result = Util.Copy(base)
    for key, value in pairs(patch) do
        if type(value) == 'table' and type(result[key]) == 'table' then
            result[key] = Util.Merge(result[key], value)
        else
            result[key] = Util.Copy(value)
        end
    end
    return result
end

function Util.Count(map)
    local total = 0
    if type(map) ~= 'table' then return total end
    for _ in pairs(map) do total = total + 1 end
    return total
end

-- Stable ordering for menus: maps are iterated with pairs(), which has no
-- defined order, so anything rendered to a player is sorted first.
function Util.SortedValues(map, comparator)
    local values = {}
    if type(map) ~= 'table' then return values end
    for _, value in pairs(map) do values[#values + 1] = value end
    table.sort(values, comparator or function(a, b)
        local left = type(a) == 'table' and (a.label or a.id or '') or tostring(a)
        local right = type(b) == 'table' and (b.label or b.id or '') or tostring(b)
        return tostring(left) < tostring(right)
    end)
    return values
end

function Util.Contains(list, needle)
    if type(list) ~= 'table' then return false end
    for _, value in ipairs(list) do
        if value == needle then return true end
    end
    return false
end

-- Coordinates arrive from config as vector3 and from the editor as a plain
-- table over the network. Both are normalized to a plain table for storage so
-- the JSON store never has to serialize a userdata.
--
-- In-game, CfxLua vectors are a first-class type: type(vector3(...)) returns
-- 'vector3', not 'table' or 'userdata'. Rejecting that type made every
-- server-side GetEntityCoords read normalize to nil, which failed every zone
-- and distance check.
function Util.ToCoords(value)
    local kind = type(value)
    if kind ~= 'table' and kind ~= 'userdata' and kind ~= 'vector3' and kind ~= 'vector4' then return nil end
    local x, y, z = value.x, value.y, value.z
    if x == nil then x, y, z = value[1], value[2], value[3] end
    if not Util.IsFiniteNumber(x) or not Util.IsFiniteNumber(y) or not Util.IsFiniteNumber(z) then return nil end
    return { x = x + 0.0, y = y + 0.0, z = z + 0.0 }
end

function Util.Distance(a, b)
    local left, right = Util.ToCoords(a), Util.ToCoords(b)
    if not left or not right then return nil end
    local dx, dy, dz = left.x - right.x, left.y - right.y, left.z - right.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Timestamp rendering without the os library, which does not exist in the
-- client runtime (os.date there crashes with "attempt to index a nil value").
-- Pure calendar math from a POSIX timestamp, UTC.
local MONTHS = { 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' }

local function civilFrom(seconds)
    local days = math.floor(seconds / 86400)
    local rem = seconds % 86400
    -- Howard Hinnant's civil-from-days algorithm.
    local z = days + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local day = doy - math.floor((153 * mp + 2) / 5) + 1
    local month = mp < 10 and mp + 3 or mp - 9
    return day, month, math.floor(rem / 3600), math.floor((rem % 3600) / 60)
end

-- '12 Mar 14:05'
function Util.Stamp(seconds)
    seconds = tonumber(seconds)
    if not seconds or seconds <= 0 then return '' end
    local day, month, hour, minute = civilFrom(math.floor(seconds))
    return ('%d %s %02d:%02d'):format(day, MONTHS[month] or '?', hour, minute)
end

-- '14:05'
function Util.StampClock(seconds)
    seconds = tonumber(seconds)
    if not seconds or seconds <= 0 then return '' end
    local _, _, hour, minute = civilFrom(math.floor(seconds))
    return ('%02d:%02d'):format(hour, minute)
end

-- Truncates free text before it is stored. Narratives and BOLO descriptions
-- come straight from player input.
function Util.Text(value, maximum, fallback)
    if type(value) ~= 'string' then return fallback end
    local trimmed = value:gsub('^%s+', ''):gsub('%s+$', '')
    if trimmed == '' then return fallback end
    return trimmed:sub(1, maximum or 500)
end

function Util.Money(value)
    if not Util.IsFiniteNumber(value) or value < 0 then return nil end
    return math.floor(value + 0.5)
end

return Util
