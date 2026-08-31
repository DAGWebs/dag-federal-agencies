-- LEO actions on the client: picking a target, playing the animations, and
-- holding the restraint state the server told this player they are under.
--
-- Nothing here decides anything. The client picks who you are pointing at and
-- asks; the server re-reads both positions and the officer's rank before it
-- agrees. The restraint loop below runs on the player being restrained, from
-- state the server pushed to them.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Const = Federal.Constants
local State = Federal.State
local Actions = {}
Federal.Actions = Actions

local restraint = { cuffed = false, arrested = false }
local escortedBy = nil

local CUFF_DICT = 'mp_arresting'
local CUFF_ANIM = 'idle'

-- Targeting ------------------------------------------------------------------

-- The closest other player within `limit`, as a server id. Returns nil rather
-- than a best guess when nobody is close enough.
function Actions.NearestPlayer(limit)
    local player = PlayerPedId()
    local origin = GetEntityCoords(player)
    local best, bestDistance

    for _, other in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(other)
        if ped ~= player and DoesEntityExist(ped) then
            local distance = #(origin - GetEntityCoords(ped))
            if distance <= (limit or 4.0) and (not bestDistance or distance < bestDistance) then
                best, bestDistance = other, distance
            end
        end
    end

    if not best then return nil end
    return GetPlayerServerId(best), bestDistance
end

-- The vehicle the player is looking at or standing beside, as a network id so
-- the server can resolve the same entity.
function Actions.NearestVehicle(limit)
    local ped = PlayerPedId()
    local origin = GetEntityCoords(ped)

    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then
        vehicle = GetClosestVehicle(origin.x, origin.y, origin.z, limit or 6.0, 0, 71)
    end
    if vehicle == 0 or not DoesEntityExist(vehicle) then return nil end

    return NetworkGetNetworkIdFromEntity(vehicle), vehicle
end

local function requireTarget()
    local target = Actions.NearestPlayer((Config.Federal or {}).actionDistance or 4.0)
    if not target then
        Bridge.Notify('Nobody is close enough.', 'error')
        return nil
    end
    return target
end

local function timing(name)
    return ((Config.Federal or {}).timings or {})[name] or 3000
end

-- Runs the bar, then re-checks the target is still there. A suspect who walked
-- off mid-search has not been searched, and the server would refuse anyway --
-- catching it here is what stops the officer getting a bare refusal instead of
-- an explanation.
local function timedOnTarget(target, label, animation, name)
    if timing(name) <= 0 then return true end
    if not Federal.Progress.Run({ label = label, duration = timing(name), animation = animation }) then
        return false
    end

    local still = Actions.NearestPlayer((Config.Federal or {}).actionDistance or 4.0)
    if still ~= target then
        Bridge.Notify('They moved away before you finished.', 'error')
        return false
    end
    return true
end

Actions.TimedOnTarget = timedOnTarget

Actions.RequireTarget = requireTarget

-- Restraint ---------------------------------------------------------------------

local function playCuffAnim()
    RequestAnimDict(CUFF_DICT)
    local deadline = GetGameTimer() + 2000
    while not HasAnimDictLoaded(CUFF_DICT) and GetGameTimer() < deadline do Wait(10) end
    if not HasAnimDictLoaded(CUFF_DICT) then return end
    TaskPlayAnim(PlayerPedId(), CUFF_DICT, CUFF_ANIM, 8.0, -8.0, -1, 49, 0, false, false, false)
end

function Actions.Restrained()
    return restraint.cuffed == true
end

local function applyRestraint(state)
    restraint = type(state) == 'table' and state or { cuffed = false }
    local ped = PlayerPedId()

    if restraint.cuffed then
        SetEnableHandcuffs(ped, true)
        playCuffAnim()
    else
        SetEnableHandcuffs(ped, false)
        ClearPedTasks(ped)
        escortedBy = nil
    end
end

RegisterNetEvent(Federal.Net('restraint'), function(state)
    applyRestraint(state)
    if Federal.Hud then Federal.Hud.Refresh() end
end)

RegisterNetEvent(Federal.Net('escort'), function(officer)
    escortedBy = officer
    local ped = PlayerPedId()
    if not officer then return DetachEntity(ped, true, false) end

    local escortPed = GetPlayerPed(GetPlayerFromServerId(officer))
    if escortPed and escortPed ~= 0 then
        AttachEntityToEntity(ped, escortPed, 11816, 0.54, 0.54, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true)
    end
end)

RegisterNetEvent(Federal.Net('seat'), function(netId)
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end

    DetachEntity(PlayerPedId(), true, false)
    -- Rear seats first: a detainee does not ride shotgun.
    for seat = 1, 3 do
        if IsVehicleSeatFree(vehicle, seat) then
            return SetPedIntoVehicle(PlayerPedId(), vehicle, seat)
        end
    end
end)

-- A restrained player keeps their hands cuffed and cannot drive, shoot or
-- punch their way out. The loop only runs while they are actually restrained.
CreateThread(function()
    while true do
        local sleep = 500
        if restraint.cuffed then
            sleep = 0
            local ped = PlayerPedId()
            DisableControlAction(0, 24, true)   -- attack
            DisableControlAction(0, 25, true)   -- aim
            DisableControlAction(0, 45, true)   -- reload
            DisableControlAction(0, 22, true)   -- jump
            DisableControlAction(0, 21, true)   -- sprint
            DisableControlAction(0, 75, true)   -- exit vehicle
            if not IsEntityPlayingAnim(ped, CUFF_DICT, CUFF_ANIM, 3) and not escortedBy then
                playCuffAnim()
            end
        end
        Wait(sleep)
    end
end)

-- Action helpers ------------------------------------------------------------------

function Actions.Cuff()
    local target = requireTarget()
    if not target then return end

    -- Uncuffing is instant; putting them on is not.
    if not Federal.Progress.Run({ label = 'Restraining subject', duration = timing('cuff'), animation = 'frisk' }) then
        return
    end
    TriggerServerEvent(Federal.Net('action:cuff'), target)
end

function Actions.Escort()
    local target = requireTarget()
    if target then TriggerServerEvent(Federal.Net('action:escort'), target) end
end

function Actions.Seat()
    local target = requireTarget()
    if not target then return end

    local netId = Actions.NearestVehicle(8.0)
    if not netId then return Bridge.Notify('No vehicle nearby.', 'error') end
    TriggerServerEvent(Federal.Net('action:seat'), target, netId)
end

function Actions.Release()
    local target = requireTarget()
    if target then TriggerServerEvent(Federal.Net('action:release'), target) end
end

-- Renders a search report as a menu so the officer can read what was found
-- rather than watching notifications scroll past.
function Actions.ShowSearch(report)
    local options = {}
    if #report.found == 0 then
        options[1] = { title = 'Nothing found', description = 'The subject is carrying no listed contraband.', disabled = true }
    else
        options[#options + 1] = { title = 'Contraband', header = true }
        for _, entry in ipairs(report.found) do
            local seized = false
            for _, taken in ipairs(report.seized) do
                if taken.item == entry.item then seized = true end
            end
            options[#options + 1] = {
                title = entry.item,
                description = seized and 'Seized and logged as evidence' or 'Left with the subject',
                badge = ('x%d'):format(entry.count),
                badgeTone = seized and 'danger' or 'accent',
                disabled = true
            }
        end
    end

    DAG.Menu.Register({
        id = Federal.Menus.Id('search'),
        title = ('Search: %s'):format(report.name or 'subject'),
        subtitle = #report.evidence > 0 and ('%d item(s) filed as evidence'):format(#report.evidence) or nil,
        options = options
    })
    DAG.Menu.Open(Federal.Menus.Id('search'))
end

function Actions.Search()
    local target = requireTarget()
    if not target then return end

    if not timedOnTarget(target, 'Searching subject', 'search', 'search') then return end

    Bridge.TriggerCallback(Federal.Net('action:search'), function(report, err)
        if not report then return Bridge.Notify(err or 'The search was refused.', 'error') end
        Actions.ShowSearch(report)
    end, target)
end

function Actions.SearchVehicle()
    local netId = Actions.NearestVehicle(8.0)
    if not netId then return Bridge.Notify('No vehicle nearby.', 'error') end
    if not Federal.Progress.Run({ label = 'Searching vehicle', duration = timing('search'), animation = 'search' }) then
        return
    end

    Bridge.TriggerCallback(Federal.Net('action:searchVehicle'), function(result, err)
        if not result then return Bridge.Notify(err or 'The search was refused.', 'error') end

        local options = {}
        if #result.occupants == 0 then
            options[1] = { title = 'Vehicle is empty', description = 'Nobody was inside to search.', disabled = true }
        end
        for _, report in ipairs(result.occupants) do
            options[#options + 1] = {
                title = report.name or 'Occupant',
                description = #report.found > 0 and ('%d contraband item(s)'):format(#report.found) or 'Nothing found',
                badge = #report.found > 0 and 'HIT' or 'CLEAR',
                badgeTone = #report.found > 0 and 'danger' or 'success',
                onSelect = function() Actions.ShowSearch(report) end
            }
        end

        DAG.Menu.Register({
            id = Federal.Menus.Id('vehicleSearch'),
            title = 'Vehicle search',
            subtitle = 'Occupants searched',
            options = options
        })
        DAG.Menu.Open(Federal.Menus.Id('vehicleSearch'))
    end, netId)
end

function Actions.Identify()
    local target = requireTarget()
    if not target then return end

    Bridge.TriggerCallback(Federal.Net('action:identify'), function(result, err)
        if not result then return Bridge.Notify(err or 'Identification was refused.', 'error') end

        local options = {
            { title = result.name or 'Unknown', description = result.identifier, disabled = true }
        }
        if result.warrant then
            options[#options + 1] = {
                title = 'ACTIVE WARRANT',
                description = result.warrant.reason,
                badge = result.warrant.number,
                badgeTone = 'danger',
                disabled = true
            }
        end
        if result.record then
            options[#options + 1] = {
                title = 'Prior arrests',
                badge = tostring(#(result.record.arrests or {})),
                disabled = true
            }
            options[#options + 1] = {
                title = 'Fingerprints on file',
                badge = result.record.printed and 'Yes' or 'No',
                badgeTone = result.record.printed and 'success' or nil,
                disabled = true
            }
        else
            options[#options + 1] = { title = 'No record on file', disabled = true }
        end

        DAG.Menu.Register({
            id = Federal.Menus.Id('identify'),
            title = 'Identification',
            options = options
        })
        DAG.Menu.Open(Federal.Menus.Id('identify'))
    end, target)
end

function Actions.Fingerprint()
    local target = requireTarget()
    if not target then return end

    if not timedOnTarget(target, 'Taking fingerprints', 'fingerprint', 'fingerprint') then return end

    Bridge.TriggerCallback(Federal.Net('action:fingerprint'), function(result, err)
        Bridge.Notify(result and ('%s is now on file.'):format(result.name) or (err or 'Refused.'),
            result and 'success' or 'error')
    end, target)
end

function Actions.Swab()
    local target = requireTarget()
    if not target then return end

    -- A swab can be botched: it is the one collection step where technique
    -- matters, and a fumbled sample is a real outcome.
    if not Federal.Progress.Attempt({
        label = 'Taking a DNA swab',
        duration = timing('swab'),
        animation = 'swab',
        skill = { 'easy', 'medium' },
        failure = 'You contaminated the sample.'
    }) then return end

    Bridge.TriggerCallback(Federal.Net('action:swab'), function(record, err)
        Bridge.Notify(record and ('Swab logged as %s.'):format(record.number) or (err or 'Refused.'),
            record and 'success' or 'error')
    end, target)
end

-- Investigation: interviewing the world -------------------------------------
--
-- Any NPC near a crime scene can be questioned. The server owns their
-- identity and what they say; this side finds the ped, holds them still,
-- and renders the conversation.

-- The closest human, non-player, living NPC.
function Actions.NearestNPC(limit)
    local player = PlayerPedId()
    local origin = GetEntityCoords(player)
    local best, bestDistance

    for _, ped in ipairs(GetGamePool('CPed')) do
        if ped ~= player and DoesEntityExist(ped) and not IsPedAPlayer(ped)
            and IsPedHuman(ped) and not IsPedDeadOrDying(ped, true) and not IsPedInAnyVehicle(ped, true) then
            local distance = #(origin - GetEntityCoords(ped))
            if distance <= (limit or 3.0) and (not bestDistance or distance < bestDistance) then
                best, bestDistance = ped, distance
            end
        end
    end
    return best
end

-- A stable key per ped for the session, so re-interviewing the same person
-- gets the same identity back from the server.
local npcKeys = {}
local npcKeySequence = 0

local function npcKey(ped)
    if not npcKeys[ped] then
        npcKeySequence = npcKeySequence + 1
        npcKeys[ped] = ('npc%d-%d'):format(GetGameTimer() % 100000, npcKeySequence)
    end
    return npcKeys[ped]
end

-- Local physical state per ped: hands up, knocked down, cuffed. The server
-- owns identity and attitude; the body language lives here.
local npcState = {}

local function pedState(ped)
    npcState[ped] = npcState[ped] or {}
    return npcState[ped]
end

-- A hostile reaction from the server: make the ped act on it.
local function applyReaction(ped, reaction)
    if not reaction or not DoesEntityExist(ped) then return end
    SetBlockingOfNonTemporaryEvents(ped, false)
    ClearPedTasks(ped)
    if reaction == 'attack' then
        TaskCombatPed(ped, PlayerPedId(), 0, 16)
        Bridge.Notify('They turned on you!', 'error')
    else
        local coords = GetEntityCoords(ped)
        TaskSmartFleePed(ped, PlayerPedId(), 120.0, 20000, false, false)
        Bridge.Notify('They bolted!', 'error')
        coords = nil
    end
end

local function cuffPed(ped)
    local state = pedState(ped)
    ClearPedTasksImmediately(ped)
    SetBlockingOfNonTemporaryEvents(ped, true)
    RequestAnimDict('mp_arresting')
    local deadline = GetGameTimer() + 1500
    while not HasAnimDictLoaded('mp_arresting') and GetGameTimer() < deadline do Wait(10) end
    if HasAnimDictLoaded('mp_arresting') then
        TaskPlayAnim(ped, 'mp_arresting', 'idle', 8.0, -8.0, -1, 49, 0, false, false, false)
    end
    SetEnableHandcuffs(ped, true)
    state.cuffed = true
    state.hands = false
    Bridge.Notify('Subject cuffed.', 'success')
end

local function showInterview(ped, result)
    local state = pedState(ped)
    result = result or state.lastResult or { name = 'Subject', statement = '...' }
    state.lastResult = result
    local attitude = result.attitude or 0
    local mood = attitude >= 7 and 'Hostile' or attitude >= 4 and 'Agitated' or attitude >= 2 and 'Wary' or 'Cooperative'

    local options = {
        {
            title = result.name,
            description = ('DOB %s | %s'):format(result.dob or '?', result.identifier or ''),
            badge = mood,
            badgeTone = attitude >= 4 and 'danger' or (attitude >= 2 and 'accent' or 'success'),
            disabled = true
        },
        { title = 'Statement', description = result.statement, icon = 'info', disabled = true }
    }
    if result.caseNumber then
        options[#options + 1] = { title = ('Working case %s'):format(result.caseNumber), icon = 'info', disabled = true }
    end
    if result.lead then
        options[#options + 1] = { title = result.lead, icon = 'check', badge = 'Lead', badgeTone = 'success', disabled = true }
    end
    if result.line then
        options[#options + 1] = { title = 'Reaction', description = result.line, icon = 'info', disabled = true }
    end

    local key = npcKey(ped)
    local function approach(tone)
        Bridge.TriggerCallback(Federal.Net('investigate:approach'), function(response, err)
            if not response then return Bridge.Notify(err or 'No response.', 'error') end
            if response.reaction then
                DAG.Menu.Close()
                return applyReaction(ped, response.reaction)
            end
            result.attitude = response.attitude
            result.line = response.line
            showInterview(ped, result)
        end, key, tone)
    end

    options[#options + 1] = { title = 'Approach', header = true }
    options[#options + 1] = {
        title = 'Reassure them',
        description = 'Calm them down - cooperation improves',
        icon = 'check',
        onSelect = function() approach('calm') end
    }
    options[#options + 1] = {
        title = 'Lean on them',
        description = 'Pressure shakes details loose, and tempers fray',
        icon = 'info',
        badgeTone = 'danger',
        onSelect = function() approach('hard') end
    }
    options[#options + 1] = {
        title = 'Press for details',
        description = 'Push them on what else they saw',
        icon = 'info',
        onSelect = function() Actions.InterviewPed(ped, true) end
    }
    options[#options + 1] = {
        title = 'Take a formal statement',
        description = result.caseNumber and ('Files onto %s as a witness'):format(result.caseNumber)
            or 'Needs an open case scene nearby',
        icon = 'check',
        onSelect = function()
            Bridge.TriggerCallback(Federal.Net('investigate:statement'), function(filed, err)
                Bridge.Notify(filed
                    and ('%s is on %s as a witness; statement filed.'):format(filed.name, filed.caseNumber)
                    or (err or 'Refused.'), filed and 'success' or 'error', 8000)
            end, key)
        end
    }

    -- Enforcement: order, take down, cuff, book.
    if State.Can('actions.detain') or State.Can('actions.arrest') then
        options[#options + 1] = { title = 'Enforcement', header = true }
    end

    if State.Can('actions.arrest') and not state.cuffed and not state.hands and not state.subdued then
        options[#options + 1] = {
            title = 'Order: you are under arrest',
            description = 'Verbal command - a hostile subject may bolt or swing',
            icon = 'lock',
            onSelect = function()
                Bridge.TriggerCallback(Federal.Net('investigate:order'), function(response, err)
                    if not response then return Bridge.Notify(err or 'Refused.', 'error') end
                    result.attitude = response.attitude
                    result.line = response.line
                    if response.result == 'comply' then
                        ClearPedTasksImmediately(ped)
                        SetBlockingOfNonTemporaryEvents(ped, true)
                        TaskHandsUp(ped, 30000, PlayerPedId(), -1, true)
                        pedState(ped).hands = true
                        showInterview(ped, result)
                    else
                        DAG.Menu.Close()
                        applyReaction(ped, response.result)
                    end
                end, key)
            end
        }
    end

    if State.Can('actions.detain') and not state.cuffed and not state.subdued then
        options[#options + 1] = {
            title = 'Take them down',
            description = 'Physical takedown - knocks them out cold',
            icon = 'lock',
            badgeTone = 'danger',
            onSelect = function()
                DAG.Menu.Close()
                if #(GetEntityCoords(PlayerPedId()) - GetEntityCoords(ped)) > 2.5 then
                    return Bridge.Notify('Get closer first.', 'error')
                end
                if not Federal.Progress.Run({ label = 'Taking them down', duration = 900, animation = 'frisk' }) then return end
                SetBlockingOfNonTemporaryEvents(ped, true)
                ClearPedTasksImmediately(ped)
                SetPedToRagdoll(ped, 12000, 12000, 0, false, false, false)
                pedState(ped).subdued = true
                Bridge.Notify('Subject is down - cuff them.', 'success')
                SetTimeout(600, function() showInterview(ped) end)
            end
        }
    end

    if State.Can('actions.detain') and (state.hands or state.subdued) and not state.cuffed then
        options[#options + 1] = {
            title = 'Cuff them',
            icon = 'lock',
            onSelect = function()
                if not Federal.Progress.Run({ label = 'Applying cuffs', duration = 1800, animation = 'frisk' }) then return end
                cuffPed(ped)
                showInterview(ped)
            end
        }
    end

    if state.cuffed then
        if State.Can('actions.arrest') then
            options[#options + 1] = {
                title = 'Book the arrest',
                description = 'Files the arrest on their record (and the docket)',
                icon = 'lock',
                badgeTone = 'danger',
                onSelect = function()
                    local chargeOptions = {}
                    for _, charge in ipairs((Config.Federal or {}).charges or {}) do
                        chargeOptions[#chargeOptions + 1] = { value = charge, label = charge }
                    end
                    DAG.Menu.Input('Book the arrest', {
                        { name = 'charge', label = 'Primary charge', type = 'select', required = true,
                            options = chargeOptions, allowCustom = true },
                        { name = 'extra', label = 'Further charges (comma separated)' }
                    }, function(values)
                        if not values then return end
                        local charges = { values.charge }
                        for charge in tostring(values.extra or ''):gmatch('[^,]+') do
                            local trimmed = charge:gsub('^%s+', ''):gsub('%s+$', '')
                            if trimmed ~= '' then charges[#charges + 1] = trimmed end
                        end
                        Bridge.TriggerCallback(Federal.Net('investigate:arrestNpc'), function(booking, err)
                            Bridge.Notify(booking
                                and ('%s booked%s.'):format(booking.name,
                                    booking.caseNumber and (' - case %s filed'):format(booking.caseNumber) or '')
                                or (err or 'Refused.'), booking and 'success' or 'error', 9000)
                        end, key, charges)
                    end)
                end
            }
        end
        options[#options + 1] = {
            title = 'Seat them in the nearest vehicle',
            icon = 'car',
            onSelect = function()
                local _, vehicle = Actions.NearestVehicle(7.0)
                if not vehicle then return Bridge.Notify('No vehicle close enough.', 'error') end
                TaskEnterVehicle(ped, vehicle, 10000, 2, 1.0, 1, 0)
                SetTimeout(4000, function()
                    if DoesEntityExist(ped) and not IsPedInAnyVehicle(ped, false) then
                        TaskEnterVehicle(ped, vehicle, 10000, 1, 1.0, 1, 0)
                    end
                end)
            end
        }
        options[#options + 1] = {
            title = 'Release them',
            icon = 'close',
            onSelect = function()
                SetEnableHandcuffs(ped, false)
                ClearPedTasks(ped)
                SetBlockingOfNonTemporaryEvents(ped, false)
                TaskWanderStandard(ped, 10.0, 10)
                npcState[ped] = nil
                Bridge.Notify('Subject released.', 'inform')
            end
        }
    end

    DAG.Menu.Register({
        id = Federal.Menus.Id('interview'),
        title = 'Subject contact',
        subtitle = result.name,
        options = options
    })
    DAG.Menu.Open(Federal.Menus.Id('interview'))
end

function Actions.InterviewPed(ped, pressing)
    if not ped or not DoesEntityExist(ped) then
        return Bridge.Notify('They are gone.', 'error')
    end
    -- A ped mid-fight or mid-flight is not giving a statement.
    if IsPedInCombat(ped, PlayerPedId()) or IsPedFleeing(ped) then
        return Bridge.Notify('They are in no state to be interviewed - deal with them first.', 'error')
    end

    -- Hold the witness in place and face the officer: an interview, not a
    -- conversation shouted at a fleeing back. A subject already down, in
    -- cuffs or with their hands up keeps their pose.
    local held = npcState[ped]
    if not (held and (held.subdued or held.cuffed or held.hands)) then
        ClearPedTasksImmediately(ped)
        TaskTurnPedToFaceEntity(ped, PlayerPedId(), 1500)
        TaskStandStill(ped, 30000)
        SetBlockingOfNonTemporaryEvents(ped, true)
    end

    if not Federal.Progress.Run({
        label = pressing and 'Pressing the witness' or 'Interviewing the witness',
        duration = timing('interview') or 4000,
        animation = 'search'
    }) then
        SetBlockingOfNonTemporaryEvents(ped, false)
        return
    end

    Bridge.TriggerCallback(Federal.Net('investigate:interview'), function(result, err)
        if not result then
            SetBlockingOfNonTemporaryEvents(ped, false)
            return Bridge.Notify(err or 'They will not talk to you.', 'error')
        end
        showInterview(ped, result)
    end, npcKey(ped))
end

function Actions.Interview()
    local ped = Actions.NearestNPC(3.0)
    if not ped then
        return Bridge.Notify('Nobody is close enough to interview.', 'error')
    end
    Actions.InterviewPed(ped, false)
end

function Actions.ReviewCCTV()
    if not Federal.Progress.Run({
        label = 'Pulling the CCTV',
        duration = timing('cctv') or 8000,
        animation = 'search'
    }) then return end

    Bridge.TriggerCallback(Federal.Net('investigate:cctv'), function(result, err)
        if not result then return Bridge.Notify(err or 'No footage.', 'error') end
        Bridge.Notify(('%s %s%s'):format(
            result.summary,
            result.evidenceNumber and ('Filed as %s.'):format(result.evidenceNumber) or '',
            result.lead and (' ' .. result.lead) or ''), 'success', 12000)
    end)
end

-- Bagging evidence in the field: anywhere, not just a callout marker. Pick
-- what kind of item it is, describe it, kneel and seal it. The server spends
-- one evidence bag and hands back the sealed bag as an inventory item; it
-- stays in the officer's custody until checked into an evidence locker.
function Actions.BagEvidence()
    local options = {}
    for _, key in ipairs(Const.EvidenceKindOrder) do
        local kindKey = key
        local kind = Const.EvidenceKinds[key]
        options[#options + 1] = {
            title = kind.label,
            icon = 'box',
            onSelect = function()
                DAG.Menu.Input('Bag evidence', {
                    { name = 'label', label = 'What is it?', required = true },
                    { name = 'description', label = 'Condition / where found (optional)' },
                    { name = 'incident', label = 'Attach to incident id (optional)' }
                }, function(values)
                    if not values then return end

                    if not Federal.Progress.Run({
                        label = 'Bagging and sealing evidence',
                        duration = timing('collectEvidence'),
                        animation = 'collect'
                    }) then return end

                    local coords = GetEntityCoords(PlayerPedId())
                    Bridge.TriggerCallback(Federal.Net('cad:bag'), function(record, err)
                        Bridge.Notify(record
                            and ('Sealed as %s. Check it into an evidence locker.'):format(record.number)
                            or (err or 'Refused.'), record and 'success' or 'error', 8000)
                    end, {
                        kind = kindKey,
                        label = values.label or values[1],
                        description = values.description or values[2],
                        incidentId = values.incident or values[3],
                        location = { x = coords.x, y = coords.y, z = coords.z }
                    })
                end)
            end
        }
    end

    DAG.Menu.Register({
        id = Federal.Menus.Id('bagEvidence'),
        title = 'Bag evidence',
        subtitle = 'What are you sealing?',
        options = options
    })
    DAG.Menu.Open(Federal.Menus.Id('bagEvidence'))
end

function Actions.Arrest()
    local target = requireTarget()
    if not target then return end

    DAG.Menu.Input('Charges', {
        { name = 'charges', label = 'Charges (comma separated)', required = true },
        { name = 'incident', label = 'Attach to incident id (optional)' }
    }, function(values)
        if not values then return end

        local charges = {}
        for charge in tostring(values.charges or values[1] or ''):gmatch('[^,]+') do
            local trimmed = charge:gsub('^%s+', ''):gsub('%s+$', '')
            if trimmed ~= '' then charges[#charges + 1] = trimmed end
        end
        if #charges == 0 then return Bridge.Notify('No charges entered.', 'error') end

        Bridge.TriggerCallback(Federal.Net('action:arrest'), function(booking, err)
            if not booking then return Bridge.Notify(err or 'The arrest was refused.', 'error') end
            local suffix = booking.caseNumber and (' Case %s filed.'):format(booking.caseNumber) or ''
            Bridge.Notify(('%s booked.%s'):format(booking.name or 'Subject', suffix), 'success')
        end, target, { charges = charges, incidentId = values.incident or values[2] })
    end)
end

function Actions.Fine()
    local target = requireTarget()
    if not target then return end

    DAG.Menu.Input('Issue a fine', {
        { name = 'amount', label = 'Amount', type = 'number', required = true },
        { name = 'reason', label = 'Reason', required = true }
    }, function(values)
        if not values then return end
        TriggerServerEvent(Federal.Net('action:fine'), target,
            tonumber(values.amount or values[1]), values.reason or values[2])
    end)
end

function Actions.SetStatus(status)
    if not Const.UnitStatus[status] then return end
    TriggerServerEvent(Federal.Net('status'), status)
end

-- The action list, filtered to what this player's rank allows. Used by the
-- field menu and by the callout scene menu.
function Actions.Options()
    local options = {}
    local function add(permission, option)
        if State.Can(permission) then options[#options + 1] = option end
    end

    add('actions.detain', { title = 'Cuff / uncuff', icon = 'lock', onSelect = Actions.Cuff })
    add('actions.detain', { title = 'Escort / release hold', icon = 'user', onSelect = Actions.Escort })
    add('actions.detain', { title = 'Seat in vehicle', icon = 'car', onSelect = Actions.Seat })
    add('actions.search', { title = 'Search suspect', icon = 'box', onSelect = Actions.Search })
    add('actions.search', { title = 'Search vehicle', icon = 'car', onSelect = Actions.SearchVehicle })
    add('actions.search', { title = 'Identify subject', icon = 'info', onSelect = Actions.Identify })
    add('actions.search', { title = 'Interview witness (NPC)', icon = 'user', onSelect = Actions.Interview })
    add('actions.search', { title = 'Review scene CCTV', icon = 'info', onSelect = Actions.ReviewCCTV })
    add('actions.evidence', { title = 'Fingerprint subject', icon = 'user', onSelect = Actions.Fingerprint })
    add('actions.evidence', { title = 'Take DNA swab', icon = 'box', onSelect = Actions.Swab })
    add('actions.evidence', { title = 'Bag evidence', icon = 'box', onSelect = Actions.BagEvidence })
    add('actions.arrest', { title = 'Book arrest', icon = 'lock', badgeTone = 'danger', onSelect = Actions.Arrest })
    add('actions.arrest', { title = 'Issue fine', icon = 'cash', onSelect = Actions.Fine })
    add('actions.arrest', { title = 'Release subject', icon = 'check', onSelect = Actions.Release })

    return options
end

return Actions
