-- The callout scene on the client.
--
-- One assigned officer is the scene HOST: their machine spawns the suspect,
-- the witnesses and the evidence markers, so exactly one client owns them.
-- Everyone else assigned sees the blip and the objective list and interacts
-- with entities the host created.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local State = Federal.State
local Callouts = {}
Federal.Callouts = Callouts

local known = {}
local scene = { calloutId = nil, peds = {}, blip = nil, evidence = {}, interactions = {} }

local function id(name)
    return Federal.Menus.Id('callout:' .. name)
end

-- Scene teardown -----------------------------------------------------------------

local function clearScene()
    for _, ped in ipairs(scene.peds) do
        Federal.Suspects.Forget(ped)
        if DoesEntityExist(ped) then DeleteEntity(ped) end
    end
    for _, interaction in ipairs(scene.interactions) do DAG.Interactions.Remove(interaction) end
    if scene.blip and DoesBlipExist(scene.blip) then RemoveBlip(scene.blip) end

    scene = { calloutId = nil, peds = {}, blip = nil, evidence = {}, interactions = {}, suspect = nil }
end

Callouts.ClearScene = clearScene

-- Scene construction --------------------------------------------------------------

local function spawnPed(model, coords, heading, calm)
    local hash = GetHashKey(model)
    RequestModel(hash)

    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(20) end
    if not HasModelLoaded(hash) then return nil end

    -- On the ACTUAL ground: the old fixed z-1.0 buried peds on uneven or
    -- part-streamed terrain and they fell through the world.
    local groundZ = coords.z
    local found, resolved = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z + 5.0, false)
    if found then groundZ = resolved end

    local ped = CreatePed(4, hash, coords.x, coords.y, groundZ, heading or 0.0, true, false)
    SetModelAsNoLongerNeeded(hash)
    SetEntityAsMissionEntity(ped, true, true)
    SetPedDiesWhenInjured(ped, false)

    -- `calm` peds (witnesses, court NPCs) are meant to stand there. A suspect
    -- is not: blocking non-temporary events is what made the old suspect a
    -- prop that waited to be pressed.
    if calm ~= false then
        SetBlockingOfNonTemporaryEvents(ped, true)
        SetPedFleeAttributes(ped, 0, false)
        TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_STAND_IMPATIENT', 0, true)
    end

    scene.peds[#scene.peds + 1] = ped
    return ped
end

Callouts.SpawnPed = spawnPed

-- Scatters evidence points around the scene. They are client-side markers; the
-- record they create is filed on the server when one is worked.
local function placeEvidence(callout)
    local spread = (callout.evidence and callout.evidence.radius) or 15.0
    local kinds = (callout.evidence and callout.evidence.kinds) or { 'print' }
    local wanted = 0

    for _, stage in ipairs(callout.stages or {}) do
        if stage.kind == 'evidence' then wanted = math.max(wanted, stage.count or 1) end
    end
    -- One spare, so a player who misses a marker is not stuck.
    wanted = wanted + 1

    for index = 1, wanted do
        local angle = (index / wanted) * math.pi * 2
        local point = {
            x = callout.location.x + (math.cos(angle) * spread * 0.6),
            y = callout.location.y + (math.sin(angle) * spread * 0.6),
            z = callout.location.z
        }
        local kind = kinds[((index - 1) % #kinds) + 1]
        local markerId = ('federal:callout:%s:evidence:%d'):format(callout.id, index)

        DAG.Interactions.Register({
            id = markerId,
            coords = vector3(point.x, point.y, point.z),
            distance = 2.0,
            marker = 21,
            label = 'Press ~INPUT_CONTEXT~ to collect evidence',
            canInteract = function() return State.Can('actions.evidence') end,
            onSelect = function()
                local timings = (Config.Federal or {}).timings or {}
                -- Lifting a print off a bad surface can fail; the marker is
                -- only removed once the work is actually done, so a fumble
                -- leaves the evidence there to try again.
                if not Federal.Progress.Attempt({
                    label = 'Collecting evidence',
                    duration = timings.collectEvidence or 5000,
                    animation = 'collect',
                    skill = kind == 'print' and { 'easy', 'medium' } or nil,
                    failure = 'You disturbed it. Try again.'
                }) then return end

                DAG.Interactions.Remove(markerId)
                Bridge.TriggerCallback(Federal.Net('cad:collect'), function(record)
                    if record then
                        Bridge.Notify(('Collected %s (%s).'):format(record.label, record.number), 'success')
                    end
                end, {
                    kind = kind,
                    calloutId = callout.id,
                    location = point,
                    subject = callout.suspect and callout.suspect.identifier or nil
                })
            end
        })

        scene.interactions[#scene.interactions + 1] = markerId
    end
end

-- One scene witness, separately stageable so the watchdog can bring back a
-- witness the world lost - or whose model never loaded - without touching
-- the suspect. A template typo in the model list must not cost the scene
-- its witness, so unknown models fall back to a stock one.
local function spawnWitness(callout, index)
    local models = (callout.witnesses and callout.witnesses.models and #callout.witnesses.models > 0)
        and callout.witnesses.models or { 'a_m_y_business_01' }
    local model = models[((index - 1) % #models) + 1]
    if not IsModelInCdimage(GetHashKey(model)) then model = 'a_m_y_business_01' end

    local point = {
        x = callout.location.x - 2.0 - index,
        y = callout.location.y + 2.0,
        z = callout.location.z
    }
    local ped = spawnPed(model, point, 180.0, true)
    if not ped then return nil end

    scene.witnesses = scene.witnesses or {}
    scene.witnesses[index] = ped

    local witnessId = ('federal:callout:%s:witness:%d'):format(callout.id, index)
    DAG.Interactions.Remove(witnessId)
    DAG.Interactions.Register({
        id = witnessId,
        coords = vector3(point.x, point.y, point.z),
        follow = ped,
        distance = 2.5,
        label = 'Press ~INPUT_CONTEXT~ to interview',
        onSelect = function() Callouts.Report(callout.id, 'interview') end
    })
    scene.interactions[#scene.interactions + 1] = witnessId
    return ped
end

-- Builds the scene. Only the host does this.
local function buildScene(callout)
    clearScene()
    scene.calloutId = callout.id

    scene.blip = Federal.Zones.AddBlip(callout.location, callout.label, callout.blip)
    if scene.blip then SetBlipRoute(scene.blip, true) end

    -- A real player suspect is already in the world; only an NPC needs one.
    if callout.suspect and callout.suspect.kind == 'npc' then
        local spawn = {
            x = callout.location.x + 2.0,
            y = callout.location.y + 1.0,
            z = callout.location.z
        }
        local ped = spawnPed(callout.suspect.model, spawn, 0.0, false)

        if ped then
            local state = Federal.Suspects.Attach(ped, callout.id)
            scene.suspect = ped

            local suspectId = ('federal:callout:%s:suspect'):format(callout.id)
            DAG.Interactions.Register({
                id = suspectId,
                -- Follows the ped rather than sitting where it spawned: a
                -- suspect who ran is not detained at their old position.
                coords = vector3(spawn.x, spawn.y, spawn.z),
                follow = ped,
                distance = 2.5,
                label = 'Press ~INPUT_CONTEXT~ to detain the suspect',
                canInteract = function()
                    if not State.Can('actions.detain') then return false end
                    -- Only once they have actually given up, been beaten, or
                    -- gone down. Walking up to a fleeing suspect and pressing
                    -- E is exactly what this replaces.
                    return state ~= nil and state.subdued == true
                end,
                onSelect = function()
                    local timings = (Config.Federal or {}).timings or {}
                    if not Federal.Progress.Run({
                        label = 'Detaining suspect',
                        duration = timings.cuff or 2500,
                        animation = 'frisk'
                    }) then return end

                    Federal.Suspects.Subdue(state)
                    Callouts.Report(callout.id, 'arrest')
                end
            })
            scene.interactions[#scene.interactions + 1] = suspectId
        end
    end

    local witnesses = (callout.witnesses and callout.witnesses.count) or 0
    for index = 1, witnesses do
        spawnWitness(callout, index)
    end

    placeEvidence(callout)
end

-- The host builds the scene, but never from across the map: peds created in
-- unloaded world space fail to spawn or get culled, which is how a
-- responder used to arrive at an empty scene. A far-away host gets the blip
-- and route immediately, and the scene itself goes live on approach.
local pendingSceneId = nil

local function tryBuildScene(callout)
    if type(callout.location) ~= 'table' then return end
    local location = vector3(callout.location.x, callout.location.y, callout.location.z)
    local distance = #(GetEntityCoords(PlayerPedId()) - location)

    if distance <= 120.0 then
        pendingSceneId = nil
        buildScene(callout)
        return
    end

    pendingSceneId = callout.id
    clearScene()
    scene.blip = Federal.Zones.AddBlip(callout.location, callout.label, callout.blip)
    if scene.blip then SetBlipRoute(scene.blip, true) end
    Bridge.Notify('Scene marked on your map - it goes live as you arrive.', 'inform', 6000)
end

-- One watchdog owns scene liveness for the host: it builds the pending
-- scene on arrival, and REBUILDS when every actor is gone - which is what
-- a build that fired before the area streamed in, or a world cull, leaves
-- behind. A partial cast (an arrested suspect, say) is left alone.
local sceneAttempts = {}

CreateThread(function()
    while true do
        Wait(2000)
        local me = GetPlayerServerId(PlayerId())
        local hosting
        for _, callout in pairs(known) do
            if callout.host == me and callout.status ~= 'closed' and type(callout.location) == 'table' then
                hosting = callout
                break
            end
        end

        if hosting then
            local location = vector3(hosting.location.x, hosting.location.y, hosting.location.z)
            if #(GetEntityCoords(PlayerPedId()) - location) <= 120.0 then
                local needsBuild = scene.calloutId ~= hosting.id

                if not needsBuild then
                    local expected = ((hosting.suspect and hosting.suspect.kind == 'npc') and 1 or 0)
                        + ((hosting.witnesses and hosting.witnesses.count) or 0)
                    if expected > 0 then
                        local alive = 0
                        for _, ped in ipairs(scene.peds) do
                            if DoesEntityExist(ped) then alive = alive + 1 end
                        end
                        if alive > 0 then sceneAttempts[hosting.id] = nil end
                        needsBuild = alive == 0
                    end

                    -- Individual witnesses: restage any single one the world
                    -- lost (or whose spawn failed), without a full rebuild.
                    if not needsBuild then
                        for index = 1, ((hosting.witnesses and hosting.witnesses.count) or 0) do
                            local witness = scene.witnesses and scene.witnesses[index]
                            if not witness or not DoesEntityExist(witness) then
                                local attemptKey = hosting.id .. ':w' .. index
                                local tries = (sceneAttempts[attemptKey] or 0) + 1
                                sceneAttempts[attemptKey] = tries
                                if tries <= 4 then spawnWitness(hosting, index) end
                            end
                        end
                    end
                end

                if needsBuild then
                    local attempts = (sceneAttempts[hosting.id] or 0) + 1
                    sceneAttempts[hosting.id] = attempts
                    if attempts <= 4 then
                        local arriving = pendingSceneId == hosting.id
                        pendingSceneId = nil
                        buildScene(hosting)
                        if arriving then Bridge.Notify('You are on scene.', 'inform') end
                    elseif attempts == 5 then
                        Bridge.Notify('The scene actors will not stage here - the location may be obstructed.', 'error', 8000)
                    end
                end
            end
        end
    end
end)

-- 'Arrive' objectives complete themselves: standing at the scene IS the
-- report. Requiring a menu click to say "I am here" soft-locked every
-- responder who reasonably went straight for the witness instead. Perimeter
-- stages (arrive + deployed cordon) legitimately refuse until the cones are
-- out, so attempts RETRY on a slow beat rather than firing once.
local arriveAttempts = {}

CreateThread(function()
    while true do
        Wait(1500)
        local me = GetPlayerServerId(PlayerId())
        for _, callout in pairs(known) do
            if callout.status ~= 'closed' and type(callout.location) == 'table' then
                local assigned = false
                for _, source in ipairs(callout.assigned or {}) do
                    if source == me then assigned = true break end
                end

                local stage = assigned and callout.stages and callout.stages[callout.stage] or nil
                if stage and stage.kind == 'arrive' then
                    local reportKey = ('%s:%s'):format(callout.id, tostring(callout.stage))
                    local lastTry = arriveAttempts[reportKey] or 0
                    if GetGameTimer() - lastTry >= 8000 then
                        local location = vector3(callout.location.x, callout.location.y, callout.location.z)
                        if #(GetEntityCoords(PlayerPedId()) - location) <= ((tonumber(stage.radius) or 25.0) + 5.0) then
                            arriveAttempts[reportKey] = GetGameTimer()
                            Callouts.Report(callout.id, stage.id)
                        end
                    end
                end
            end
        end
    end
end)

-- Progress ---------------------------------------------------------------------------

function Callouts.Report(calloutId, stageId)
    Bridge.TriggerCallback(Federal.Net('callout:progress'), function(result)
        if result then Callouts.Track(result) end
    end, calloutId, stageId)
end

function Callouts.Track(callout)
    if type(callout) ~= 'table' then return end
    known[callout.id] = callout

    if callout.host == GetPlayerServerId(PlayerId())
        and scene.calloutId ~= callout.id and pendingSceneId ~= callout.id then
        tryBuildScene(callout)
    end

    -- The HUD is the persistent copy of this; the notification is just the
    -- nudge that it changed.
    local me = GetPlayerServerId(PlayerId())
    local assigned = false
    for _, source in ipairs(callout.assigned or {}) do
        if source == me then assigned = true end
    end
    if assigned then Federal.Hud.SetCallout(callout) end

    local stage = callout.stages and callout.stages[callout.stage]
    if stage then Bridge.Notify(('Objective: %s'):format(stage.label), 'inform') end
end

-- Menus ---------------------------------------------------------------------------------

-- Pulling your own work: pick a template (or roll the dice) and the server
-- dispatches it, bypassing the automatic population gate. Rate limited
-- server-side so it cannot be spammed.
function Callouts.Request()
    Bridge.TriggerCallback(Federal.Net('callout:templates'), function(templates)
        local options = { {
            title = 'Surprise me',
            description = 'A random case from your agency\'s catalog',
            icon = 'info',
            onSelect = function()
                Bridge.TriggerCallback(Federal.Net('callout:force'), function(callout)
                    if callout then Callouts.Menu() end
                end, nil)
            end
        } }

        for _, template in ipairs(templates or {}) do
            options[#options + 1] = {
                title = template.label,
                description = template.description,
                icon = 'chevron',
                badge = ('P%d'):format(template.priority or 2),
                badgeTone = (template.priority or 2) == 1 and 'danger' or nil,
                onSelect = function()
                    Bridge.TriggerCallback(Federal.Net('callout:force'), function(callout)
                        if callout then Callouts.Menu() end
                    end, template.id)
                end
            }
        end

        Federal.CAD.Show(id('request'), 'Request a callout', 'Dispatches to your whole agency', options)
    end)
end

function Callouts.Menu()
    Bridge.TriggerCallback(Federal.Net('callouts'), function(list)
        local options = {}
        for _, callout in ipairs(list or {}) do
            known[callout.id] = callout
            local stage = callout.stages and callout.stages[callout.stage]
            options[#options + 1] = {
                title = callout.label,
                description = stage and stage.label or 'Complete',
                icon = 'info',
                badge = callout.number,
                badgeTone = callout.priority >= 3 and 'danger' or 'accent',
                onSelect = function() Callouts.Detail(callout.id) end
            }
        end

        options[#options + 1] = { title = 'Dispatch', header = true }
        options[#options + 1] = {
            title = 'Request a callout',
            description = 'Pull a case now, whatever the automatic gate says',
            icon = 'check',
            onSelect = Callouts.Request
        }

        Federal.CAD.Show(id('list'), 'Active callouts', ('%d running'):format(#(list or {})), options)
    end)
end

function Callouts.Detail(calloutId)
    local callout = known[calloutId]
    if not callout then return Bridge.Notify('That callout is no longer active.', 'error') end

    local me = GetPlayerServerId(PlayerId())
    local assigned = false
    for _, source in ipairs(callout.assigned or {}) do
        if source == me then assigned = true end
    end

    local options = {
        { title = callout.number, description = callout.description, disabled = true },
        { title = 'Objectives', header = true }
    }

    for index, stage in ipairs(callout.stages or {}) do
        local done = index < callout.stage
        options[#options + 1] = {
            title = stage.label,
            icon = done and 'check' or 'chevron',
            badge = done and 'Done' or (index == callout.stage and 'Current' or 'Pending'),
            badgeTone = done and 'success' or (index == callout.stage and 'accent' or nil),
            disabled = true
        }
    end

    if #(callout.leads or {}) > 0 then
        options[#options + 1] = { title = 'Leads', header = true }
        for _, lead in ipairs(callout.leads) do
            options[#options + 1] = {
                title = lead.summary or lead.kind,
                icon = 'info',
                badge = lead.number,
                disabled = true
            }
        end
    end

    options[#options + 1] = { title = 'Actions', header = true }
    options[#options + 1] = {
        title = 'Leads for this case',
        icon = 'info',
        badge = tostring(#(callout.leads or {})),
        onSelect = function() Federal.Leads.Open(calloutId) end
    }
    if not assigned then
        options[#options + 1] = {
            title = 'Attach to this callout',
            icon = 'check',
            onSelect = function()
                Bridge.TriggerCallback(Federal.Net('callout:attach'), function(result, err)
                    if not result then return Bridge.Notify(err or 'Refused.', 'error') end
                    Callouts.Track(result)
                end, calloutId)
            end
        }
    else
        local stage = callout.stages and callout.stages[callout.stage]
        if stage then
            options[#options + 1] = {
                title = ('Report: %s'):format(stage.label),
                description = 'The server checks this before accepting it',
                icon = 'check',
                onSelect = function() Callouts.Report(calloutId, stage.id) end
            }
        end
        options[#options + 1] = {
            title = 'Detach',
            icon = 'close',
            onSelect = function()
                TriggerServerEvent(Federal.Net('callout:detach'), calloutId)
                Federal.Hud.ClearCallout(calloutId)
                if scene.calloutId == calloutId then clearScene() end
            end
        }
    end

    if State.Can('callout.manage') then
        options[#options + 1] = {
            title = 'Cancel the callout',
            icon = 'close',
            badgeTone = 'danger',
            onSelect = function()
                DAG.Menu.Confirm('Cancel this callout?', callout.number, function(confirmed)
                    if confirmed then TriggerServerEvent(Federal.Net('callout:cancel'), calloutId) end
                end)
            end
        }
    end

    Federal.CAD.Show(id('detail'), callout.label, callout.number, options)
end

-- Events -----------------------------------------------------------------------------------

RegisterNetEvent(Federal.Net('callout:dispatch'), function(callout)
    if type(callout) ~= 'table' then return end
    known[callout.id] = callout
    Bridge.Notify(('%s: %s'):format(callout.number, callout.label), 'inform', 8000)
    PlaySoundFrontend(-1, 'Text_Arrive_Tone', 'Phone_SoundSet_Default', true)
end)

RegisterNetEvent(Federal.Net('callout:update'), function(callout)
    Callouts.Track(callout)
end)

RegisterNetEvent(Federal.Net('callout:closed'), function(callout)
    if type(callout) ~= 'table' then return end
    known[callout.id] = nil
    Federal.Hud.ClearCallout(callout.id)
    if scene.calloutId == callout.id then clearScene() end
    Bridge.Notify(('%s closed.'):format(callout.number), 'success')
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then clearScene() end
end)

return Callouts
