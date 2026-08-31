-- The customization studio: live, in-game editing of the things an agency
-- stocks. Spawn a car and dress it before saving it to the motor pool; cycle
-- clothing on your own ped and save the result as a uniform; stock armory
-- items through a searchable catalog instead of remembering spawn codes; tie
-- uniforms, items and vehicles to ranks; and manage sub-departments.
--
-- Everything here is presentation. Every save goes to a server endpoint that
-- re-checks authorization (federal.admin or editor.manage), so nothing in
-- this file is trusted.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local State = Federal.State
local Studio = {}
Federal.Studio = Studio

local function id(name)
    return Federal.Menus.Id('studio:' .. name)
end

local function show(menuId, title, subtitle, options)
    Federal.CAD.Show(menuId, title, subtitle, options)
end

-- Which agency the studio edits: the named one, or the player's own.
local function targetAgency(agencyId)
    if agencyId then
        for _, agency in ipairs(State.Agencies()) do
            if agency.id == agencyId then return agency end
        end
    end
    return State.Mine()
end

-- Division dropdown for the save dialogs: 'Any division' plus each taskforce.
local function divisionOptions(agency)
    local options = { { value = '', label = 'Any division' } }
    for _, division in ipairs(agency and agency.divisions or {}) do
        options[#options + 1] = { value = division.id, label = division.label }
    end
    return options
end

-- Orbit camera ------------------------------------------------------------------
--
-- While a studio is open the camera orbits the thing being edited. The NUI
-- menu holds keyboard focus, so the UI relays numpad 4/6 (rotate), 8/2
-- (raise/lower) and the scroll wheel (zoom) back here as 'studioCam' posts.

local cam = nil
local inputPending = false
local orbit = { heading = 0.0, pitch = -8.0, radius = 3.0, target = nil, menus = nil }

local function updateCam()
    if not cam or not orbit.target or not DoesEntityExist(orbit.target) then return end
    local coords = GetEntityCoords(orbit.target)
    local heading = math.rad(orbit.heading)
    local pitch = math.rad(orbit.pitch)
    local flat = orbit.radius * math.cos(pitch)

    SetCamCoord(cam,
        coords.x + math.sin(heading) * flat,
        coords.y + math.cos(heading) * flat,
        coords.z - orbit.radius * math.sin(pitch) + 0.4)
    PointCamAtCoord(cam, coords.x, coords.y, coords.z + 0.4)
end

local function disableCam()
    if not cam then return end
    RenderScriptCams(false, true, 400, true, true)
    DestroyCam(cam, false)
    cam = nil
    SendNUIMessage({ action = 'camera', enabled = false })
end

local function enableCam(target, radius, menuIds)
    disableCam()
    orbit.target = target
    orbit.radius = radius or 3.0
    orbit.heading = GetEntityHeading(target) + 160.0
    orbit.pitch = -8.0
    orbit.menus = menuIds or {}

    cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    updateCam()
    SetCamActive(cam, true)
    RenderScriptCams(true, true, 400, true, true)
    SendNUIMessage({ action = 'camera', enabled = true })

    -- The camera lives exactly as long as a studio menu (or one of its save
    -- dialogs) is up; closing everything hands the normal camera back.
    CreateThread(function()
        while cam do
            Wait(400)
            local current = DAG.Menu.Current()
            if not inputPending and (not current or not orbit.menus[current]) then
                disableCam()
            end
        end
    end)
end

RegisterNUICallback('studioCam', function(data, reply)
    reply({})
    if not cam or type(data) ~= 'table' then return end

    local op = data.op
    if op == 'left' then orbit.heading = orbit.heading - 12.0
    elseif op == 'right' then orbit.heading = orbit.heading + 12.0
    elseif op == 'up' then orbit.pitch = math.max(orbit.pitch - 6.0, -50.0)
    elseif op == 'down' then orbit.pitch = math.min(orbit.pitch + 6.0, 30.0)
    elseif op == 'zoomin' then orbit.radius = math.max(orbit.radius - 0.6, 1.2)
    elseif op == 'zoomout' then orbit.radius = math.min(orbit.radius + 0.6, 10.0)
    end
    updateCam()
end)

-- Vehicle studio ---------------------------------------------------------------

local preview = nil -- { entity, agencyId, label, minGrade, model }

local function deletePreview()
    disableCam()
    if preview and DoesEntityExist(preview.entity) then
        SetEntityAsMissionEntity(preview.entity, true, true)
        DeleteVehicle(preview.entity)
    end
    preview = nil
end

-- All vehicle models the client knows, including streamed addons. The native
-- is missing on old game builds; the picker degrades to free text there.
local function vehicleCatalog()
    if type(GetAllVehicleModels) ~= 'function' then return {} end
    local ok, models = pcall(GetAllVehicleModels)
    if not ok or type(models) ~= 'table' then return {} end

    local list = {}
    for _, model in ipairs(models) do
        local name = tostring(model):lower()
        local label = GetLabelText(GetDisplayNameFromVehicleModel(GetHashKey(name)))
        if label == 'NULL' or label == '' then label = name end
        list[#list + 1] = { value = name, label = label }
    end
    table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
    return list
end

-- A small named palette of stock GTA paint indexes. Selecting from a list
-- beats typing a paint id, and anything fancier belongs at a mod shop.
local PAINTS = {
    { 0, 'Black' }, { 12, 'Matte black' }, { 1, 'Graphite' }, { 4, 'Silver' },
    { 6, 'Steel grey' }, { 111, 'Frost white' }, { 134, 'Pure white' },
    { 27, 'Torino red' }, { 28, 'Formula red' }, { 39, 'Matte red' },
    { 38, 'Orange' }, { 88, 'Yellow' }, { 49, 'Dark green' }, { 53, 'Race green' },
    { 64, 'Dark blue' }, { 70, 'Bright blue' }, { 73, 'Racing blue' },
    { 62, 'Galaxy blue' }, { 145, 'Purple' }, { 135, 'Hot pink' }, { 90, 'Gold' },
    { 101, 'Bronze' }
}

-- Registers (does not open) a palette submenu; the customize menu links to it.
local function paintMenu(menuId, title, apply)
    local options = {}
    for _, paint in ipairs(PAINTS) do
        options[#options + 1] = {
            title = paint[2],
            icon = 'car',
            keepOpen = true,
            onSelect = function() apply(paint[1]) end
        }
    end
    DAG.Menu.Register({ id = menuId, title = title, subtitle = 'Applied to the preview instantly', options = options })
end

local PERFORMANCE_MODS = { 11, 12, 13, 15, 16 } -- engine, brakes, gearbox, suspension, armour

-- Every cosmetic mod slot the game has, offered whenever the model carries
-- options for it. (Performance slots have their own max/stock buttons.)
local VEHICLE_MOD_SLOTS = {
    { 0, 'Spoiler' }, { 1, 'Front bumper' }, { 2, 'Rear bumper' }, { 3, 'Side skirt' },
    { 4, 'Exhaust' }, { 5, 'Frame' }, { 6, 'Grille' }, { 7, 'Hood' },
    { 8, 'Left fender' }, { 9, 'Right fender' }, { 10, 'Roof' }, { 14, 'Horn' },
    { 23, 'Front wheels' }, { 24, 'Rear wheels' }, { 25, 'Plate holder' },
    { 27, 'Interior trim' }, { 28, 'Ornaments' }, { 30, 'Dials' },
    { 33, 'Steering wheel' }, { 34, 'Shifter' }, { 35, 'Plaques' }, { 48, 'Livery (mod)' }
}

-- The menu ids the orbit camera stays alive for while the studio runs.
local function vehicleMenuSet()
    local set = {
        [id('vehicle')] = true, [id('paint-primary')] = true,
        [id('paint-secondary')] = true, [id('extras')] = true, [id('mods')] = true
    }
    for _, def in ipairs(VEHICLE_MOD_SLOTS) do set[id('mod-' .. def[1])] = true end
    return set
end

-- Cycling one mod slot, stock (-1) included in the loop.
local function cycleVehicleMod(vehicle, slot, label, step)
    local count = GetNumVehicleMods(vehicle, slot)
    if count <= 0 then return end
    local nextIndex = GetVehicleMod(vehicle, slot) + step
    if nextIndex >= count then nextIndex = -1
    elseif nextIndex < -1 then nextIndex = count - 1 end
    if nextIndex < 0 then
        RemoveVehicleMod(vehicle, slot)
    else
        SetVehicleMod(vehicle, slot, nextIndex, false)
    end
    Bridge.Notify(('%s: %s'):format(label, nextIndex < 0 and 'stock' or ('%d / %d'):format(nextIndex + 1, count)),
        'inform', 900)
end

local function customizeMenu()
    if not preview or not DoesEntityExist(preview.entity) then
        return Bridge.Notify('The preview vehicle is gone - start again.', 'error')
    end
    local vehicle = preview.entity

    local liveryCount = GetVehicleLiveryCount(vehicle)
    local modLiveryCount = GetNumVehicleMods(vehicle, 48)

    local options = {
        { title = ('%s (%s)'):format(preview.label, preview.model), disabled = true },
        { title = 'Appearance', header = true }
    }

    if liveryCount > 1 or modLiveryCount > 0 then
        local function cycleLivery(step)
            if liveryCount > 1 then
                SetVehicleLivery(vehicle, (GetVehicleLivery(vehicle) + step) % liveryCount)
            else
                local current = GetVehicleMod(vehicle, 48)
                SetVehicleMod(vehicle, 48, (current + step) % modLiveryCount, false)
            end
        end
        options[#options + 1] = {
            title = 'Next livery',
            icon = 'chevron',
            keepOpen = true,
            onSelect = function() cycleLivery(1) end
        }
        options[#options + 1] = {
            title = 'Previous livery',
            icon = 'chevron',
            keepOpen = true,
            onSelect = function() cycleLivery(-1) end
        }
    end

    options[#options + 1] = { title = 'Primary colour', icon = 'car', menu = id('paint-primary') }
    options[#options + 1] = { title = 'Secondary colour', icon = 'car', menu = id('paint-secondary') }
    options[#options + 1] = {
        title = 'Next window tint',
        icon = 'chevron',
        keepOpen = true,
        onSelect = function()
            SetVehicleWindowTint(vehicle, (GetVehicleWindowTint(vehicle) + 1) % 7)
        end
    }
    options[#options + 1] = {
        title = 'Next wheel design',
        icon = 'chevron',
        keepOpen = true,
        onSelect = function()
            local count = GetNumVehicleMods(vehicle, 23)
            if count > 0 then
                SetVehicleMod(vehicle, 23, (GetVehicleMod(vehicle, 23) + 1) % count, false)
            end
        end
    }
    options[#options + 1] = {
        title = 'Next wheel type',
        description = 'Sport, muscle, offroad, SUV... resets the design',
        icon = 'chevron',
        keepOpen = true,
        onSelect = function()
            SetVehicleWheelType(vehicle, (GetVehicleWheelType(vehicle) + 1) % 13)
            SetVehicleMod(vehicle, 23, 0, false)
        end
    }
    options[#options + 1] = {
        title = 'Next plate style',
        icon = 'chevron',
        keepOpen = true,
        onSelect = function()
            SetVehicleNumberPlateTextIndex(vehicle, (GetVehicleNumberPlateTextIndex(vehicle) + 1) % 6)
        end
    }
    options[#options + 1] = {
        title = 'Toggle neon kit',
        icon = 'chevron',
        keepOpen = true,
        onSelect = function()
            local enabled = not IsVehicleNeonLightEnabled(vehicle, 0)
            for index = 0, 3 do SetVehicleNeonLightEnabled(vehicle, index, enabled) end
            if enabled then SetVehicleNeonLightsColour(vehicle, 80, 160, 255) end
        end
    }

    -- The full catalog: every cosmetic slot this model actually has options
    -- for, each with its own next/previous/stock cycling.
    local modSlots = {}
    for _, def in ipairs(VEHICLE_MOD_SLOTS) do
        if GetNumVehicleMods(vehicle, def[1]) > 0 then modSlots[#modSlots + 1] = def end
    end
    if #modSlots > 0 then
        options[#options + 1] = {
            title = 'All body & interior mods',
            description = ('%d slot(s) available on this model'):format(#modSlots),
            icon = 'wrench',
            menu = id('mods')
        }
        local slotRows = {}
        for _, def in ipairs(modSlots) do
            local slot, label = def[1], def[2]
            slotRows[#slotRows + 1] = {
                title = label,
                description = ('%d option(s)'):format(GetNumVehicleMods(vehicle, slot)),
                icon = 'wrench',
                menu = id('mod-' .. slot)
            }
            DAG.Menu.Register({
                id = id('mod-' .. slot),
                title = label,
                subtitle = 'Applied to the preview instantly',
                options = {
                    { title = 'Next option', icon = 'chevron', keepOpen = true,
                        onSelect = function() cycleVehicleMod(vehicle, slot, label, 1) end },
                    { title = 'Previous option', icon = 'chevron', keepOpen = true,
                        onSelect = function() cycleVehicleMod(vehicle, slot, label, -1) end },
                    { title = 'Back to stock', icon = 'close', keepOpen = true,
                        onSelect = function()
                            RemoveVehicleMod(vehicle, slot)
                            Bridge.Notify(('%s: stock'):format(label), 'inform', 900)
                        end }
                }
            })
        end
        DAG.Menu.Register({ id = id('mods'), title = 'Body & interior', subtitle = preview.label, options = slotRows })
    end

    -- Extras: police lightbars, pushbars and the like live here. Addon
    -- vehicles run these well past the vanilla 14.
    local hasExtras = false
    for extra = 0, 25 do
        if DoesExtraExist(vehicle, extra) then hasExtras = true break end
    end
    if hasExtras then
        options[#options + 1] = { title = 'Toggle extras', icon = 'box', menu = id('extras') }
    end

    options[#options + 1] = { title = 'Performance', header = true }
    options[#options + 1] = {
        title = 'Maximum performance',
        description = 'Engine, brakes, gearbox, suspension, armour, turbo',
        icon = 'wrench',
        keepOpen = true,
        onSelect = function()
            for _, modType in ipairs(PERFORMANCE_MODS) do
                local count = GetNumVehicleMods(vehicle, modType)
                if count > 0 then SetVehicleMod(vehicle, modType, count - 1, false) end
            end
            ToggleVehicleMod(vehicle, 18, true)
            Bridge.Notify('Performance maxed.', 'success')
        end
    }
    options[#options + 1] = {
        title = 'Stock performance',
        icon = 'wrench',
        keepOpen = true,
        onSelect = function()
            for _, modType in ipairs(PERFORMANCE_MODS) do
                SetVehicleMod(vehicle, modType, -1, false)
            end
            ToggleVehicleMod(vehicle, 18, false)
        end
    }

    options[#options + 1] = { title = 'Finish', header = true }
    options[#options + 1] = {
        title = 'Save to the motor pool',
        description = ('Stores it for the %s exactly as it looks now'):format(preview.agencyId:upper()),
        icon = 'check',
        badgeTone = 'success',
        onSelect = Studio.SaveVehicle
    }
    options[#options + 1] = {
        title = 'Discard',
        description = 'Deletes the preview without saving',
        icon = 'close',
        badgeTone = 'danger',
        onSelect = deletePreview
    }

    -- Submenus are registered up front so `menu = ...` navigation works.
    paintMenu(id('paint-primary'), 'Primary colour', function(paint)
        local _, secondary = GetVehicleColours(vehicle)
        ClearVehicleCustomPrimaryColour(vehicle)
        SetVehicleColours(vehicle, paint, secondary)
    end)
    paintMenu(id('paint-secondary'), 'Secondary colour', function(paint)
        local primary = GetVehicleColours(vehicle)
        ClearVehicleCustomSecondaryColour(vehicle)
        SetVehicleColours(vehicle, primary, paint)
    end)

    local extraOptions = {}
    for extra = 0, 25 do
        if DoesExtraExist(vehicle, extra) then
            extraOptions[#extraOptions + 1] = {
                title = ('Extra %d'):format(extra),
                icon = 'box',
                keepOpen = true,
                onSelect = function()
                    SetVehicleExtra(vehicle, extra, IsVehicleExtraTurnedOn(vehicle, extra))
                end
            }
        end
    end
    DAG.Menu.Register({ id = id('extras'), title = 'Extras', subtitle = 'Toggles apply instantly', options = extraOptions })

    -- Registered (not just shown) so paint/extras submenus can navigate back.
    DAG.Menu.Register({ id = id('vehicle'), title = 'Vehicle studio', subtitle = preview.label, options = options })
    DAG.Menu.Open(id('vehicle'))
end

Studio.CustomizeMenu = customizeMenu

function Studio.SaveVehicle()
    if not preview or not DoesEntityExist(preview.entity) then
        return Bridge.Notify('The preview vehicle is gone.', 'error')
    end

    TriggerServerEvent(Federal.Net('garage:add'), preview.agencyId, {
        -- Re-editing an existing entry saves back over it, not beside it.
        id = preview.editId,
        model = preview.model,
        label = preview.label,
        minGrade = preview.minGrade,
        division = preview.division,
        props = Federal.Armory.CaptureVehicleProps(preview.entity)
    })
    deletePreview()
end

-- Entry point: ask which car, spawn it, hand over to the customize menu.
function Studio.Vehicle(agencyId)
    local agency = targetAgency(agencyId)
    if not agency then return Bridge.Notify('No agency to edit.', 'error') end

    deletePreview()

    local catalog = vehicleCatalog()
    local modelField = {
        name = 'model', label = 'Vehicle', required = true, allowCustom = true,
        placeholder = 'Search by name or spawn code'
    }
    if #catalog > 0 then
        modelField.type = 'select'
        modelField.options = catalog
    end

    DAG.Menu.Input('Add a vehicle to the ' .. agency.short, {
        modelField,
        { name = 'label', label = 'Display name' },
        { name = 'minGrade', label = 'Minimum grade', type = 'number', default = 0 },
        { name = 'division', label = 'Restrict to a division', type = 'select', default = '', options = divisionOptions(agency) }
    }, function(values)
        if not values or not values.model then return end
        local model = tostring(values.model):lower()

        local hash = GetHashKey(model)
        if not IsModelInCdimage(hash) or not IsModelAVehicle(hash) then
            return Bridge.Notify(('"%s" is not a vehicle model on this server.'):format(model), 'error')
        end

        RequestModel(hash)
        local deadline = GetGameTimer() + 5000
        while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(20) end
        if not HasModelLoaded(hash) then
            return Bridge.Notify('That model did not load.', 'error')
        end

        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)
        local vehicle = CreateVehicle(hash, coords.x, coords.y, coords.z, GetEntityHeading(ped), true, false)
        SetModelAsNoLongerNeeded(hash)
        -- Without a mod kit the game reports ZERO mod options on every slot,
        -- which is why a fresh preview used to show almost nothing to edit.
        SetVehicleModKit(vehicle, 0)
        SetVehicleOnGroundProperly(vehicle)
        SetPedIntoVehicle(ped, vehicle, -1)

        preview = {
            entity = vehicle,
            agencyId = agency.id,
            model = model,
            label = (values.label and values.label ~= '') and tostring(values.label)
                or GetLabelText(GetDisplayNameFromVehicleModel(hash)),
            minGrade = tonumber(values.minGrade) or 0,
            division = values.division and values.division ~= '' and tostring(values.division) or nil
        }
        if preview.label == 'NULL' or preview.label == '' then preview.label = model end

        enableCam(vehicle, 6.0, vehicleMenuSet())
        Bridge.Notify('Preview spawned. Numpad 4/6 rotate, 8/2 raise, scroll to zoom.', 'inform', 6000)
        customizeMenu()
    end)
end

-- Re-editing: spawns an EXISTING motor pool vehicle exactly as it was saved,
-- hands it to the same customize menu, and saving replaces the entry.
function Studio.VehicleEdit(agencyId, entry)
    local agency = targetAgency(agencyId)
    if not agency then return Bridge.Notify('No agency to edit.', 'error') end
    if type(entry) ~= 'table' or type(entry.model) ~= 'string' then
        return Bridge.Notify('That vehicle no longer exists.', 'error')
    end

    deletePreview()

    local hash = GetHashKey(entry.model)
    if not IsModelInCdimage(hash) or not IsModelAVehicle(hash) then
        return Bridge.Notify(('"%s" is not a vehicle model on this server.'):format(entry.model), 'error')
    end

    RequestModel(hash)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(20) end
    if not HasModelLoaded(hash) then
        return Bridge.Notify('That model did not load.', 'error')
    end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local vehicle = CreateVehicle(hash, coords.x, coords.y, coords.z, GetEntityHeading(ped), true, false)
    SetModelAsNoLongerNeeded(hash)
    SetVehicleModKit(vehicle, 0)
    if entry.props then Federal.Armory.ApplyVehicleProps(vehicle, entry.props) end
    SetVehicleOnGroundProperly(vehicle)
    SetPedIntoVehicle(ped, vehicle, -1)

    preview = {
        entity = vehicle,
        agencyId = agency.id,
        editId = entry.id,
        model = entry.model,
        label = entry.label or entry.model,
        minGrade = entry.minGrade or 0,
        division = entry.division
    }

    enableCam(vehicle, 6.0, vehicleMenuSet())
    Bridge.Notify(('Editing %s - saving replaces the stored vehicle.'):format(preview.label), 'inform', 6000)
    customizeMenu()
end

-- A crashed or restarted resource must not leave a preview car in the world.
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then deletePreview() end
end)

-- Uniform studio ---------------------------------------------------------------

local SLOT_LABELS = {
    { slot = 1, label = 'Mask' }, { slot = 3, label = 'Arms / torso' },
    { slot = 4, label = 'Legs' }, { slot = 5, label = 'Bag' },
    { slot = 6, label = 'Shoes' }, { slot = 7, label = 'Accessory' },
    { slot = 8, label = 'Shirt' }, { slot = 9, label = 'Body armour' },
    { slot = 10, label = 'Decals' }, { slot = 11, label = 'Jacket / top' }
}

local PROP_LABELS = {
    { slot = 0, label = 'Hat' }, { slot = 1, label = 'Glasses' },
    { slot = 2, label = 'Ear piece' }, { slot = 6, label = 'Watch' },
    { slot = 7, label = 'Bracelet' }
}

local outfitSnapshot = nil
local uniformAgencyId = nil
local uniformEditing = nil -- the existing uniform being re-dressed, if any

local function restoreSnapshot()
    if outfitSnapshot then Federal.Uniforms.Apply(outfitSnapshot) end
    outfitSnapshot = nil
end

-- Cycles one component slot. Every press applies instantly: your own ped is
-- the live preview.
local function cycleComponent(slot, step, texture)
    local ped = PlayerPedId()
    if texture then
        local drawable = GetPedDrawableVariation(ped, slot)
        local count = GetNumberOfPedTextureVariations(ped, slot, drawable)
        if count <= 0 then return end
        local nextTexture = (GetPedTextureVariation(ped, slot) + step) % count
        SetPedComponentVariation(ped, slot, drawable, nextTexture, 0)
    else
        local count = GetNumberOfPedDrawableVariations(ped, slot)
        if count <= 0 then return end
        local nextDrawable = (GetPedDrawableVariation(ped, slot) + step) % count
        SetPedComponentVariation(ped, slot, nextDrawable, 0, 0)
    end
end

local function cycleProp(slot, step)
    local ped = PlayerPedId()
    local count = GetNumberOfPedPropDrawableVariations(ped, slot)
    if count <= 0 then return end

    -- -1 (nothing worn) is part of the cycle, so every prop can be removed.
    local current = GetPedPropIndex(ped, slot)
    local nextDrawable = current + step
    if nextDrawable >= count then nextDrawable = -1
    elseif nextDrawable < -1 then nextDrawable = count - 1 end

    if nextDrawable < 0 then
        ClearPedProp(ped, slot)
    else
        SetPedPropIndex(ped, slot, nextDrawable, 0, true)
    end
end

-- Textures on the prop being worn: helmet camos, glasses tints, hat colours.
local function cyclePropTexture(slot, step)
    local ped = PlayerPedId()
    local drawable = GetPedPropIndex(ped, slot)
    if drawable < 0 then return end

    local count = GetNumberOfPedPropTextureVariations(ped, slot, drawable)
    if count <= 0 then return end

    local nextTexture = (GetPedPropTextureIndex(ped, slot) + step) % count
    SetPedPropIndex(ped, slot, drawable, nextTexture, true)
end

local function slotMenu(entry, isProp)
    local rows = {}
    local function row(title, fn)
        rows[#rows + 1] = { title = title, icon = 'chevron', keepOpen = true, onSelect = fn }
    end

    if isProp then
        row('Next style', function() cycleProp(entry.slot, 1) end)
        row('Previous style', function() cycleProp(entry.slot, -1) end)
        row('Next colour / texture', function() cyclePropTexture(entry.slot, 1) end)
        row('Previous colour / texture', function() cyclePropTexture(entry.slot, -1) end)
        rows[#rows + 1] = {
            title = 'Remove', icon = 'close', keepOpen = true,
            onSelect = function() ClearPedProp(PlayerPedId(), entry.slot) end
        }
    else
        row('Next style', function() cycleComponent(entry.slot, 1) end)
        row('Previous style', function() cycleComponent(entry.slot, -1) end)
        row('Next colour / texture', function() cycleComponent(entry.slot, 1, true) end)
        row('Previous colour / texture', function() cycleComponent(entry.slot, -1, true) end)
    end

    -- Navigate (not open) so Backspace returns to the studio's slot list.
    DAG.Menu.Register({ id = id('uniform-slot'), title = entry.label, subtitle = 'Changes show on you instantly', options = rows })
    DAG.Menu.Navigate(id('uniform-slot'))
end

function Studio.UniformMenu()
    local options = {
        { title = 'You are the preview', description = 'Every change applies to your ped instantly', disabled = true },
        { title = 'Clothing', header = true }
    }

    for _, entry in ipairs(SLOT_LABELS) do
        options[#options + 1] = {
            title = entry.label, icon = 'user', keepOpen = true,
            onSelect = function() slotMenu(entry, false) end
        }
    end

    options[#options + 1] = { title = 'Props', header = true }
    for _, entry in ipairs(PROP_LABELS) do
        options[#options + 1] = {
            title = entry.label, icon = 'user', keepOpen = true,
            onSelect = function() slotMenu(entry, true) end
        }
    end

    options[#options + 1] = { title = 'Finish', header = true }
    options[#options + 1] = {
        title = 'Save this outfit as a uniform',
        icon = 'check', badgeTone = 'success',
        onSelect = Studio.SaveUniform
    }
    options[#options + 1] = {
        title = 'Put my old clothes back',
        description = 'Restores what you wore when the studio opened',
        icon = 'close',
        onSelect = restoreSnapshot
    }

    show(id('uniform'), 'Uniform studio', nil, options)
end

function Studio.SaveUniform()
    local agencyId = uniformAgencyId
    if not agencyId then return end

    local editing = uniformEditing
    inputPending = true
    DAG.Menu.Input(editing and ('Save changes to %s'):format(editing.label) or 'Save this outfit', {
        { name = 'label', label = 'Uniform name', required = true, default = editing and editing.label },
        { name = 'minGrade', label = 'Minimum grade', type = 'number', default = editing and editing.minGrade or 0 },
        {
            name = 'variant', label = 'Fits', type = 'select', default = editing and editing.variant or 'any',
            options = {
                { value = 'any', label = 'Everyone' },
                { value = 'male', label = 'Male peds only' },
                { value = 'female', label = 'Female peds only' }
            }
        },
        {
            name = 'division', label = 'Restrict to a division', type = 'select',
            default = editing and editing.division or '',
            options = divisionOptions(targetAgency(agencyId))
        }
    }, function(values)
        inputPending = false
        if not values or not values.label then return end
        local captured = Federal.Uniforms.Capture()
        TriggerServerEvent(Federal.Net('uniform:adminSave'), agencyId, {
            -- Editing keeps the id, so the save replaces the same uniform.
            id = editing and editing.id or nil,
            label = values.label,
            minGrade = tonumber(values.minGrade) or 0,
            variant = tostring(values.variant or 'any'):lower(),
            division = values.division and values.division ~= '' and tostring(values.division) or nil,
            components = captured.components,
            props = captured.props
        })
        uniformEditing = nil
        outfitSnapshot = nil
    end)
end

-- Opens the live clothing editor. With `existing` (a uniform record), the ped
-- is dressed in that uniform first and saving replaces it; without, it starts
-- from whatever the player is wearing and saving creates a new uniform.
function Studio.Uniform(agencyId, existing)
    local agency = targetAgency(agencyId)
    if not agency then return Bridge.Notify('No agency to edit.', 'error') end

    uniformAgencyId = agency.id
    uniformEditing = type(existing) == 'table' and existing or nil
    outfitSnapshot = Federal.Uniforms.Capture()
    if uniformEditing then Federal.Uniforms.Apply(uniformEditing) end

    enableCam(PlayerPedId(), 2.8, {
        [id('uniform')] = true, [id('uniform-slot')] = true
    })
    Bridge.Notify('Numpad 4/6 rotate the camera, 8/2 raise it, scroll to zoom.', 'inform', 6000)
    Studio.UniformMenu()
end

-- Item studio ------------------------------------------------------------------

function Studio.Item(agencyId)
    local agency = targetAgency(agencyId)
    if not agency then return Bridge.Notify('No agency to edit.', 'error') end

    Bridge.TriggerCallback(Federal.Net('itemCatalog'), function(catalog)
        local itemField = {
            name = 'item', label = 'Item', required = true, allowCustom = true,
            placeholder = 'Search items and weapons'
        }
        if type(catalog) == 'table' and #catalog > 0 then
            itemField.type = 'select'
            itemField.options = catalog
        end

        DAG.Menu.Input('Stock the ' .. agency.short .. ' armory', {
            itemField,
            { name = 'label', label = 'Display name' },
            { name = 'count', label = 'Quantity per draw', type = 'number', default = 1 },
            { name = 'minGrade', label = 'Minimum grade', type = 'number', default = 0 },
            { name = 'price', label = 'Price', type = 'number', default = 0 },
            { name = 'category', label = 'Category (groups the armory list)' },
            { name = 'division', label = 'Restrict to a division', type = 'select', default = '', options = divisionOptions(agency) }
        }, function(values)
            if not values or not values.item then return end
            TriggerServerEvent(Federal.Net('armory:adminSave'), agency.id, {
                item = values.item,
                label = values.label,
                count = tonumber(values.count) or 1,
                minGrade = tonumber(values.minGrade) or 0,
                price = tonumber(values.price) or 0,
                category = values.category,
                division = values.division and values.division ~= '' and tostring(values.division) or nil
            })
        end)
    end)
end

-- Rank loadouts ----------------------------------------------------------------
--
-- Pick a rank, then pick what that rank unlocks. Selecting an entry sets its
-- minimum grade to the chosen rank's grade, so "tie the carbine to Senior
-- Agent" is two clicks. "Everyone" is the grade-0 rank.

local function loadoutRows(agency, rank)
    local function rankFor(minGrade)
        local best
        for _, candidate in ipairs(agency.ranks or {}) do
            if (minGrade or 0) >= candidate.grade and (not best or candidate.grade > best.grade) then
                best = candidate
            end
        end
        return best and best.label or ('grade ' .. tostring(minGrade))
    end

    local rows = { {
        title = ('Unlocks for %s (grade %d) and above'):format(rank.label, rank.grade),
        description = 'Select an entry to require this rank for it',
        disabled = true
    } }

    rows[#rows + 1] = { title = 'Uniforms', header = true }
    for _, uniform in ipairs(agency.uniforms or {}) do
        rows[#rows + 1] = {
            title = uniform.label,
            icon = 'user',
            badge = rankFor(uniform.minGrade),
            badgeTone = (uniform.minGrade or 0) == rank.grade and 'success' or nil,
            onSelect = function()
                local payload = {}
                for key, value in pairs(uniform) do payload[key] = value end
                payload.minGrade = rank.grade
                TriggerServerEvent(Federal.Net('uniform:adminSave'), agency.id, payload)
            end
        }
    end

    rows[#rows + 1] = { title = 'Armory', header = true }
    for _, entry in ipairs(agency.armory or {}) do
        rows[#rows + 1] = {
            title = entry.label,
            description = entry.item,
            icon = 'box',
            badge = rankFor(entry.minGrade),
            badgeTone = (entry.minGrade or 0) == rank.grade and 'success' or nil,
            onSelect = function()
                local payload = {}
                for key, value in pairs(entry) do payload[key] = value end
                payload.minGrade = rank.grade
                TriggerServerEvent(Federal.Net('armory:adminSave'), agency.id, payload)
            end
        }
    end

    return rows
end

function Studio.RankLoadout(agencyId, rank)
    local agency = targetAgency(agencyId)
    if not agency then return end

    local rows = loadoutRows(agency, rank)

    -- Vehicles come from the garage callback because the motor pool lives in
    -- its own store rather than on the agency record.
    Bridge.TriggerCallback(Federal.Net('garage'), function(vehicles)
        rows[#rows + 1] = { title = 'Vehicles', header = true }
        for _, entry in ipairs(vehicles or {}) do
            rows[#rows + 1] = {
                title = entry.label,
                description = entry.model,
                icon = 'car',
                badge = ('grade %d+'):format(entry.minGrade or 0),
                badgeTone = (entry.minGrade or 0) == rank.grade and 'success' or nil,
                onSelect = function()
                    TriggerServerEvent(Federal.Net('garage:setGrade'), agency.id, entry.id, rank.grade)
                end
            }
        end

        show(id('loadout'), ('%s loadout'):format(rank.label), agency.label, rows)
    end)
end

function Studio.RankLoadouts(agencyId)
    local agency = targetAgency(agencyId)
    if not agency then return Bridge.Notify('No agency to edit.', 'error') end

    local options = { {
        title = 'Pick a rank, then pick what it unlocks',
        disabled = true
    } }
    for _, rank in ipairs(agency.ranks or {}) do
        options[#options + 1] = {
            title = ('%d - %s'):format(rank.grade, rank.label),
            icon = 'user',
            onSelect = function() Studio.RankLoadout(agency.id, rank) end
        }
    end

    show(id('loadouts'), 'Rank loadouts', agency.label, options)
end

-- Divisions --------------------------------------------------------------------

local function reopenDivisions(agencyId)
    SetTimeout(350, function() Studio.Divisions(agencyId) end)
end

-- The division's own rank ladder (SWAT Operator, Team Lead...): list,
-- create, rename, delete. Members are placed on it from Personnel.
function Studio.DivisionRanks(agencyId, division)
    local function reopen()
        SetTimeout(350, function()
            local agency = targetAgency(agencyId)
            local fresh = agency and Federal.Schema.FindById(agency.divisions or {}, division.id)
            if fresh then Studio.DivisionRanks(agencyId, fresh) end
        end)
    end

    local options = {}
    for _, rank in ipairs(division.ranks or {}) do
        options[#options + 1] = {
            title = rank.label,
            icon = 'user',
            badge = ('Grade %d'):format(rank.grade),
            onSelect = function()
                DAG.Menu.Input(('Rank: %s'):format(rank.label), {
                    { name = 'label', label = 'Rank name (blank to delete)', default = rank.label }
                }, function(values)
                    if not values then return end
                    if not values.label or values.label == '' then
                        TriggerServerEvent(Federal.Net('editor:divisionRankDelete'), agencyId, division.id, rank.grade)
                    else
                        TriggerServerEvent(Federal.Net('editor:divisionRankSave'), agencyId, division.id, {
                            grade = rank.grade, label = values.label
                        })
                    end
                    reopen()
                end)
            end
        }
    end

    if #options == 0 then
        options[1] = { title = 'No ranks yet', description = 'Members simply belong to the division', disabled = true }
    end

    options[#options + 1] = { title = 'Manage', header = true }
    options[#options + 1] = {
        title = 'Create a rank',
        description = 'Grade 0 is the entry rank of the division',
        icon = 'check',
        onSelect = function()
            DAG.Menu.Input('New division rank', {
                { name = 'label', label = 'Rank name', required = true },
                { name = 'grade', label = 'Grade on the division ladder', type = 'number', required = true, default = #(division.ranks or {}) }
            }, function(values)
                if not values or not values.label then return end
                TriggerServerEvent(Federal.Net('editor:divisionRankSave'), agencyId, division.id, {
                    grade = tonumber(values.grade) or 0, label = values.label
                })
                reopen()
            end)
        end
    }

    show(id('division-ranks'), ('%s ranks'):format(division.label), 'The division\'s own ladder', options)
end

-- One division: rename, retune the joinable grade, its ranks, delete.
function Studio.Division(agencyId, division)
    local options = {
        {
            title = division.label,
            description = (division.minGrade or 0) > 0
                and ('Joinable from grade %d'):format(division.minGrade)
                or 'Joinable by every grade',
            disabled = true
        },
        {
            title = 'Division ranks',
            description = ('%d rank(s) on its own ladder'):format(#(division.ranks or {})),
            icon = 'lock',
            onSelect = function() Studio.DivisionRanks(agencyId, division) end
        },
        {
            title = 'Rename',
            icon = 'wrench',
            onSelect = function()
                DAG.Menu.Input('Rename division', {
                    { name = 'label', label = 'Division name', required = true, default = division.label }
                }, function(values)
                    if not values or not values.label then return end
                    TriggerServerEvent(Federal.Net('editor:divisionSave'), agencyId, {
                        id = division.id, label = values.label, minGrade = division.minGrade
                    })
                    reopenDivisions(agencyId)
                end)
            end
        },
        {
            title = 'Set the joinable grade',
            description = 'Members below it cannot be assigned',
            icon = 'lock',
            onSelect = function()
                DAG.Menu.Input('Joinable from grade', {
                    { name = 'minGrade', label = 'Grade', type = 'number', required = true, default = division.minGrade or 0 }
                }, function(values)
                    if not values then return end
                    TriggerServerEvent(Federal.Net('editor:divisionSave'), agencyId, {
                        id = division.id, label = division.label, minGrade = tonumber(values.minGrade) or 0
                    })
                    reopenDivisions(agencyId)
                end)
            end
        },
        {
            title = 'Delete this division',
            icon = 'close',
            badgeTone = 'danger',
            onSelect = function()
                DAG.Menu.Confirm(('Delete %s?'):format(division.label),
                    'Members assigned to it fall back to no division.', function(confirmed)
                    if not confirmed then return end
                    TriggerServerEvent(Federal.Net('editor:divisionDelete'), agencyId, division.id)
                    reopenDivisions(agencyId)
                end)
            end
        }
    }

    show(id('division'), division.label, 'Division', options)
end

function Studio.Divisions(agencyId)
    local agency = targetAgency(agencyId)
    if not agency then return Bridge.Notify('No agency to edit.', 'error') end

    local options = {}
    for _, division in ipairs(agency.divisions or {}) do
        options[#options + 1] = {
            title = division.label,
            description = (division.minGrade or 0) > 0 and ('Joinable from grade %d'):format(division.minGrade) or nil,
            icon = 'user',
            onSelect = function() Studio.Division(agency.id, division) end
        }
    end

    if #options == 0 then
        options[1] = { title = 'No divisions yet', disabled = true }
    end

    options[#options + 1] = { title = 'Manage', header = true }
    options[#options + 1] = {
        title = 'Create a division',
        description = 'A taskforce or sub-department of this agency',
        icon = 'check',
        onSelect = function()
            DAG.Menu.Input('New division', {
                { name = 'label', label = 'Division name', required = true },
                { name = 'minGrade', label = 'Joinable from grade', type = 'number', default = 0 }
            }, function(values)
                if not values or not values.label then return end
                TriggerServerEvent(Federal.Net('editor:divisionSave'), agency.id, {
                    label = values.label,
                    minGrade = tonumber(values.minGrade) or 0
                })
                reopenDivisions(agency.id)
            end)
        end
    }
    options[#options + 1] = {
        title = 'Assign members',
        description = 'Done from Personnel: pick a member, then Set division',
        icon = 'info',
        disabled = true
    }

    show(id('divisions'), 'Divisions', agency.label, options)
end

-- Command entry points -----------------------------------------------------------

RegisterNetEvent(Federal.Net('openStudio'), function(kind, agencyId)
    if kind == 'vehicle' then Studio.Vehicle(agencyId)
    elseif kind == 'uniform' then Studio.Uniform(agencyId)
    elseif kind == 'item' then Studio.Item(agencyId)
    elseif kind == 'ranks' then Studio.RankLoadouts(agencyId)
    elseif kind == 'divisions' then Studio.Divisions(agencyId)
    end
end)

return Studio
