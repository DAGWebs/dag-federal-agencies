-- The armory: what an agency stocks, who may draw it, and who may change it.
--
-- Drawing is gated by rank grade, by standing in an armory zone, and by the
-- price being payable. Managing the stock list is a boss action and goes
-- through the same read-modify-save path as uniforms.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Util = Federal.Util
local Schema = Federal.Schema
local Core = Federal.Core

local Armory = {}
Federal.Armory = Armory

local function fail(message)
    return nil, message
end

local function settings()
    return Config.Federal or {}
end

-- What this player may draw, with the reason each locked line is locked. The
-- client renders the locked rows too: "Assistant Director" is more useful on
-- a greyed row than the row simply being absent.
function Armory.List(source)
    local membership = Core.Membership(source)
    if not membership then return {} end

    local list = {}
    for _, entry in ipairs(membership.agency.armory or {}) do
        local locked = membership.grade < (entry.minGrade or 0)
        local rank = Core.Rank(membership.agency, entry.minGrade or 0)
        list[#list + 1] = {
            id = entry.id,
            item = entry.item,
            label = entry.label,
            category = entry.category,
            count = entry.count,
            price = entry.price,
            minGrade = entry.minGrade,
            locked = locked,
            lockedReason = locked and ('Requires %s'):format(rank and rank.label or ('grade ' .. tostring(entry.minGrade))) or nil
        }
    end

    table.sort(list, function(a, b)
        if a.category == b.category then return tostring(a.label) < tostring(b.label) end
        return tostring(a.category) < tostring(b.category)
    end)
    return list
end

function Armory.Draw(source, entryId)
    local membership = Core.Require(source, 'armory.use')
    if not membership then return fail('not authorized') end

    local allowed = Core.RequireZone(source, membership, 'armory')
    if not allowed then return fail('not at an armory') end

    local entry = Schema.FindById(membership.agency.armory or {}, entryId)
    if not entry then return fail('that item is not stocked') end
    if membership.grade < (entry.minGrade or 0) then return fail('your grade is not issued that item') end

    -- Charge first, then hand over. If the item cannot be added the charge is
    -- refunded, because taking the money and giving nothing is the worse bug.
    local price = entry.price or 0
    if price > 0 and not Bridge.RemoveMoney(source, 'bank', price, 'federal-armory') then
        return fail('you cannot afford that')
    end

    if not Bridge.AddItem(source, entry.item, entry.count or 1) then
        if price > 0 then Bridge.AddMoney(source, 'bank', price, 'federal-armory-refund') end
        return fail('your inventory would not take that item')
    end

    return entry
end

function Armory.Save(source, payload)
    local membership = Federal.Uniforms.RequireBoss(source, 'armory.manage')
    if not membership then return fail('not authorized') end

    local entry, message = Schema.ArmoryItem(payload)
    if not entry then return fail(message) end

    local agency = membership.agency
    agency.armory = agency.armory or {}

    local _, index = Schema.FindById(agency.armory, entry.id)
    if index then
        agency.armory[index] = entry
    else
        agency.armory[#agency.armory + 1] = entry
    end

    local saved, saveMessage = Federal.Uniforms.PersistAgency(agency)
    if not saved then return fail(saveMessage) end
    return entry
end

function Armory.Delete(source, entryId)
    local membership = Federal.Uniforms.RequireBoss(source, 'armory.manage')
    if not membership then return fail('not authorized') end

    local agency = membership.agency
    local entry, index = Schema.FindById(agency.armory or {}, entryId)
    if not index then return fail('that item is not stocked') end

    table.remove(agency.armory, index)
    local saved, saveMessage = Federal.Uniforms.PersistAgency(agency)
    if not saved then return fail(saveMessage) end
    return entry
end

-- Vehicles are spawned by the client; the server's job is to confirm the
-- player is entitled to one and is standing in a motor pool.
function Armory.RequestVehicle(source, model)
    local membership = Core.Require(source, 'armory.use')
    if not membership then return fail('not authorized') end

    local allowed = Core.RequireZone(source, membership, 'garage')
    if not allowed then return fail('not at a motor pool') end

    local name = Util.Text(model, 40)
    if not name then return fail('no vehicle model given') end

    local price = tonumber(settings().vehiclePrice) or 0
    if price > 0 and not Bridge.RemoveMoney(source, 'bank', price, 'federal-motorpool') then
        return fail('you cannot afford that')
    end

    TriggerClientEvent(Federal.Net('spawnVehicle'), source, name)
    return { model = name }
end

RegisterNetEvent(Federal.Net('armory:draw'), function(entryId)
    local playerSource = source
    if type(entryId) ~= 'string' then return end

    local entry, message = Armory.Draw(playerSource, entryId)
    Bridge.Notify(playerSource, entry and ('Drew %s.'):format(entry.label) or message, entry and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('armory:save'), function(payload)
    local playerSource = source
    local entry, message = Armory.Save(playerSource, payload)
    Bridge.Notify(playerSource, entry and ('Stocked %s.'):format(entry.label) or message, entry and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('armory:delete'), function(entryId)
    local playerSource = source
    if type(entryId) ~= 'string' then return end
    local entry, message = Armory.Delete(playerSource, entryId)
    Bridge.Notify(playerSource, entry and ('Removed %s.'):format(entry.label) or message, entry and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('armory:vehicle'), function(model)
    local playerSource = source
    if type(model) ~= 'string' then return end
    local result, message = Armory.RequestVehicle(playerSource, model)
    if not result then Bridge.Notify(playerSource, message, 'error') end
end)

Bridge.RegisterCallback(Federal.Net('armory'), function(source, reply)
    reply(Armory.List(source))
end)

return Armory
