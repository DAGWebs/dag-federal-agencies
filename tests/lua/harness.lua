-- A small FiveM runtime stub. It defines the natives the template touches so
-- the real resource files can be loaded and exercised in plain Lua 5.4.
local harness = {}

local ROOT = (arg and arg[0] or ''):match('^(.*)tests[/\\]lua[/\\]') or './'
harness.root = ROOT

local function path(relative) return ROOT .. relative end

harness.resourceName = 'dag-template'

-- Anything that rolls a die (NPC juror votes, NPC model choice, which callout
-- template fires) becomes deterministic under this. Restored by reset().
local realRandom = math.random
harness.realRandom = realRandom

function harness.fixRandom(value)
    math.random = function(lower, upper)
        if lower and upper then return lower end
        if lower then return 1 end
        return value or 0.5
    end
end

function harness.reset()
    harness.resourceStates = {}
    harness.files = {}
    harness.savedFiles = {}
    harness.handlers = {}
    harness.netEvents = {}
    harness.clientEvents = {}
    harness.serverEvents = {}
    harness.threads = {}
    harness.timers = {}
    harness.stateBags = {}
    harness.exportsRegistered = {}
    harness.exportTargets = {}
    harness.aceAllowed = {}
    harness.identifiers = {}
    harness.names = {}
    harness.output = {}
    harness.gameTimer = 0
    harness.drawnMarkers = {}
    harness.helpText = {}
    harness.controlsReleased = {}
    harness.playerCoords = nil
    harness.peds = {}
    harness.entityCoords = {}
    harness.players = {}
    harness.vehicles = {}
    harness.networkEntities = {}
    harness.headings = {}
    harness.pedComponents = {}
    harness.pedProps = {}
    harness.pedIsMale = false
    harness.pedIsDead = false
    harness.waypoint = nil
    harness.deadPeds = {}
    harness.freeAiming = false
    harness.speeds = {}
    harness.pedWeapons = {}
    harness.drawnWeapons = {}
    harness.pedTasks = {}
    harness.pedArmour = 0
    harness.handcuffed = false
    harness.animDicts = {}
    harness.playingAnim = nil
    harness.scenarios = {}
    harness.attachments = {}
    harness.seated = {}
    harness.sounds = {}
    harness.models = {}
    harness.spawnedPeds = {}
    harness.spawnedVehicles = {}
    harness.activePlayers = {}
    harness.closestVehicle = nil
    harness.blips = {}
    harness.nextBlip = 0
    harness.nextEntity = 5000
    harness.lastBlipName = nil
    harness.localEvents = {}
    harness.commands = {}
    harness.waitBudget = nil
    math.random = realRandom
    harness.nuiMessages = {}
    harness.nuiCallbacks = {}
    harness.nuiFocus = nil
    _G.LocalPlayer = { state = {} }

    _G.DAG = nil
    _G.Config = nil
    _G.source = nil
end

-- vector3 with the subtraction/length semantics the interaction loop relies on.
local vectorMeta = {}
vectorMeta.__index = vectorMeta
vectorMeta.__sub = function(a, b)
    return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, vectorMeta)
end
vectorMeta.__len = function(v)
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end
vectorMeta.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end

function _G.vector3(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, vectorMeta)
end
harness.vectorMeta = vectorMeta

_G.json = dofile(path('tests/lua/json.lua'))

function _G.GetCurrentResourceName() return harness.resourceName end
function _G.GetResourceState(resource) return harness.resourceStates[resource] or 'missing' end
function _G.GetGameTimer() return harness.gameTimer end

harness.STOP = '__harness_stop__'


-- Resource threads are `while true` loops. A wait budget lets a test run an
-- exact number of iterations and then unwind via a sentinel error.
function _G.Wait(ms)
    -- Wait(0) yields one frame in FiveM (~16ms), not zero time. Treating it as
    -- zero would make any loop that polls with Wait(0) spin forever against
    -- its own GetGameTimer deadline.
    harness.gameTimer = harness.gameTimer + ((ms and ms > 0) and ms or 16)
    if not harness.waitBudget then return end
    if harness.waitBudget <= 0 then error(harness.STOP, 0) end
    harness.waitBudget = harness.waitBudget - 1
end

-- Runs a thread body until it has called Wait() `allowedWaits` times, then
-- unwinds. `0` means "run one pass of a loop that waits at the end"; `1` means
-- "run one pass of a loop that waits at the top".
function harness.runThread(fn, allowedWaits)
    harness.waitBudget = allowedWaits or 0
    local ok, err = pcall(fn)
    harness.waitBudget = nil
    harness.nuiMessages = {}
    harness.nuiCallbacks = {}
    harness.nuiFocus = nil
    if not ok and err ~= harness.STOP then error(err, 0) end
end

function _G.CreateThread(fn) harness.threads[#harness.threads + 1] = fn end
function _G.SetTimeout(ms, fn) harness.timers[#harness.timers + 1] = { at = harness.gameTimer + ms, fn = fn } end

function _G.AddEventHandler(event, handler)
    harness.handlers[event] = harness.handlers[event] or {}
    table.insert(harness.handlers[event], handler)
    return { event = event, handler = handler }
end

function _G.RegisterNetEvent(event, handler)
    harness.netEvents[event] = true
    if handler then return AddEventHandler(event, handler) end
end

function _G.TriggerEvent(event, ...)
    table.insert(harness.localEvents, { event = event, args = table.pack(...) })
    for _, handler in ipairs(harness.handlers[event] or {}) do handler(...) end
end

function _G.TriggerClientEvent(event, target, ...)
    table.insert(harness.clientEvents, { event = event, target = target, args = table.pack(...) })
end

function _G.TriggerServerEvent(event, ...)
    table.insert(harness.serverEvents, { event = event, args = table.pack(...) })
end

function _G.RegisterCommand(name, handler, restricted)
    harness.commands = harness.commands or {}
    harness.commands[name] = { handler = handler, restricted = restricted }
end

function _G.LoadResourceFile(_, file) return harness.files[file] end
function _G.SaveResourceFile(_, file, data)
    harness.savedFiles[file] = data
    return true
end

function _G.print(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring((select(index, ...))) end
    table.insert(harness.output, table.concat(parts, '\t'))
end

-- Server player natives
function _G.GetPlayerIdentifierByType(playerSource) return harness.identifiers[playerSource] end
function _G.GetPlayerIdentifiers(playerSource)
    local id = harness.identifiers[playerSource]
    return id and { id } or {}
end
function _G.GetPlayerName(playerSource) return harness.names[playerSource] or ('Player' .. tostring(playerSource)) end
function _G.IsPlayerAceAllowed(playerSource, permission)
    local allowed = harness.aceAllowed[playerSource]
    return allowed ~= nil and (allowed == true or allowed[permission] == true)
end

function _G.GetPlayerPed(playerSource) return harness.peds[playerSource] or 0 end

function _G.GetPlayers()
    local list = {}
    for _, playerSource in ipairs(harness.players) do list[#list + 1] = tostring(playerSource) end
    return list
end

function _G.NetworkGetEntityFromNetworkId(netId) return harness.networkEntities[netId] or 0 end
function _G.DoesEntityExist(entity) return entity ~= nil and entity ~= 0 end
function _G.GetVehiclePedIsIn(ped) return harness.vehicles[ped] or 0 end
function _G.GetEntityHeading(entity) return harness.headings[entity] or 0.0 end

function _G.Player(playerSource)
    harness.stateBags[playerSource] = harness.stateBags[playerSource] or {}
    local bag = harness.stateBags[playerSource]
    return {
        state = setmetatable({}, {
            __index = function(_, key)
                if key == 'set' then
                    return function(_, name, value) bag[name] = value end
                end
                return bag[key]
            end
        })
    }
end

-- Client player natives
_G.LocalPlayer = { state = {} }
function _G.PlayerId() return 1 end
function _G.GetPlayerServerId() return 1 end
function _G.PlayerPedId() return 1 end
function _G.GetEntityCoords(entity)
    return harness.entityCoords[entity] or harness.playerCoords or vector3(0.0, 0.0, 0.0)
end
function _G.DrawMarker(kind, x, y, z)
    table.insert(harness.drawnMarkers, { kind = kind, coords = vector3(x, y, z) })
end
function _G.BeginTextCommandDisplayHelp() end
function _G.AddTextComponentSubstringPlayerName(text) table.insert(harness.helpText, text) end
function _G.EndTextCommandDisplayHelp() end
function _G.IsControlJustReleased(_, key) return harness.controlsReleased[key] == true end
function _G.SendNUIMessage(payload)
    table.insert(harness.nuiMessages, payload)
end

function _G.RegisterNUICallback(name, handler)
    harness.nuiCallbacks[name] = handler
end

function _G.SetNuiFocus(hasFocus, hasCursor)
    harness.nuiFocus = { focus = hasFocus, cursor = hasCursor }
end

-- Ped appearance, used by uniform capture and apply.
function _G.IsPedMale() return harness.pedIsMale == true end
function _G.GetPedDrawableVariation(_, slot) return (harness.pedComponents[slot] or {}).drawable or 0 end
function _G.GetPedTextureVariation(_, slot) return (harness.pedComponents[slot] or {}).texture or 0 end
function _G.GetPedPaletteVariation(_, slot) return (harness.pedComponents[slot] or {}).palette or 0 end
function _G.GetPedPropIndex(_, slot) return (harness.pedProps[slot] or {}).drawable or -1 end
function _G.GetPedPropTextureIndex(_, slot) return (harness.pedProps[slot] or {}).texture or 0 end

function _G.SetPedComponentVariation(_, slot, drawable, texture, palette)
    harness.pedComponents[slot] = { drawable = drawable, texture = texture, palette = palette }
end
function _G.SetPedPropIndex(_, slot, drawable, texture)
    harness.pedProps[slot] = { drawable = drawable, texture = texture }
end
function _G.ClearPedProp(_, slot) harness.pedProps[slot] = nil end
function _G.SetPedArmour(_, value) harness.pedArmour = value end

-- Tasks, restraint and controls.
function _G.SetEnableHandcuffs(_, enabled) harness.handcuffed = enabled end
function _G.ClearPedTasks() end
function _G.RequestAnimDict(dict) harness.animDicts[dict] = true end
function _G.HasAnimDictLoaded(dict) return harness.animDicts[dict] == true end
function _G.TaskPlayAnim(_, dict, name) harness.playingAnim = { dict = dict, name = name } end
function _G.IsEntityPlayingAnim(_, dict, name)
    return harness.playingAnim ~= nil and harness.playingAnim.dict == dict and harness.playingAnim.name == name
end
function _G.TaskStartScenarioInPlace(ped, scenario)
    harness.scenarios[ped] = scenario
    harness.pedTasks[ped] = 'scenario'
end
function _G.DisableControlAction() end
function _G.AttachEntityToEntity(entity, target) harness.attachments[entity] = target end
function _G.DetachEntity(entity) harness.attachments[entity] = nil end
function _G.SetPedIntoVehicle(ped, vehicle, seat) harness.seated[ped] = { vehicle = vehicle, seat = seat } end
function _G.IsVehicleSeatFree() return true end
function _G.PlaySoundFrontend(_, name) harness.sounds[#harness.sounds + 1] = name end
function _G.IsEntityDead() return harness.pedIsDead == true end
function _G.SetNewWaypoint(x, y) harness.waypoint = { x = x, y = y } end
function _G.SetEntityCoords(entity, x, y, z) harness.entityCoords[entity] = vector3(x, y, z) end
function _G.ClearPedTasksImmediately() end

-- Suspect behaviour. Tasks are recorded rather than performed so a test can
-- assert what a suspect decided to do.
function _G.IsPedDeadOrDying(ped) return harness.deadPeds[ped] == true end
function _G.IsPlayerFreeAiming() return harness.freeAiming == true end
function _G.GetEntitySpeed(ped) return harness.speeds[ped] or 0.0 end
function _G.SetPedAccuracy() end
function _G.SetPedSeeingRange() end
function _G.SetPedHearingRange() end
function _G.SetPedKeepTask() end
function _G.GiveWeaponToPed(ped, weapon) harness.pedWeapons[ped] = weapon end
function _G.SetCurrentPedWeapon(ped, weapon) harness.drawnWeapons[ped] = weapon end
function _G.TaskHandsUp(ped) harness.pedTasks[ped] = 'handsUp' end
function _G.TaskSmartFleePed(ped) harness.pedTasks[ped] = 'flee' end
function _G.TaskCombatPed(ped) harness.pedTasks[ped] = 'combat' end

-- Models and entities.
function _G.GetHashKey(name) return name end
function _G.RequestModel(model) harness.models[model] = true end
function _G.HasModelLoaded(model) return harness.models[model] == true end
function _G.SetModelAsNoLongerNeeded() end
function _G.CreatePed(_, model, x, y, z, heading)
    harness.nextEntity = harness.nextEntity + 1
    harness.spawnedPeds[harness.nextEntity] = { model = model, coords = vector3(x, y, z), heading = heading }
    return harness.nextEntity
end
function _G.CreateVehicle(model, x, y, z)
    harness.nextEntity = harness.nextEntity + 1
    harness.spawnedVehicles[harness.nextEntity] = { model = model, coords = vector3(x, y, z) }
    return harness.nextEntity
end
function _G.SetVehicleNumberPlateText() end
function _G.DeleteEntity(entity)
    harness.spawnedPeds[entity] = nil
    harness.spawnedVehicles[entity] = nil
end
function _G.SetEntityAsMissionEntity() end
function _G.SetBlockingOfNonTemporaryEvents() end
function _G.SetPedFleeAttributes() end
function _G.SetPedDiesWhenInjured() end
function _G.GetActivePlayers() return harness.activePlayers end
function _G.GetPlayerFromServerId(serverId) return serverId end
function _G.GetClosestVehicle() return harness.closestVehicle or 0 end
function _G.NetworkGetNetworkIdFromEntity(entity) return entity end

-- Blips. Held in a table so a test can assert what was drawn and that a
-- rebuild removed the previous set.
function _G.AddBlipForCoord(x, y, z)
    harness.nextBlip = harness.nextBlip + 1
    harness.blips[harness.nextBlip] = { coords = vector3(x, y, z) }
    return harness.nextBlip
end
function _G.DoesBlipExist(blip) return harness.blips[blip] ~= nil end
function _G.RemoveBlip(blip) harness.blips[blip] = nil end
function _G.SetBlipSprite(blip, sprite) if harness.blips[blip] then harness.blips[blip].sprite = sprite end end
function _G.SetBlipColour(blip, colour) if harness.blips[blip] then harness.blips[blip].colour = colour end end
function _G.SetBlipScale(blip, scale) if harness.blips[blip] then harness.blips[blip].scale = scale end end
function _G.SetBlipAsShortRange() end
function _G.SetBlipRoute(blip, enabled) if harness.blips[blip] then harness.blips[blip].route = enabled end end
function _G.BeginTextCommandSetBlipName() end
function _G.AddTextComponentString(text) harness.lastBlipName = text end
function _G.EndTextCommandSetBlipName(blip) if harness.blips[blip] then harness.blips[blip].name = harness.lastBlipName end end

function _G.AddStateBagChangeHandler(key, _, handler)
    harness.handlers['statebag:' .. key] = harness.handlers['statebag:' .. key] or {}
    table.insert(harness.handlers['statebag:' .. key], handler)
end

_G.exports = setmetatable({}, {
    __call = function(_, name, fn) harness.exportsRegistered[name] = fn end,
    __index = function(_, resource)
        local target = harness.exportTargets[resource]
        if not target then error(('No stub export target for "%s"'):format(resource), 2) end
        return target
    end
})

-- Runs every thread body once. Loops in resource code use `while true`, so
-- threads under test are written to break out via a harness flag.
function harness.runThreads()
    for _, fn in ipairs(harness.threads) do fn() end
end

function harness.flushTimers(untilTime)
    untilTime = untilTime or math.huge
    local pending = harness.timers
    harness.timers = {}
    for _, timer in ipairs(pending) do
        if timer.at <= untilTime then timer.fn() else table.insert(harness.timers, timer) end
    end
end

function harness.load(relative)
    local chunk, err = loadfile(path(relative))
    assert(chunk, err)
    return chunk()
end

function harness.loadConfig()
    harness.load('config.lua')
    return _G.Config
end

function harness.loadServer(opts)
    opts = opts or {}
    harness.loadConfig()
    harness.load('bridge/shared.lua')
    harness.load('bridge/server.lua')
    for _, adapter in ipairs(opts.adapters or { 'standalone' }) do
        harness.load('bridge/server/' .. adapter .. '.lua')
    end
    for _, module in ipairs(opts.modules or {}) do
        harness.load('modules/' .. module .. '/server.lua')
    end
    return _G.DAG
end

function harness.loadClient(opts)
    opts = opts or {}
    harness.loadConfig()
    harness.load('bridge/shared.lua')
    harness.load('bridge/client.lua')
    for _, adapter in ipairs(opts.adapters or { 'standalone' }) do
        harness.load('bridge/client/' .. adapter .. '.lua')
    end
    for _, module in ipairs(opts.modules or {}) do
        harness.load('modules/' .. module .. '/client.lua')
    end
    for _, file in ipairs(opts.files or {}) do
        harness.load(file)
    end
    return _G.DAG
end

-- Places a player on the server side: gives them a ped handle, positions it,
-- and registers them as connected so GetPlayers() reports them.
function harness.placePlayer(playerSource, coords)
    local ped = 1000 + playerSource
    harness.peds[playerSource] = ped
    harness.entityCoords[ped] = coords
    for _, existing in ipairs(harness.players) do
        if existing == playerSource then return ped end
    end
    harness.players[#harness.players + 1] = playerSource
    return ped
end

-- Loads the full federal server stack: bridge, the template modules it builds
-- on, the shared validators, the default catalogs and the federal modules
-- named in `federal`.
function harness.loadFederalServer(opts)
    opts = opts or {}
    harness.loadServer({
        adapters = opts.adapters or { 'standalone' },
        modules = { 'storage', 'access', 'repository', 'commands' }
    })
    for _, file in ipairs({ 'constants', 'util', 'schema' }) do
        harness.load('federal/shared/' .. file .. '.lua')
    end
    for _, file in ipairs(opts.catalogs or { 'agencies', 'callouts', 'court' }) do
        harness.load('federal/config/' .. file .. '.lua')
    end
    for _, file in ipairs(opts.federal or { 'core' }) do
        harness.load('federal/server/' .. file .. '.lua')
    end
    return _G.DAG
end

-- Loads the full federal client stack in the manifest's order, so a file that
-- touches a native at load time (rather than inside a function or a thread)
-- fails here instead of on a live server.
function harness.loadFederalClient(opts)
    opts = opts or {}
    harness.loadClient({
        adapters = opts.adapters or { 'standalone' },
        modules = { 'menu', 'interactions' }
    })
    for _, file in ipairs({ 'constants', 'util', 'schema' }) do
        harness.load('federal/shared/' .. file .. '.lua')
    end
    for _, file in ipairs({ 'agencies', 'callouts', 'court' }) do
        harness.load('federal/config/' .. file .. '.lua')
    end
    for _, file in ipairs(opts.federal or {
        'state', 'progress', 'uniforms', 'actions', 'suspects', 'cad', 'armory',
        'reports', 'leads', 'callouts', 'court', 'jail', 'personnel', 'editor', 'hud', 'menus', 'zones', 'bootstrap'
    }) do
        harness.load('federal/client/' .. file .. '.lua')
    end
    return _G.DAG
end

-- Gives a player a framework job on the standalone adapter, which is what
-- Core.Membership reads to resolve their agency and rank.
function harness.setJob(playerSource, name, grade)
    local player = DAG.Framework.GetPlayer(playerSource)
    player.job.name = name
    player.job.label = name
    player.job.grade = grade or 0
    return player.job
end

function harness.lastNuiMessage()
    return harness.nuiMessages[#harness.nuiMessages]
end

function harness.outputContains(needle)
    for _, line in ipairs(harness.output) do
        if line:find(needle, 1, true) then return true end
    end
    return false
end

harness.reset()
return harness
