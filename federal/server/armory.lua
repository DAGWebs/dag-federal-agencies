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
-- Whether this member may draw an entry: grade, and division when the entry
-- is tied to one. Returns ok plus the reason a locked row shows.
local function drawable(source, membership, entry)
    if membership.grade < (entry.minGrade or 0) then
        local rank = Core.Rank(membership.agency, entry.minGrade or 0)
        return false, ('Requires %s'):format(rank and rank.label or ('grade ' .. tostring(entry.minGrade)))
    end
    if entry.division and not Core.IsAdmin(source) then
        local mine = membership.division and membership.division.id
        if mine ~= entry.division then
            local division = Schema.FindById(membership.agency.divisions or {}, entry.division)
            return false, ('Requires %s'):format(division and division.label or 'another division')
        end
    end
    return true
end

Armory.Drawable = drawable

function Armory.List(source)
    local membership = Core.Membership(source)
    if not membership then return {} end

    local list = {}
    for _, entry in ipairs(membership.agency.armory or {}) do
        local ok, reason = drawable(source, membership, entry)
        list[#list + 1] = {
            id = entry.id,
            item = entry.item,
            label = entry.label,
            category = entry.category,
            count = entry.count,
            price = entry.price,
            minGrade = entry.minGrade,
            division = entry.division,
            locked = not ok,
            lockedReason = reason
        }
    end

    table.sort(list, function(a, b)
        if a.category == b.category then return tostring(a.label) < tostring(b.label) end
        return tostring(a.category) < tostring(b.category)
    end)
    return list
end

-- Which ammo a drawn weapon is issued with. Explicit config map first, then
-- pattern matching on the weapon name; nil (stun gun, melee) issues none.
local function ammoFor(item)
    local ammoConfig = settings().armoryAmmo or {}
    if ammoConfig.enabled == false then return nil end

    local map = ammoConfig.map or {}
    if map[item] then return map[item] end
    if not item:find('^weapon_') then return nil end
    if item:find('stungun') or item:find('flashlight') or item:find('nightstick') then return nil end
    if item:find('smg') then return 'smg_ammo' end
    if item:find('shotgun') then return 'shotgun_ammo' end
    if item:find('rifle') or item:find('carbine') or item:find('musket') then return 'rifle_ammo' end
    if item:find('pistol') or item:find('revolver') then return 'pistol_ammo' end
    return nil
end

local function weaponSerial()
    local chars, serial = '0123456789ABCDEF', 'FED'
    for _ = 1, 9 do
        local pick = math.random(#chars)
        serial = serial .. chars:sub(pick, pick)
    end
    return serial
end

-- Deleting stock leaves a tombstone: without it, an item that also exists in
-- the config baseline would quietly re-stock itself on the next restart.
local function tombstoneArmory(agency, entryId)
    agency.armoryRemoved = agency.armoryRemoved or {}
    if not Util.Contains(agency.armoryRemoved, entryId) then
        agency.armoryRemoved[#agency.armoryRemoved + 1] = entryId
    end
end

local function untombstoneArmory(agency, entryId)
    for index, removedId in ipairs(agency.armoryRemoved or {}) do
        if removedId == entryId then
            table.remove(agency.armoryRemoved, index)
            return
        end
    end
end

function Armory.Draw(source, entryId)
    local membership = Core.Require(source, 'armory.use')
    if not membership then return fail('not authorized') end

    local allowed = Core.RequireZone(source, membership, 'armory')
    if not allowed then return fail('not at an armory') end

    local entry = Schema.FindById(membership.agency.armory or {}, entryId)
    if not entry then return fail('that item is not stocked') end

    local ok, reason = drawable(source, membership, entry)
    if not ok then return fail(reason) end

    -- Charge first, then hand over. If the item cannot be added the charge is
    -- refunded, because taking the money and giving nothing is the worse bug.
    local price = entry.price or 0
    if price > 0 and not Bridge.RemoveMoney(source, 'bank', price, 'federal-armory') then
        return fail('you cannot afford that')
    end

    -- Weapons carry the metadata qb-style inventories expect (a serial and
    -- full quality); without it some inventories render the weapon broken or
    -- drop it entirely, which reads as "the gun was never added".
    local metadata = nil
    if entry.item:find('^weapon_') then
        metadata = { serie = weaponSerial(), quality = 100 }
    end

    -- The tablet is issued LOGGED IN: it carries its drawer's session, and
    -- whoever ends up holding it - including whoever stole it - opens the
    -- CAD on that identity.
    if entry.item == ((Config.Federal or {}).tabletItem or 'fed_tablet') then
        metadata = {
            agency = membership.agency.id,
            owner = membership.name,
            identifier = membership.identifier,
            callsign = Core.CallsignFor(membership),
            description = ('Signed in: %s (%s)'):format(membership.name, membership.agency.short)
        }
    end

    if not Bridge.AddItem(source, entry.item, entry.count or 1, metadata) then
        if price > 0 then Bridge.AddMoney(source, 'bank', price, 'federal-armory-refund') end
        return fail('your inventory would not take that item')
    end

    -- A gun without rounds is a paperweight: issue magazines with it.
    local ammoItem = ammoFor(entry.item)
    if ammoItem then
        local magazines = math.floor(Util.Clamp(tonumber((settings().armoryAmmo or {}).count) or 2, 1, 10))
        if Bridge.AddItem(source, ammoItem, magazines) then
            entry = Util.Copy(entry)
            entry.issuedAmmo = ('%dx %s'):format(magazines, ammoItem)
        end
    end

    -- Onto the unit's checkout log, which the CAD roster reads.
    Armory.LogDraw(membership.identifier, entry)

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
    untombstoneArmory(agency, entry.id)

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
    tombstoneArmory(agency, entryId)
    local saved, saveMessage = Federal.Uniforms.PersistAgency(agency)
    if not saved then return fail(saveMessage) end
    return entry
end

-- Motor pool stock -----------------------------------------------------------
--
-- Vehicles live in the resource's own store, per agency, so they are editable
-- in game (/fedaddcar and friends). Config.Federal.vehicles stays the fallback
-- for an agency nobody has edited; the first in-game edit copies the config
-- list into the store and everything after that edits the stored list.

local vehicleStore = DAG.Repository.Create('federal_vehicles')

-- Captured vehicle properties come from a client, so only plain data survives:
-- numbers, strings, booleans, and shallow tables of the same, with a hard cap
-- so nobody ships a megabyte of "props" into the store.
local function plainCopy(value, depth)
    local kind = type(value)
    if kind == 'number' or kind == 'string' or kind == 'boolean' then return value end
    if kind ~= 'table' or (depth or 0) >= 3 then return nil end

    local copy, count = {}, 0
    for key, inner in pairs(value) do
        local keyKind = type(key)
        if keyKind == 'string' or keyKind == 'number' then
            local cleaned = plainCopy(inner, (depth or 0) + 1)
            if cleaned ~= nil then
                copy[key] = cleaned
                count = count + 1
                if count >= 250 then break end
            end
        end
    end
    return copy
end

-- The agency's motor pool: the stored list when one exists, the config list
-- otherwise. The second return names which one you got.
function Armory.Vehicles(agencyId)
    local record = vehicleStore.get(agencyId)
    if record and type(record.vehicles) == 'table' then
        return Util.Copy(record.vehicles), 'stored'
    end

    local catalog = settings().vehicles or {}
    local list = {}
    for index, entry in ipairs(catalog[agencyId] or catalog.default or {}) do
        if type(entry) == 'table' and type(entry.model) == 'string' then
            list[#list + 1] = {
                id = Util.Slug(entry.label or entry.model, ('vehicle-%d'):format(index)),
                model = entry.model,
                label = entry.label or entry.model
            }
        end
    end
    return list, 'config'
end

local function persistVehicles(agencyId, list)
    local saved, message = vehicleStore.save(agencyId, { id = agencyId, vehicles = list })
    if not saved then return fail(message or 'the motor pool could not be saved') end
    Core.Sync()
    return true
end

-- Admin/editor action: add (or replace) a vehicle, optionally with the mod
-- and livery properties captured from a real vehicle in game.
function Armory.AddVehicle(source, agencyId, payload)
    local agency, message = Federal.Editor.EditableFor(source, agencyId, 'armory.manage')
    if not agency then return fail(message) end

    payload = type(payload) == 'table' and payload or {}
    local model = Util.Text(payload.model, 40)
    if not model then return fail('no vehicle model') end
    local label = Util.Text(payload.label, 60, model)

    local list = Armory.Vehicles(agency.id)
    local entry = {
        id = Util.Slug(payload.id or label, ('vehicle-%d'):format(#list + 1)),
        model = model:lower(),
        label = label,
        minGrade = math.floor(Util.Clamp(tonumber(payload.minGrade) or 0, 0, 100)),
        division = Util.IsSlug(payload.division) and payload.division or nil,
        props = plainCopy(payload.props)
    }

    local replaced = false
    for index, existing in ipairs(list) do
        if existing.id == entry.id then
            list[index] = entry
            replaced = true
        end
    end
    if not replaced then list[#list + 1] = entry end

    local ok, saveMessage = persistVehicles(agency.id, list)
    if not ok then return fail(saveMessage) end
    return entry
end

-- Sets the minimum grade on one motor pool vehicle: the rank-loadout menu's
-- write path. Seeds the config list into the store on first use, like every
-- other vehicle edit.
function Armory.SetVehicleGrade(source, agencyId, vehicleId, minGrade)
    local agency, message = Federal.Editor.EditableFor(source, agencyId, 'armory.manage')
    if not agency then return fail(message) end

    local list = Armory.Vehicles(agency.id)
    for index, entry in ipairs(list) do
        if entry.id == vehicleId then
            list[index].minGrade = math.floor(Util.Clamp(tonumber(minGrade) or 0, 0, 100))
            local ok, saveMessage = persistVehicles(agency.id, list)
            if not ok then return fail(saveMessage) end
            return list[index]
        end
    end
    return fail('no such vehicle in that motor pool')
end

function Armory.RemoveVehicle(source, agencyId, vehicleId)
    local agency, message = Federal.Editor.EditableFor(source, agencyId, 'armory.manage')
    if not agency then return fail(message) end
    if type(vehicleId) ~= 'string' or vehicleId == '' then return fail('which vehicle? give its id or model') end

    local list = Armory.Vehicles(agency.id)
    for index, entry in ipairs(list) do
        if entry.id == vehicleId or entry.model == vehicleId:lower() then
            table.remove(list, index)
            local ok, saveMessage = persistVehicles(agency.id, list)
            if not ok then return fail(saveMessage) end
            return entry
        end
    end
    return fail('no such vehicle in that motor pool')
end

-- Admin/editor variants of the armory stock operations. The boss-menu path
-- requires standing in the command office; these are for the config commands
-- and require federal.admin or editor.manage instead.
function Armory.AdminSave(source, agencyId, payload)
    local agency, message = Federal.Editor.EditableFor(source, agencyId, 'armory.manage')
    if not agency then return fail(message) end

    local entry, entryMessage = Schema.ArmoryItem(payload)
    if not entry then return fail(entryMessage) end

    agency.armory = agency.armory or {}
    local _, index = Schema.FindById(agency.armory, entry.id)
    if index then
        agency.armory[index] = entry
    else
        agency.armory[#agency.armory + 1] = entry
    end
    untombstoneArmory(agency, entry.id)

    local saved, saveMessage = Federal.Uniforms.PersistAgency(agency)
    if not saved then return fail(saveMessage) end
    return entry
end

function Armory.AdminDelete(source, agencyId, entryId)
    local agency, message = Federal.Editor.EditableFor(source, agencyId, 'armory.manage')
    if not agency then return fail(message) end

    local entry, index = Schema.FindById(agency.armory or {}, entryId)
    if not index then return fail('that item is not stocked') end

    table.remove(agency.armory, index)
    tombstoneArmory(agency, entryId)
    local saved, saveMessage = Federal.Uniforms.PersistAgency(agency)
    if not saved then return fail(saveMessage) end
    return entry
end

-- Checkout ledger ------------------------------------------------------------
--
-- What each member currently has out: the motor pool vehicle, their armory
-- draws, the uniform they changed into. Held in memory on purpose - spawned
-- vehicles do not survive a restart, so neither should the ledger that
-- describes them. The CAD's Units tab reads this.

local checkouts = {}
Armory.checkouts = checkouts

-- The item list aggregates by item and caps its length, so a unit that draws
-- ammo forty times does not turn their roster card into a scroll.
local MAX_CHECKOUT_ITEMS = 15

local function checkoutFor(identifier)
    checkouts[identifier] = checkouts[identifier] or { items = {} }
    return checkouts[identifier]
end

function Armory.CheckoutFor(identifier)
    return checkouts[identifier] and Util.Copy(checkouts[identifier]) or nil
end

function Armory.LogDraw(identifier, entry)
    local kit = checkoutFor(identifier)
    for _, line in ipairs(kit.items) do
        if line.item == entry.item then
            line.count = (line.count or 1) + (entry.count or 1)
            line.at = os.time()
            return
        end
    end
    if #kit.items >= MAX_CHECKOUT_ITEMS then table.remove(kit.items, 1) end
    kit.items[#kit.items + 1] = {
        item = entry.item, label = entry.label, count = entry.count or 1, at = os.time()
    }
end

function Armory.LogUniform(identifier, label)
    checkoutFor(identifier).uniform = { label = label, at = os.time() }
end

function Armory.ClearCheckout(identifier)
    checkouts[identifier] = nil
end

-- A member leaving takes their session's kit off the board; their spawned
-- vehicle is despawning with them anyway.
AddEventHandler('playerDropped', function()
    local droppedSource = source
    local ok, identifier = pcall(Bridge.GetIdentifier, droppedSource)
    if ok and identifier then Armory.ClearCheckout(identifier) end
end)

-- Qbox hands out vehicle keys server-side; the client asks for them right
-- after its motor pool spawn. Only honoured for members with armory access,
-- and only when qbx_vehiclekeys is actually running.
RegisterNetEvent(Federal.Net('garage:keys'), function(plate)
    local playerSource = source
    if type(plate) ~= 'string' or #plate == 0 or #plate > 8 then return end
    if GetResourceState('qbx_vehiclekeys') ~= 'started' then return end
    if not Core.Require(playerSource, 'armory.use') then return end
    pcall(function() exports.qbx_vehiclekeys:GiveKeys(playerSource, plate) end)
end)

RegisterNetEvent(Federal.Net('garage:return'), function()
    local playerSource = source
    local identifier = Bridge.GetIdentifier(playerSource)
    if identifier and checkouts[identifier] then checkouts[identifier].vehicle = nil end
    Bridge.Notify(playerSource, 'Vehicle returned to the motor pool.', 'success')
end)

-- Clearing a unit's checkout log: your own freely, another unit's with
-- roster.manage.
RegisterNetEvent(Federal.Net('checkout:clear'), function(targetSource)
    local playerSource = source
    targetSource = tonumber(targetSource) or playerSource
    if targetSource ~= playerSource
        and not (Core.Can(playerSource, 'roster.manage') or Core.IsAdmin(playerSource)) then
        return Bridge.Notify(playerSource, 'Clearing a checkout log is a roster action.', 'error')
    end

    local identifier = Bridge.GetIdentifier(targetSource)
    if identifier then Armory.ClearCheckout(identifier) end
    Bridge.Notify(playerSource, 'Checkout log cleared.', 'success')
end)

-- Vehicles are spawned by the client; the server's job is to confirm the
-- player is entitled to one and is standing in a motor pool. One vehicle out
-- per unit: drawing another returns the current one first.
function Armory.RequestVehicle(source, vehicleId)
    local membership = Core.Require(source, 'armory.use')
    if not membership then return fail('not authorized') end

    local allowed = Core.RequireZone(source, membership, 'garage')
    if not allowed then return fail('not at a motor pool') end

    if type(vehicleId) ~= 'string' then return fail('no vehicle given') end

    local entry
    for _, vehicle in ipairs(Armory.Vehicles(membership.agency.id)) do
        if vehicle.id == vehicleId or vehicle.model == vehicleId then
            entry = vehicle
            break
        end
    end
    if not entry then return fail('that vehicle is not in the motor pool') end

    local ok, reason = drawable(source, membership, entry)
    if not ok then return fail(reason) end

    local price = tonumber(settings().vehiclePrice) or 0
    if price > 0 and not Bridge.RemoveMoney(source, 'bank', price, 'federal-motorpool') then
        return fail('you cannot afford that')
    end

    -- The unit's callsign is the plate: 1F-36 rides on plate 1F36. That makes
    -- the car on the street answerable to the roster at a glance.
    local plate = tostring(Core.CallsignFor(membership) or ''):upper():gsub('[^%w]', ''):sub(1, 8)
    if plate == '' then plate = ('FED%03d'):format(math.random(0, 999)) end

    checkoutFor(membership.identifier).vehicle = {
        model = entry.model,
        label = entry.label or entry.model,
        plate = plate,
        at = os.time()
    }

    -- The in-car terminal signs in as the drawer and STAYS signed in: the
    -- vehicle's statebag carries the session for whoever ends up inside.
    TriggerClientEvent(Federal.Net('spawnVehicle'), source, entry.model, entry.props, plate, {
        agency = membership.agency.id,
        name = membership.name,
        identifier = membership.identifier,
        callsign = Core.CallsignFor(membership)
    })
    return entry
end

RegisterNetEvent(Federal.Net('armory:draw'), function(entryId)
    local playerSource = source
    if type(entryId) ~= 'string' then return end

    local entry, message = Armory.Draw(playerSource, entryId)
    Bridge.Notify(playerSource,
        entry and ('Drew %s%s.'):format(entry.label, entry.issuedAmmo and (' with ' .. entry.issuedAmmo) or '') or message,
        entry and 'success' or 'error')
end)

-- The ballistic vest: using the item puts it on. Registered for both
-- spellings so the shipped 'armour' item and a stock 'armor' item work.
local lastVest = {}

for _, itemName in ipairs({ 'armour', 'armor' }) do
    Bridge.CreateUseableItem(itemName, function(source)
        if Bridge.RemoveItem(source, itemName, 1) then
            lastVest[source] = itemName
            TriggerClientEvent(Federal.Net('useArmour'), source)
        end
    end)
end

-- Cancelling the strap-on animation gives the vest back.
RegisterNetEvent(Federal.Net('armour:refund'), function()
    local playerSource = source
    local itemName = lastVest[playerSource]
    if itemName then
        lastVest[playerSource] = nil
        Bridge.AddItem(playerSource, itemName, 1)
    end
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

RegisterNetEvent(Federal.Net('armory:vehicle'), function(vehicleId)
    local playerSource = source
    if type(vehicleId) ~= 'string' then return end
    local result, message = Armory.RequestVehicle(playerSource, vehicleId)
    if not result then Bridge.Notify(playerSource, message, 'error') end
end)

-- The capture round trip for /fedaddcar: the command asks this client to read
-- the vehicle it is sitting in, and the client posts the capture back here.
-- Authorization happens in AddVehicle, never in the client.
RegisterNetEvent(Federal.Net('garage:add'), function(agencyId, payload)
    local playerSource = source
    if type(agencyId) ~= 'string' then return end
    local entry, message = Armory.AddVehicle(playerSource, agencyId, payload)
    Bridge.Notify(playerSource,
        entry and ('Added %s (%s) to the %s motor pool.'):format(entry.label, entry.model, agencyId:upper()) or message,
        entry and 'success' or 'error')
end)

-- Rank-loadout and studio write paths. Same operations the commands use;
-- authorization happens inside each function, never here.
RegisterNetEvent(Federal.Net('armory:adminSave'), function(agencyId, payload)
    local playerSource = source
    if type(agencyId) ~= 'string' then return end
    local entry, message = Armory.AdminSave(playerSource, agencyId, payload)
    Bridge.Notify(playerSource,
        entry and ('Stocked %s in the %s armory.'):format(entry.label, agencyId:upper()) or message,
        entry and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('armory:adminDelete'), function(agencyId, entryId)
    local playerSource = source
    if type(agencyId) ~= 'string' or type(entryId) ~= 'string' then return end
    local entry, message = Armory.AdminDelete(playerSource, agencyId, entryId)
    Bridge.Notify(playerSource, entry and ('Removed %s.'):format(entry.label) or message, entry and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('garage:setGrade'), function(agencyId, vehicleId, minGrade)
    local playerSource = source
    if type(agencyId) ~= 'string' or type(vehicleId) ~= 'string' then return end
    local entry, message = Armory.SetVehicleGrade(playerSource, agencyId, vehicleId, minGrade)
    Bridge.Notify(playerSource,
        entry and ('%s now requires grade %d+.'):format(entry.label, entry.minGrade or 0) or message,
        entry and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('garage:remove'), function(agencyId, vehicleId)
    local playerSource = source
    if type(agencyId) ~= 'string' or type(vehicleId) ~= 'string' then return end
    local entry, message = Armory.RemoveVehicle(playerSource, agencyId, vehicleId)
    Bridge.Notify(playerSource, entry and ('Removed %s.'):format(entry.label) or message, entry and 'success' or 'error')
end)

-- Item catalog for the searchable pickers. Read once from whichever inventory
-- system is running and cached; a framework with no readable catalog returns
-- an empty list and the picker degrades to free text.
local itemCatalog = nil

function Armory.ItemCatalog()
    if itemCatalog then return itemCatalog end

    local list = {}
    local function harvest(items)
        if type(items) ~= 'table' then return end
        for name, item in pairs(items) do
            local key = type(name) == 'string' and name or (type(item) == 'table' and item.name)
            if type(key) == 'string' and key ~= '' then
                local label = type(item) == 'table' and (item.label or item.name) or key
                list[#list + 1] = { value = key, label = tostring(label) }
            end
        end
    end

    if GetResourceState('qb-core') == 'started' then
        local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
        if ok and core and core.Shared then harvest(core.Shared.Items) end
    elseif GetResourceState('qbx_core') == 'started' or GetResourceState('ox_inventory') == 'started' then
        local ok, items = pcall(function() return exports.ox_inventory:Items() end)
        if ok then harvest(items) end
    elseif GetResourceState('es_extended') == 'started' then
        local ok, shared = pcall(function() return exports.es_extended:getSharedObject() end)
        if ok and shared and shared.Items then harvest(shared.Items) end
    end

    table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
    itemCatalog = list
    return itemCatalog
end

Bridge.RegisterCallback(Federal.Net('itemCatalog'), function(source, reply)
    reply(Armory.ItemCatalog())
end)

-- What a borrowed terminal shows about the agency it belongs to, so the
-- stolen screen still wears the right letterhead.
local function sessionBrand(agencyId)
    local agency = Core.Agency(agencyId)
    if not agency then return nil end
    return {
        label = agency.label,
        short = agency.short,
        color = agency.color,
        logo = agency.cad and agency.cad.logo or nil
    }
end

-- The MDT tablet: using the item opens the terminal anywhere. A credentialed
-- member gets their own session; anyone ELSE holding it gets the session it
-- was issued with - the tablet never logged out, and neither did the car.
local tabletItem = (Config.Federal or {}).tabletItem or 'fed_tablet'
Bridge.CreateUseableItem(tabletItem, function(source, item)
    local membership = Core.Membership(source)
    if membership and not membership.borrowed and Core.Can(source, 'cad.view')
        and (membership.onDuty or Core.IsAdmin(source)) then
        return TriggerClientEvent(Federal.Net('openMdt'), source)
    end

    -- Not credentialed: the tablet is still signed in as whoever drew it.
    local info = type(item) == 'table' and (item.info or item.metadata) or nil
    if type(info) ~= 'table' or type(info.agency) ~= 'string' then
        return Bridge.Notify(source, 'The tablet has no active session.', 'error')
    end
    Core.BorrowSession(source, {
        agency = info.agency, name = info.owner,
        identifier = info.identifier, callsign = info.callsign
    })
    TriggerClientEvent(Federal.Net('openMdt'), source, {
        owner = info.owner or 'Unknown operator',
        brand = sessionBrand(info.agency)
    })
end)

-- The in-car terminal of a stolen agency vehicle: anyone in the seat may use
-- it, on the session of the unit who drew the car. The server verifies they
-- really are sitting in a flagged vehicle before handing the session over.
RegisterNetEvent(Federal.Net('terminal:borrow'), function(netId)
    local playerSource = source
    local entity = NetworkGetEntityFromNetworkId(tonumber(netId) or 0)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return end

    local terminal = Entity(entity).state and Entity(entity).state.fedTerminal
    if type(terminal) ~= 'table' or type(terminal.agency) ~= 'string' then
        return Bridge.Notify(playerSource, 'This vehicle has no terminal.', 'error')
    end

    local ped = GetPlayerPed(playerSource)
    if GetVehiclePedIsIn(ped, false) ~= entity then
        return Bridge.Notify(playerSource, 'Get in the vehicle first.', 'error')
    end

    Core.BorrowSession(playerSource, {
        agency = terminal.agency, name = terminal.name,
        identifier = terminal.identifier, callsign = terminal.callsign
    })
    TriggerClientEvent(Federal.Net('openMdt'), playerSource, {
        owner = terminal.name or 'Unknown operator',
        brand = sessionBrand(terminal.agency)
    })
end)

-- The holster stance only engages over a sidearm the member actually holds.
function Armory.HolsterCheck(source)
    local membership = Core.Membership(source)
    if not membership then return false end
    for _, item in ipairs((settings().holster or {}).weapons or {}) do
        if Bridge.HasItem(source, item, 1) then return true end
    end
    return false
end

Bridge.RegisterCallback(Federal.Net('holster:check'), function(source, reply)
    reply(Armory.HolsterCheck(source))
end)

Bridge.RegisterCallback(Federal.Net('armory'), function(source, reply)
    reply(Armory.List(source))
end)

-- The garage list, annotated with what this player's grade may actually draw
-- so the client can grey out the rest.
Bridge.RegisterCallback(Federal.Net('garage'), function(source, reply)
    local membership = Core.Membership(source)
    if not membership then return reply({}) end

    local list = Armory.Vehicles(membership.agency.id)
    for _, entry in ipairs(list) do
        local ok, reason = drawable(source, membership, entry)
        if not ok then
            entry.locked = true
            entry.lockedReason = reason
        end
    end
    reply(list)
end)

return Armory
