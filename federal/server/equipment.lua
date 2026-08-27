-- Deployable field equipment: spike strips, cones, barriers, evidence markers,
-- cameras.
--
-- Objects are created by the client that deploys them and registered here, so
-- the server owns the ledger of what is out and who put it there. That is what
-- lets an officer pick up somebody else's cones and stops one player leaving
-- two hundred barriers on a motorway.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Util = Federal.Util
local Core = Federal.Core

local Equipment = {}
Federal.Equipment = Equipment

-- In memory: deployed props do not survive a restart, so a ledger that did
-- would only describe objects that no longer exist.
local deployed, sequence = {}, 0
Equipment.deployed = deployed

local function fail(message)
    return nil, message
end

local function settings()
    return (Config.Federal or {}).equipment or {}
end

function Equipment.Enabled()
    return Core.Enabled() and settings().enabled ~= false
end

function Equipment.Definition(id)
    for _, entry in ipairs(settings().items or {}) do
        if entry.id == id then return entry end
    end
    return nil
end

-- What this officer may deploy, with the reason each locked line is locked.
function Equipment.Available(source)
    local membership = Core.Membership(source)
    if not membership or not Equipment.Enabled() then return {} end

    local list = {}
    for _, entry in ipairs(settings().items or {}) do
        local allowed = entry.permission == nil or Core.Can(source, entry.permission)
        local held = entry.item == nil or Bridge.HasItem(source, entry.item, 1)

        list[#list + 1] = {
            id = entry.id,
            label = entry.label,
            model = entry.model,
            item = entry.item,
            offset = entry.offset,
            locked = not allowed or not held,
            lockedReason = (not allowed and 'Your rank does not carry this')
                or (not held and ('Requires %s'):format(entry.item))
                or nil
        }
    end
    return list
end

function Equipment.CountFor(identifier)
    local total = 0
    for _, entry in pairs(deployed) do
        if entry.identifier == identifier then total = total + 1 end
    end
    return total
end

-- Registers a deployment. The client has already created the object and passes
-- its network id; the server decides whether it was allowed to.
function Equipment.Deploy(source, itemId, netId)
    local membership = Core.Require(source, 'actions.detain', { duty = true })
    if not membership then return fail('not authorized') end
    if not Equipment.Enabled() then return fail('field equipment is disabled') end

    local definition = Equipment.Definition(itemId)
    if not definition then return fail('no such equipment') end
    if definition.permission and not Core.Can(source, definition.permission) then
        return fail('your rank does not carry that')
    end

    local identifier = membership.identifier
    local limit = tonumber(settings().limit) or 8
    if Equipment.CountFor(identifier) >= limit then
        return fail(('you already have %d out; pick some up first'):format(limit))
    end

    if definition.item and not Bridge.RemoveItem(source, definition.item, 1) then
        return fail(('you do not have a %s'):format(definition.item))
    end

    sequence = sequence + 1
    local record = {
        id = Util.RecordId('eqp', sequence),
        netId = tonumber(netId),
        item = itemId,
        label = definition.label,
        agency = membership.agency.id,
        identifier = identifier,
        by = membership.name,
        at = os.time()
    }

    deployed[record.id] = record
    return record
end

-- Anyone in the agency can pick up anyone else's: the alternative is a road
-- full of cones nobody can move because the officer who put them there logged
-- off.
function Equipment.Retrieve(source, recordId)
    local membership = Core.Require(source, 'actions.detain', { duty = true })
    if not membership then return fail('not authorized') end

    local record = deployed[recordId]
    if not record then return fail('that is not there any more') end
    if record.agency ~= membership.agency.id and not Core.IsAdmin(source) then
        return fail('that belongs to another agency')
    end

    local definition = Equipment.Definition(record.item)
    if definition and definition.item then Bridge.AddItem(source, definition.item, 1) end

    deployed[recordId] = nil
    return record
end

function Equipment.List(source)
    local membership = Core.Membership(source)
    if not membership then return {} end

    local list = {}
    for _, record in pairs(deployed) do
        if record.agency == membership.agency.id then list[#list + 1] = Util.Copy(record) end
    end
    table.sort(list, function(a, b) return (a.at or 0) > (b.at or 0) end)
    return list
end

-- Clearing up: a supervisor removing everything an agency has out.
function Equipment.ClearAll(source)
    local membership = Core.Require(source, 'callout.manage')
    if not membership then return fail('not authorized') end

    local cleared = {}
    for id, record in pairs(deployed) do
        if record.agency == membership.agency.id then
            cleared[#cleared + 1] = record.netId
            deployed[id] = nil
        end
    end

    TriggerClientEvent(Federal.Net('equipment:clear'), -1, cleared)
    return { cleared = #cleared }
end

Bridge.RegisterCallback(Federal.Net('equipment:list'), function(source, reply)
    reply({ available = Equipment.Available(source), deployed = Equipment.List(source) })
end)

Bridge.RegisterCallback(Federal.Net('equipment:deploy'), function(source, reply, itemId, netId)
    local record, message = Equipment.Deploy(source, itemId, netId)
    reply(record, message)
end)

Bridge.RegisterCallback(Federal.Net('equipment:retrieve'), function(source, reply, recordId)
    local record, message = Equipment.Retrieve(source, recordId)
    reply(record, message)
end)

RegisterNetEvent(Federal.Net('equipment:clearAll'), function()
    local playerSource = source
    local result, message = Equipment.ClearAll(playerSource)
    Bridge.Notify(playerSource, result and ('Cleared %d item(s).'):format(result.cleared) or message,
        result and 'success' or 'error')
end)

return Equipment
