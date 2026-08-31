-- Locker room, armory and motor pool menus.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local State = Federal.State
local Armory = {}
Federal.Armory = Armory

local function id(name)
    return Federal.Menus.Id('armory:' .. name)
end

-- Locker room ------------------------------------------------------------------
--
-- Rendered as a wardrobe of cards, not a list: each uniform is a card with
-- its fit, grade and division restrictions, plus a civilian-clothes card.

local function wearUniform(uniform)
    DAG.Menu.GridClose()
    local timings = (Config.Federal or {}).timings or {}
    if not Federal.Progress.Run({
        label = ('Changing into %s'):format(uniform.label),
        duration = timings.changeUniform or 4000,
        animation = 'change'
    }) then return end
    TriggerServerEvent(Federal.Net('uniform:wear'), uniform.id)
end

function Armory.Locker()
    local agency = State.Mine()
    if not agency then return end

    local grade = State.Grade()
    local membership = State.Membership()

    -- Uniforms this member cannot wear do not hang in their locker at all.
    local byId = {}
    local items = {}
    for _, uniform in ipairs(agency.uniforms or {}) do
        if Federal.Uniforms.Wearable(uniform, grade, membership and membership.divisionId) then
            byId[uniform.id] = uniform
            items[#items + 1] = {
                id = uniform.id,
                label = uniform.label,
                icon = '👕',
                sub = uniform.variant ~= 'any' and ('Fits %s'):format(uniform.variant)
                    or ((uniform.minGrade or 0) > 0 and ('Grade %d+'):format(uniform.minGrade) or 'Standard issue'),
                badge = 'Issued',
                badgeTone = 'success'
            }
        end
    end

    if #items == 0 then
        items[1] = { id = 'none', label = 'Nothing issued to you yet', sub = 'A boss adds uniforms from the studio', icon = '🧺', locked = true }
    end

    DAG.Menu.Grid({
        title = 'Locker room',
        subtitle = agency.label,
        hint = 'Pick a uniform to change into it',
        sections = {
            { label = 'Uniforms', items = items },
            { label = 'Civilian', items = { {
                id = 'civilian',
                label = 'Civilian clothes',
                icon = '🧥',
                sub = 'Back to your saved appearance'
            } } }
        }
    }, function(selected)
        if selected == 'civilian' then
            DAG.Menu.GridClose()
            -- Handled in uniforms.lua: skin resource first, session snapshot
            -- as the fallback. The handler does its own notifying.
            TriggerEvent(Federal.Net('restoreAppearance'))
            return
        end
        local uniform = byId[selected]
        if uniform then wearUniform(uniform) end
    end)
end

-- Armory ---------------------------------------------------------------------------

-- The armory renders as shelves of cards grouped by category, each with an
-- icon, its grade/price, and the reason a locked shelf is locked.
local CATEGORY_ICONS = {
    ['Comms'] = '📻', ['Restraints'] = '🔗', ['Protection'] = '🦺',
    ['Sidearm'] = '🔫', ['Long gun'] = '🔫', ['Less lethal'] = '⚡',
    ['Investigation'] = '🔍', ['Entry'] = '💥', ['Surveillance'] = '📡',
    ['General'] = '📦'
}

local function drawEntry(entry)
    DAG.Menu.GridClose()
    local timings = (Config.Federal or {}).timings or {}
    if not Federal.Progress.Run({
        label = ('Drawing %s'):format(entry.label),
        duration = timings.armory or 2000,
        animation = 'equip'
    }) then return end
    TriggerServerEvent(Federal.Net('armory:draw'), entry.id)
end

function Armory.Open()
    Bridge.TriggerCallback(Federal.Net('armory'), function(list)
        local byId = {}

        -- One continuous wall of shelves. A section per category looked fine
        -- on paper and rendered as a single sad column the moment every
        -- category held one item - so the category rides ON the card as a
        -- tag, and like items simply sort together.
        local drawableList = {}
        for _, entry in ipairs(list or {}) do
            -- Shelves above this member's grade or outside their division do
            -- not exist as far as their armory is concerned.
            if not entry.locked then drawableList[#drawableList + 1] = entry end
        end
        table.sort(drawableList, function(a, b)
            local categoryA, categoryB = a.category or 'General', b.category or 'General'
            if categoryA == categoryB then return (a.label or '') < (b.label or '') end
            return categoryA < categoryB
        end)

        local items = {}
        for _, entry in ipairs(drawableList) do
            byId[entry.id] = entry
            local category = entry.category or 'General'
            items[#items + 1] = {
                id = entry.id,
                label = entry.label,
                icon = CATEGORY_ICONS[category] or '📦',
                -- The inventory's own picture of the item, so the shelves
                -- look like the inventory the gear lands in.
                image = entry.item,
                tag = category,
                sub = (entry.count or 1) > 1 and ('%s x%d'):format(entry.item, entry.count) or entry.item,
                badge = (entry.price or 0) > 0 and ('$%d'):format(entry.price) or 'Issued',
                badgeTone = (entry.price or 0) > 0 and 'accent' or 'success'
            }
        end

        local sections = { { items = items } }
        if #items == 0 then
            sections[1] = { items = { {
                id = 'none', label = 'Nothing issued to your rank', sub = 'A boss stocks the armory from /fedconfig', icon = '🧰', locked = true
            } } }
        end

        local agency = State.Mine()
        DAG.Menu.Grid({
            title = 'Armory',
            subtitle = agency and agency.label or nil,
            hint = 'Pick equipment to draw it',
            imageBase = (Config.Federal or {}).itemImages,
            sections = sections
        }, function(selected)
            local entry = byId[selected]
            if entry and not entry.locked then drawEntry(entry) end
        end)
    end)
end

-- Using a ballistic vest item straps it on: a short animation, then full
-- armour. The item was already consumed server-side.
RegisterNetEvent(Federal.Net('useArmour'), function()
    if not Federal.Progress.Run({
        label = 'Strapping on the vest',
        duration = 3000,
        animation = 'equip'
    }) then
        -- Cancelled mid-strap: the vest is not wasted.
        TriggerServerEvent(Federal.Net('armour:refund'))
        return
    end
    SetPedArmour(PlayerPedId(), 100)
    Bridge.Notify('Vest on.', 'success')
end)

-- Motor pool -------------------------------------------------------------------------

-- Reads the mods, colours, liveries and extras off a real vehicle so
-- /fedaddcar can store the car exactly as it stands.
function Armory.CaptureVehicleProps(vehicle)
    local props = { mods = {}, extras = {} }

    local primary, secondary = GetVehicleColours(vehicle)
    local pearlescent, wheelColor = GetVehicleExtraColours(vehicle)
    props.colors = { primary = primary, secondary = secondary, pearlescent = pearlescent, wheel = wheelColor }

    if GetIsVehiclePrimaryColourCustom(vehicle) then
        local r, g, b = GetVehicleCustomPrimaryColour(vehicle)
        props.customPrimary = { r, g, b }
    end
    if GetIsVehicleSecondaryColourCustom(vehicle) then
        local r, g, b = GetVehicleCustomSecondaryColour(vehicle)
        props.customSecondary = { r, g, b }
    end

    -- Interior and dashboard trim colours: visible on plenty of models and
    -- silently lost if not captured.
    local interiorOk, interiorColor = pcall(GetVehicleInteriorColour, vehicle)
    if interiorOk then props.interiorColor = interiorColor end
    local dashOk, dashColor = pcall(GetVehicleDashboardColour, vehicle)
    if dashOk then props.dashboardColor = dashColor end

    props.wheelType = GetVehicleWheelType(vehicle)
    props.windowTint = GetVehicleWindowTint(vehicle)
    props.livery = GetVehicleLivery(vehicle)
    props.roofLivery = GetVehicleRoofLivery(vehicle)
    props.plateIndex = GetVehicleNumberPlateTextIndex(vehicle)
    props.plate = GetVehicleNumberPlateText(vehicle)

    for modType = 0, 49 do
        local index = GetVehicleMod(vehicle, modType)
        if index >= 0 then
            props.mods[#props.mods + 1] = {
                type = modType,
                index = index,
                -- Custom tyres are part of the wheel mod, not a separate slot.
                variation = GetVehicleModVariation(vehicle, modType) == 1 or nil
            }
        end
    end
    props.turbo = IsToggleModOn(vehicle, 18)
    props.tyreSmoke = IsToggleModOn(vehicle, 20)
    props.xenon = IsToggleModOn(vehicle, 22)

    if props.tyreSmoke then
        local r, g, b = GetVehicleTyreSmokeColor(vehicle)
        props.tyreSmokeColor = { r, g, b }
    end
    if props.xenon then
        local xenonOk, xenonColor = pcall(GetVehicleXenonLightsColor, vehicle)
        if xenonOk and xenonColor ~= 255 then props.xenonColor = xenonColor end
    end

    local neonOn = false
    for index = 0, 3 do
        if IsVehicleNeonLightEnabled(vehicle, index) then neonOn = true break end
    end
    if neonOn then
        local r, g, b = GetVehicleNeonLightsColour(vehicle)
        props.neon = { r, g, b }
    end

    -- Addon emergency vehicles run extras well past the vanilla 14.
    for extra = 0, 25 do
        if DoesExtraExist(vehicle, extra) then
            props.extras[#props.extras + 1] = { id = extra, on = IsVehicleExtraTurnedOn(vehicle, extra) }
        end
    end

    return props
end

-- Extras applied deliberately: auto-repair off first (toggling an extra
-- repairs the vehicle, which can reset other state), explicit 0/1 ints
-- because some builds refuse booleans on this native.
local function applyVehicleExtras(vehicle, extras)
    if type(extras) ~= 'table' then return end
    SetVehicleAutoRepairDisabled(vehicle, true)
    for _, extra in ipairs(extras) do
        if type(extra) == 'table' and extra.id ~= nil and DoesExtraExist(vehicle, extra.id) then
            SetVehicleExtra(vehicle, extra.id, extra.on and 0 or 1)
        end
    end
    SetVehicleAutoRepairDisabled(vehicle, false)
end

local function applyVehicleProps(vehicle, props)
    if type(props) ~= 'table' then return end
    SetVehicleModKit(vehicle, 0)

    local colors = props.colors or {}
    if colors.primary then SetVehicleColours(vehicle, colors.primary, colors.secondary or colors.primary) end
    if colors.pearlescent then SetVehicleExtraColours(vehicle, colors.pearlescent, colors.wheel or 0) end
    if type(props.customPrimary) == 'table' then
        SetVehicleCustomPrimaryColour(vehicle, props.customPrimary[1] or 0, props.customPrimary[2] or 0, props.customPrimary[3] or 0)
    end
    if type(props.customSecondary) == 'table' then
        SetVehicleCustomSecondaryColour(vehicle, props.customSecondary[1] or 0, props.customSecondary[2] or 0, props.customSecondary[3] or 0)
    end

    if props.interiorColor then pcall(SetVehicleInteriorColour, vehicle, props.interiorColor) end
    if props.dashboardColor then pcall(SetVehicleDashboardColour, vehicle, props.dashboardColor) end

    if props.wheelType then SetVehicleWheelType(vehicle, props.wheelType) end
    for _, mod in ipairs(props.mods or {}) do
        if type(mod) == 'table' and (mod.index or -1) >= 0 then
            SetVehicleMod(vehicle, mod.type or 0, mod.index, mod.variation == true)
        end
    end
    ToggleVehicleMod(vehicle, 18, props.turbo == true)
    ToggleVehicleMod(vehicle, 20, props.tyreSmoke == true)
    ToggleVehicleMod(vehicle, 22, props.xenon == true)

    if type(props.tyreSmokeColor) == 'table' then
        SetVehicleTyreSmokeColor(vehicle,
            props.tyreSmokeColor[1] or 255, props.tyreSmokeColor[2] or 255, props.tyreSmokeColor[3] or 255)
    end
    if props.xenonColor then pcall(SetVehicleXenonLightsColor, vehicle, props.xenonColor) end

    if type(props.neon) == 'table' then
        for index = 0, 3 do SetVehicleNeonLightEnabled(vehicle, index, true) end
        SetVehicleNeonLightsColour(vehicle, props.neon[1] or 255, props.neon[2] or 255, props.neon[3] or 255)
    end

    if (props.windowTint or -1) >= 0 then SetVehicleWindowTint(vehicle, props.windowTint) end
    if (props.livery or -1) >= 0 then SetVehicleLivery(vehicle, props.livery) end
    if (props.roofLivery or -1) >= 0 then SetVehicleRoofLivery(vehicle, props.roofLivery) end
    if props.plateIndex then SetVehicleNumberPlateTextIndex(vehicle, props.plateIndex) end

    applyVehicleExtras(vehicle, props.extras)

    -- Emergency vehicles re-randomize their extras a few frames after
    -- spawning, stomping anything set on the spawn frame. A second pass
    -- shortly after wins that argument.
    if type(props.extras) == 'table' and #props.extras > 0 then
        local extras = props.extras
        CreateThread(function()
            Wait(350)
            if DoesEntityExist(vehicle) then applyVehicleExtras(vehicle, extras) end
        end)
    end
end

-- The studio re-dresses existing motor pool vehicles with this too.
Armory.ApplyVehicleProps = applyVehicleProps

-- Vehicle keys across frameworks. Every supported key system that is
-- actually running gets told about the new vehicle, so the same resource
-- hands out keys on QBCore, Qbox, ESX or standalone servers without any
-- configuration. Servers running something exotic wire it up through
-- Config.Federal.vehicleKeys instead of editing this file.
function Armory.GiveVehicleKeys(vehicle, model)
    local plate = (GetVehicleNumberPlateText(vehicle) or ''):gsub('^%s+', ''):gsub('%s+$', '')

    -- qb-vehiclekeys and every fork that kept its event. Fired blind: a
    -- TriggerEvent with no listener is a no-op, never an error.
    TriggerEvent('vehiclekeys:client:SetOwner', plate)

    -- Qbox: keys are granted server-side, so the server relays them.
    if GetResourceState('qbx_vehiclekeys') == 'started' then
        TriggerServerEvent(Federal.Net('garage:keys'), plate)
    end

    -- Popular standalone/ESX lock scripts, each only when present.
    if GetResourceState('qs-vehiclekeys') == 'started' then
        pcall(function() exports['qs-vehiclekeys']:GiveKeys(plate, model) end)
    end
    if GetResourceState('wasabi_carlock') == 'started' then
        pcall(function() exports.wasabi_carlock:GiveKey(plate) end)
    end
    if GetResourceState('MrNewbVehicleKeys') == 'started' then
        pcall(function() exports.MrNewbVehicleKeys:GiveKeys(vehicle) end)
    end
    if GetResourceState('mk_vehiclekeys') == 'started' then
        pcall(function() exports.mk_vehiclekeys:AddKey(vehicle) end)
    end

    -- The escape hatch for anything else: a custom event fired with
    -- (plate, vehicle), and/or a custom client export.
    local cfg = (Config.Federal or {}).vehicleKeys or {}
    if type(cfg.clientEvent) == 'string' and cfg.clientEvent ~= '' then
        TriggerEvent(cfg.clientEvent, plate, vehicle)
    end
    if type(cfg.export) == 'table' and cfg.export.resource and cfg.export.method then
        pcall(function()
            local argument = cfg.export.pass == 'vehicle' and vehicle or plate
            exports[cfg.export.resource][cfg.export.method](exports[cfg.export.resource], argument)
        end)
    end
end

-- The one vehicle this client currently has out of the motor pool. Drawing
-- another returns it first, so a unit cannot litter the map with cruisers.
local pooledVehicle = nil

local function returnPooledVehicle(silent)
    if pooledVehicle and DoesEntityExist(pooledVehicle) then
        DeleteEntity(pooledVehicle)
        if not silent then TriggerServerEvent(Federal.Net('garage:return')) end
    end
    pooledVehicle = nil
end

local function spawnVehicle(model, props, plate, terminal)
    local hash = GetHashKey(model)
    RequestModel(hash)

    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(20) end
    if not HasModelLoaded(hash) then
        return Bridge.Notify(('The model %s is not on this server.'):format(model), 'error')
    end

    -- One out at a time: the previous draw goes back before the new one lands.
    if pooledVehicle and DoesEntityExist(pooledVehicle) then
        DeleteEntity(pooledVehicle)
        Bridge.Notify('Your previous vehicle was returned to the pool.', 'inform')
    end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local vehicle = CreateVehicle(hash, coords.x, coords.y, coords.z, GetEntityHeading(ped), true, false)
    SetModelAsNoLongerNeeded(hash)
    SetPedIntoVehicle(ped, vehicle, -1)
    applyVehicleProps(vehicle, props)
    -- The plate is the unit's callsign (server-assigned), so the car on the
    -- street reads straight back to the roster.
    SetVehicleNumberPlateText(vehicle,
        (type(plate) == 'string' and plate ~= '') and plate or ('FED%03d'):format(math.random(0, 999)))
    -- Marks the unit as an agency vehicle: its occupants can open the MDT
    -- from the seat (the in-car terminal), and the flag replicates.
    Entity(vehicle).state:set('fedVehicle', true, true)
    -- The terminal session rides the vehicle: the drawer's identity, still
    -- signed in for whoever sits down - including a thief.
    if type(terminal) == 'table' then
        Entity(vehicle).state:set('fedTerminal', terminal, true)
    end

    -- The keys come with the car: without them the lock script shuts the
    -- officer out the first time they step away from their own cruiser.
    SetVehicleDoorsLocked(vehicle, 1)
    Armory.GiveVehicleKeys(vehicle, model)

    pooledVehicle = vehicle
    Bridge.Notify('Vehicle drawn from the motor pool.', 'success')
end

RegisterNetEvent(Federal.Net('spawnVehicle'), function(model, props, plate, terminal)
    if type(model) == 'string' then spawnVehicle(model, props, plate, terminal) end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then returnPooledVehicle(true) end
end)

-- /fedaddcar round trip: the server command asks this client to read the
-- vehicle it is sitting in; authorization stays on the server.
RegisterNetEvent(Federal.Net('captureVehicle'), function(agencyId, label)
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then
        return Bridge.Notify('Sit in the vehicle you want to add, then run the command again.', 'error')
    end

    local model = GetDisplayNameFromVehicleModel(GetEntityModel(vehicle))
    if not model or model == '' or model == 'CARNOTFOUND' then
        return Bridge.Notify('Could not read this vehicle model.', 'error')
    end

    TriggerServerEvent(Federal.Net('garage:add'), agencyId, {
        model = model:lower(),
        label = label,
        props = Armory.CaptureVehicleProps(vehicle)
    })
end)

function Armory.Garage()
    local agency = State.Mine()
    if not agency then return end

    Bridge.TriggerCallback(Federal.Net('garage'), function(list)
        local options = {}
        -- Vehicles above this member's grade simply do not appear: a locked
        -- row is an advertisement for something they cannot have.
        for _, entry in ipairs(list or {}) do
            if not entry.locked then
                options[#options + 1] = {
                    title = entry.label or entry.model,
                    description = entry.props and ('%s | saved with mods'):format(entry.model) or entry.model,
                    icon = 'car',
                    onSelect = function() TriggerServerEvent(Federal.Net('armory:vehicle'), entry.id) end
                }
            end
        end

        if #options == 0 then
            options[1] = {
                title = 'No vehicles available to your rank',
                description = 'A director stocks the motor pool from /fedconfig',
                disabled = true
            }
        end

        options[#options + 1] = {
            title = 'Return your current vehicle',
            description = 'Puts your drawn vehicle back in the pool',
            icon = 'check',
            onSelect = Armory.ReturnVehicle
        }

        Federal.CAD.Show(id('garage'), 'Motor pool', agency.label, options)
    end)
end

function Armory.ReturnVehicle()
    if not pooledVehicle or not DoesEntityExist(pooledVehicle) then
        return Bridge.Notify('You have no motor pool vehicle out.', 'error')
    end
    returnPooledVehicle(false)
end

return Armory
