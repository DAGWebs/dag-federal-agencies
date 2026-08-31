-- Client side of the /fedconfig GUI.
--
-- Opens the NUI panel with a server-authorized snapshot, relays each Save the
-- panel makes to the existing editor/armory/uniform endpoints, and refreshes
-- the panel whenever the server pushes a new context. The "use my position"
-- button reads the player's live coordinates here and fills the form; the
-- server still validates every write.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Const = Federal.Constants
local State = Federal.State

local Panel = {}
Federal.ConfigPanel = Panel

local isOpen = false
local agencyId = nil
local agencyCache = nil   -- last full agency record (uniform meta re-saves need components)
local vehicleCache = {}   -- id -> full vehicle entry, props included

local function round(value)
    return math.floor((tonumber(value) or 0) * 100 + 0.5) / 100
end

-- Static vocab the forms render: room kinds, permissions, uniform variants,
-- and the framework's licence names (certification prerequisites).
local function buildMeta(itemCatalog, licences)
    local zoneKinds = {}
    for kind, detail in pairs(Const.ZoneKinds) do
        zoneKinds[#zoneKinds + 1] = { value = kind, label = detail.label }
    end
    table.sort(zoneKinds, function(a, b) return a.label < b.label end)

    local permissions = {}
    for name in pairs(Const.Permissions) do permissions[#permissions + 1] = name end
    table.sort(permissions)

    return {
        zoneKinds = zoneKinds,
        permissions = permissions,
        variants = Const.UniformVariants,
        items = itemCatalog or {},
        licences = licences or {}
    }
end

-- The UI never needs vehicle props; keep them here for re-saves.
local function slimVehicles(list)
    vehicleCache = {}
    local slim = {}
    for _, entry in ipairs(list or {}) do
        vehicleCache[entry.id] = entry
        slim[#slim + 1] = {
            id = entry.id,
            model = entry.model,
            label = entry.label,
            minGrade = entry.minGrade or 0,
            division = entry.division,
            hasProps = entry.props ~= nil
        }
    end
    return slim
end

local function push(action, snapshot)
    agencyCache = snapshot.agency
    SendNUIMessage({
        action = action,
        config = {
            agency = snapshot.agency,
            vehicles = slimVehicles(snapshot.vehicles),
            doors = snapshot.doors or {},
            applications = snapshot.applications or {},
            topGrade = snapshot.topGrade,
            meta = buildMeta(snapshot.itemCatalog, snapshot.licences)
        }
    })
end

function Panel.Open(id)
    Bridge.TriggerCallback(Federal.Net('config:get'), function(snapshot, err)
        if not snapshot then
            return Bridge.Notify(err or 'You are not authorized to configure an agency.', 'error')
        end
        agencyId = snapshot.agency.id
        isOpen = true
        SetNuiFocus(true, true)
        push('config:open', snapshot)
    end, id)
end

function Panel.Close()
    if not isOpen then return end
    isOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'config:close' })
end

local function refresh()
    if not isOpen then return end
    Bridge.TriggerCallback(Federal.Net('config:get'), function(snapshot)
        if snapshot then push('config:update', snapshot) end
    end, agencyId)
end

-- Every server write ends in Core.Sync, which lands here: the panel re-reads
-- and re-renders, so what it shows is always what got stored.
State.OnChange(function()
    if isOpen then refresh() end
end)

-- Operations ------------------------------------------------------------------

local function splitJobs(text)
    local jobs = {}
    for job in tostring(text or ''):gmatch('[^,]+') do
        local trimmed = job:gsub('^%s+', ''):gsub('%s+$', '')
        if trimmed ~= '' then jobs[#jobs + 1] = trimmed:lower() end
    end
    return jobs
end

-- Resolves the panel's icon fields into what the server expects: a blip
-- table when anything is chosen, `false` to clear back to the default when
-- everything is left on default, and the custom id always winning.
local function resolveBlip(data)
    local sprite = tonumber(data.blipCustom) or tonumber(data.blipSprite)
    local color = tonumber(data.blipColor)
    if not sprite and not color then return false end
    return { sprite = sprite, color = color, scale = 0.85 }
end

local OPS = {}

OPS.agencySave = function(data)
    local blip = resolveBlip(data)
    TriggerServerEvent(Federal.Net('editor:agencyUpdate'), agencyId, {
        label = data.label,
        short = data.short,
        color = data.color,
        bossGrade = tonumber(data.bossGrade),
        callsignPrefix = tostring(data.callsignPrefix or ''),
        jobs = splitJobs(data.jobs),
        npcCallouts = {
            enabled = data.npcEnabled ~= false,
            civilianLimit = tonumber(data.npcCivilianLimit) or 0,
            maxActive = tonumber(data.npcMaxActive) or 0
        },
        cad = { logo = tostring(data.cadLogo or '') },
        -- UpdateAgency only replaces the blip when handed a table, so
        -- "agency default" simply leaves the current agency icon alone.
        blip = type(blip) == 'table' and blip or nil
    })
end

OPS.stationSave = function(data)
    TriggerServerEvent(Federal.Net('editor:stationSave'), agencyId, {
        id = data.id, label = data.label, coords = data.coords,
        kind = data.kind, publicBlip = data.publicBlip ~= false,
        blip = resolveBlip(data)
    })
end

OPS.stationDelete = function(data)
    TriggerServerEvent(Federal.Net('editor:stationDelete'), agencyId, data.id)
end

OPS.zoneSave = function(data)
    TriggerServerEvent(Federal.Net('editor:zoneSave'), agencyId, data.stationId, {
        id = data.id, kind = data.kind, label = data.label ~= '' and data.label or nil,
        radius = tonumber(data.radius), minGrade = tonumber(data.minGrade), coords = data.coords
    })
end

OPS.zoneDelete = function(data)
    TriggerServerEvent(Federal.Net('editor:zoneDelete'), agencyId, data.stationId, data.id)
end

OPS.rankSave = function(data)
    TriggerServerEvent(Federal.Net('editor:rankSave'), agencyId, {
        grade = tonumber(data.grade), label = data.label, permissions = data.permissions or {}
    })
end

OPS.rankDelete = function(data)
    TriggerServerEvent(Federal.Net('editor:rankDelete'), agencyId, tonumber(data.grade))
end

OPS.divisionSave = function(data)
    TriggerServerEvent(Federal.Net('editor:divisionSave'), agencyId, {
        id = data.id, label = data.label, minGrade = tonumber(data.minGrade),
        callsignPrefix = tostring(data.callsignPrefix or '')
    })
end

OPS.divisionDelete = function(data)
    TriggerServerEvent(Federal.Net('editor:divisionDelete'), agencyId, data.id)
end

OPS.certSave = function(data)
    TriggerServerEvent(Federal.Net('editor:certSave'), agencyId, {
        id = data.id,
        label = data.label,
        description = data.description ~= '' and data.description or nil,
        licences = type(data.licences) == 'table' and data.licences or nil
    })
end

OPS.certDelete = function(data)
    TriggerServerEvent(Federal.Net('editor:certDelete'), agencyId, data.id)
end

OPS.invSave = function(data)
    TriggerServerEvent(Federal.Net('editor:invSave'), agencyId, {
        id = data.id,
        match = data.match,
        statements = type(data.statements) == 'table' and data.statements or {},
        leads = type(data.leads) == 'table' and data.leads or {}
    })
end

OPS.invDelete = function(data)
    TriggerServerEvent(Federal.Net('editor:invDelete'), agencyId, data.id)
end

OPS.divisionRankSave = function(data)
    TriggerServerEvent(Federal.Net('editor:divisionRankSave'), agencyId, data.divisionId, {
        grade = tonumber(data.grade), label = data.label
    })
end

OPS.divisionRankDelete = function(data)
    TriggerServerEvent(Federal.Net('editor:divisionRankDelete'), agencyId, data.divisionId, tonumber(data.grade))
end

OPS.uniformSave = function(data)
    local payload = {
        id = data.id,
        label = data.label,
        minGrade = tonumber(data.minGrade) or 0,
        variant = data.variant or 'any',
        division = data.division ~= '' and data.division or nil
    }

    if data.capture or not data.id then
        -- Replace (or seed) the components with what the player is wearing.
        local captured = Federal.Uniforms.Capture()
        payload.components = captured.components
        payload.props = captured.props
    else
        -- Meta-only edit: resend the stored components untouched.
        local existing = Federal.Schema.FindById(agencyCache and agencyCache.uniforms or {}, data.id)
        if not existing then return Bridge.Notify('That uniform no longer exists.', 'error') end
        payload.components = existing.components
        payload.props = existing.props
        payload.armour = existing.armour
    end

    TriggerServerEvent(Federal.Net('uniform:adminSave'), agencyId, payload)
end

OPS.uniformDelete = function(data)
    TriggerServerEvent(Federal.Net('uniform:adminDelete'), agencyId, data.id)
end

-- Duplicates a uniform: the same clothes and restrictions under a new name,
-- as a starting point instead of dressing from scratch.
OPS.uniformDuplicate = function(data)
    local existing = Federal.Schema.FindById(agencyCache and agencyCache.uniforms or {}, data.id)
    if not existing then return Bridge.Notify('That uniform no longer exists.', 'error') end

    TriggerServerEvent(Federal.Net('uniform:adminSave'), agencyId, {
        -- No id: the save creates a new uniform rather than replacing.
        label = ('%s (copy)'):format(existing.label),
        minGrade = existing.minGrade,
        variant = existing.variant,
        division = existing.division,
        armour = existing.armour,
        components = existing.components,
        props = existing.props
    })
end

-- Hands an existing uniform to the live clothing studio: the panel closes,
-- the ped is dressed in the uniform, and saving in the studio replaces it.
OPS.uniformStudio = function(data)
    local existing = Federal.Schema.FindById(agencyCache and agencyCache.uniforms or {}, data.id)
    if not existing then return Bridge.Notify('That uniform no longer exists.', 'error') end

    local editAgency = agencyId
    isOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'config:close' })
    Federal.Studio.Uniform(editAgency, existing)
end

-- Hands off to the live vehicle studio: the panel closes, the model is
-- typed and spawned, customized with the orbit camera, and saving files it
-- into the motor pool - same flow the uniforms get.
OPS.vehicleStudio = function()
    local editAgency = agencyId
    isOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'config:close' })
    Federal.Studio.Vehicle(editAgency)
end

-- Re-editing an existing motor pool vehicle: the cached entry carries its
-- saved props, so the studio spawns it exactly as it was stored.
OPS.vehicleEdit = function(data)
    local entry = vehicleCache[data and data.id]
    if not entry then return Bridge.Notify('That vehicle no longer exists.', 'error') end

    local editAgency = agencyId
    isOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'config:close' })
    Federal.Studio.VehicleEdit(editAgency, entry)
end

OPS.armorySave = function(data)
    TriggerServerEvent(Federal.Net('armory:adminSave'), agencyId, {
        id = data.id, item = data.item, label = data.label ~= '' and data.label or nil,
        count = tonumber(data.count), minGrade = tonumber(data.minGrade),
        price = tonumber(data.price), category = data.category ~= '' and data.category or nil,
        division = data.division ~= '' and data.division or nil
    })
end

OPS.armoryDelete = function(data)
    TriggerServerEvent(Federal.Net('armory:adminDelete'), agencyId, data.id)
end

OPS.vehicleSave = function(data)
    local model, props

    if data.capture then
        local vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
        if vehicle == 0 then
            return Bridge.Notify('Sit in the vehicle you want to capture first.', 'error')
        end
        model = (GetDisplayNameFromVehicleModel(GetEntityModel(vehicle)) or ''):lower()
        if model == '' or model == 'carnotfound' then
            return Bridge.Notify('Could not read this vehicle model.', 'error')
        end
        props = Federal.Armory.CaptureVehicleProps(vehicle)
    else
        local existing = data.id and vehicleCache[data.id]
        if not existing then return Bridge.Notify('That vehicle no longer exists.', 'error') end
        model = existing.model
        props = existing.props
    end

    TriggerServerEvent(Federal.Net('garage:add'), agencyId, {
        id = data.id,
        model = model,
        label = data.label ~= '' and data.label or nil,
        minGrade = tonumber(data.minGrade) or 0,
        division = data.division ~= '' and data.division or nil,
        props = props
    })
end

OPS.vehicleDelete = function(data)
    TriggerServerEvent(Federal.Net('garage:remove'), agencyId, data.id)
end

OPS.doorSave = function(data)
    TriggerServerEvent(Federal.Net('door:update'), agencyId, {
        id = data.id, label = data.label,
        minGrade = tonumber(data.minGrade), radius = tonumber(data.radius),
        locked = data.locked == true,
        -- Blank coordinate fields arrive as an empty prompt and clear the
        -- point back to the door object itself.
        prompt = type(data.prompt) == 'table' and data.prompt or {}
    })
end

OPS.doorDelete = function(data)
    TriggerServerEvent(Federal.Net('door:remove'), agencyId, data.id)
end

OPS.appFormSave = function(data)
    TriggerServerEvent(Federal.Net('apps:form'), agencyId, {
        enabled = data.enabled == true,
        title = data.title,
        rank = tonumber(data.rank),
        division = data.division ~= '' and data.division or ''
    })
end

OPS.appQuestionSave = function(data)
    TriggerServerEvent(Federal.Net('apps:question'), agencyId, {
        id = data.id, label = data.label, required = data.required == true
    })
end

OPS.appQuestionDelete = function(data)
    TriggerServerEvent(Federal.Net('apps:questionDelete'), agencyId, data.id)
end

OPS.appPlaceSave = function(data)
    TriggerServerEvent(Federal.Net('apps:place'), agencyId, {
        id = data.id, label = data.label, coords = data.coords
    })
end

OPS.appPlaceDelete = function(data)
    TriggerServerEvent(Federal.Net('apps:placeDelete'), agencyId, data.id)
end

-- Capturing a door needs the camera: the panel drops NUI focus, gives the
-- player a moment to aim at the door, raycasts, then comes back.
OPS.doorCapture = function(data)
    SetNuiFocus(false, false)
    Bridge.Notify('Aim at the door or gate... capturing in 4 seconds.', 'inform', 4000)

    CreateThread(function()
        Wait(4000)
        local captured, message = Federal.DoorLocks.CaptureAim()
        if captured then
            TriggerServerEvent(Federal.Net('door:add'), agencyId, {
                model = captured.model,
                coords = captured.coords,
                label = data.label ~= '' and data.label or nil,
                minGrade = tonumber(data.minGrade) or 0
            })
        else
            Bridge.Notify(message or 'No door captured.', 'error')
        end

        if isOpen then SetNuiFocus(true, true) end
    end)
end

-- NUI wiring ------------------------------------------------------------------

RegisterNUICallback('cfgAction', function(payload, reply)
    reply({})
    if not isOpen or type(payload) ~= 'table' then return end
    local handler = OPS[payload.op]
    if handler then handler(type(payload.data) == 'table' and payload.data or {}) end
end)

RegisterNUICallback('cfgCoords', function(_, reply)
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    reply({ x = round(coords.x), y = round(coords.y), z = round(coords.z), heading = round(GetEntityHeading(ped)) })
end)

RegisterNUICallback('cfgClose', function(_, reply)
    reply({})
    isOpen = false
    SetNuiFocus(false, false)
end)

RegisterNetEvent(Federal.Net('openConfig'), function(id)
    Panel.Open(type(id) == 'string' and id or nil)
end)

-- Never leave the panel holding focus across a resource restart.
AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() and isOpen then SetNuiFocus(false, false) end
end)

return Panel
