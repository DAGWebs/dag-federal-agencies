-- The courtroom on the client.
--
-- Courthouse blips and a door interaction come from the same registry the
-- server holds, so a courthouse placed with the in-game editor appears without
-- a reconnect. When a case is being heard, the roles nobody took are filled
-- with NPCs standing in the seats a player would have used, so the room looks
-- like a court whether six people turned up or nobody did.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Const = Federal.Constants
local Schema = Federal.Schema
local Court = {}
Federal.Court = Court

local houses, blips, interactions = {}, {}, {}
local room = { caseId = nil, peds = {} }

local function id(name)
    return Federal.Menus.Id('court:' .. name)
end

local function show(menuId, title, subtitle, options)
    Federal.CAD.Show(menuId, title, subtitle, options)
end

-- Courthouse world ----------------------------------------------------------------

local function clearRoom()
    for _, ped in ipairs(room.peds) do
        if DoesEntityExist(ped) then DeleteEntity(ped) end
    end
    room = { caseId = nil, peds = {} }
end

Court.ClearRoom = clearRoom

local function clearZones()
    for _, blip in ipairs(blips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    for _, interaction in ipairs(interactions) do DAG.Interactions.Remove(interaction) end
    blips, interactions = {}, {}
end

function Court.RebuildZones()
    clearZones()
    if (Config.Federal or {}).court == nil or Config.Federal.court.enabled == false then return end

    for _, house in ipairs(houses) do
        if (Config.Federal or {}).blips ~= false then
            local blip = Federal.Zones.AddBlip(house.coords, house.label, house.blip)
            if blip then blips[#blips + 1] = blip end
        end

        local doorId = ('federal:court:%s'):format(house.id)
        DAG.Interactions.Register({
            id = doorId,
            coords = vector3(house.coords.x, house.coords.y, house.coords.z),
            distance = 2.5,
            label = ('Press ~INPUT_CONTEXT~ for the %s'):format(house.label),
            onSelect = function() Court.Docket(house.id) end
        })
        interactions[#interactions + 1] = doorId
    end
end

function Court.Refresh(callback)
    Bridge.TriggerCallback(Federal.Net('court:courthouses'), function(list)
        houses = type(list) == 'table' and list or {}
        Court.RebuildZones()
        if callback then callback(houses) end
    end)
end

function Court.Houses()
    return houses
end

-- Populating the room --------------------------------------------------------------------

local function seatFor(house, role)
    local seatRole = Const.CourtRoles[role] and Const.CourtRoles[role].seat or role
    return Schema.SeatsFor(house, seatRole)
end

-- Spawns an NPC into a named seat and sits it down.
local function seatNpc(model, seat)
    if not seat then return nil end
    local ped = Federal.Callouts.SpawnPed(model, seat.coords, seat.heading, true)
    if not ped then return nil end

    ClearPedTasks(ped)
    TaskStartScenarioInPlace(ped, 'PROP_HUMAN_SEAT_CHAIR_MP_PLAYER', 0, true)
    room.peds[#room.peds + 1] = ped
    return ped
end

-- Fills the courtroom for a case: an NPC for every role that no player took.
function Court.Populate(case)
    if type(case) ~= 'table' then return end
    local house = nil
    for _, candidate in ipairs(houses) do
        if candidate.id == case.courthouse then house = candidate end
    end
    if not house then return end

    clearRoom()
    room.caseId = case.id

    local models = ((Config.Federal or {}).court or {}).npcModels or {}

    for _, role in ipairs({ 'judge', 'prosecutor', 'defense' }) do
        local holder = case.roles and case.roles[role]
        if holder and holder.npc == true then
            local seats = seatFor(house, role)
            seatNpc(holder.model or models[role] or 's_m_m_highsec_01', seats[1])
        end
    end

    local jurySeats = Schema.SeatsFor(house, 'jury')
    for index, juror in ipairs(case.roles and case.roles.jurors or {}) do
        if juror.npc == true then
            local model = juror.model
            if not model then
                local pool = models.juror or { 'a_m_m_business_01' }
                model = pool[((index - 1) % #pool) + 1]
            end
            seatNpc(model, jurySeats[index])
        end
    end
end

-- Menus ------------------------------------------------------------------------------------

local function stamp(seconds)
    if type(seconds) ~= 'number' then return '' end
    return os.date('%d %b %H:%M', seconds)
end

local STAGE_LABEL = {
    filed = 'Filed',
    arraignment = 'Arraignment',
    trial = 'At trial',
    deliberation = 'Jury deliberating',
    verdict = 'Verdict returned',
    closed = 'Closed'
}

function Court.Docket(courthouseId)
    Bridge.TriggerCallback(Federal.Net('court:docket'), function(list)
        local options = {}
        for _, case in ipairs(list or {}) do
            options[#options + 1] = {
                title = case.defendant and case.defendant.name or 'Unknown defendant',
                description = ('%s | %s'):format(case.number, table.concat(case.charges or {}, ', ')),
                icon = 'box',
                badge = STAGE_LABEL[case.stage] or case.stage,
                badgeTone = case.stage == 'closed' and 'success' or 'accent',
                onSelect = function() Court.Case(case.id) end
            }
        end

        if #options == 0 then
            options[1] = { title = 'The docket is empty', disabled = true }
        end

        options[#options + 1] = { title = 'Actions', header = true }
        options[#options + 1] = { title = 'File a case', icon = 'check', onSelect = Court.File }

        show(id('docket'), 'Court docket', ('%d case(s)'):format(#(list or {})), options)
    end, { courthouse = courthouseId })
end

local function roleRow(case, role, holder)
    local detail = Const.CourtRoles[role]
    return {
        title = detail and detail.label or role,
        description = holder and holder.name or 'Vacant',
        icon = 'user',
        badge = holder and (holder.npc and 'Court-appointed' or 'Player') or 'Open',
        badgeTone = holder and (holder.npc and nil or 'success') or 'accent',
        onSelect = function()
            if holder and holder.npc ~= true then return end
            TriggerServerEvent(Federal.Net('court:take'), case.id, role)
            Court.Case(case.id)
        end
    }
end

function Court.Case(caseId)
    Bridge.TriggerCallback(Federal.Net('court:case'), function(case)
        if not case then return Bridge.Notify('That case is not on the docket.', 'error') end
        Court.Populate(case)

        local options = {
            { title = case.number, description = case.defendant and case.defendant.name or '', disabled = true },
            { title = ('Stage: %s'):format(STAGE_LABEL[case.stage] or case.stage), disabled = true }
        }

        if case.plea then
            options[#options + 1] = { title = ('Plea: %s'):format((case.plea):gsub('_', ' ')), disabled = true }
        end
        if case.verdict then
            options[#options + 1] = {
                title = ('Verdict: %s'):format((case.verdict):gsub('_', ' ')),
                badgeTone = case.verdict == 'guilty' and 'danger' or 'success',
                disabled = true
            }
        end
        if case.sentence then
            options[#options + 1] = {
                title = ('Sentence: %d months, $%d'):format(case.sentence.months, case.sentence.fine),
                description = ('Passed by %s'):format(case.sentence.by or 'the court'),
                disabled = true
            }
        end

        options[#options + 1] = { title = 'Charges', header = true }
        for _, charge in ipairs(case.charges or {}) do
            options[#options + 1] = { title = charge, disabled = true }
        end

        options[#options + 1] = { title = 'Roles', header = true }
        for _, role in ipairs({ 'judge', 'prosecutor', 'defense', 'bailiff' }) do
            options[#options + 1] = roleRow(case, role, case.roles and case.roles[role])
        end

        local jurors = case.roles and case.roles.jurors or {}
        options[#options + 1] = {
            title = 'Jury',
            description = 'Take a seat in the jury box',
            icon = 'user',
            badge = ('%d seated'):format(#jurors),
            onSelect = function()
                TriggerServerEvent(Federal.Net('court:take'), case.id, 'juror')
                Court.Case(case.id)
            end
        }

        if case.transcript then
            options[#options + 1] = { title = 'Proceedings', header = true }
            for _, entry in ipairs(case.transcript) do
                options[#options + 1] = {
                    title = ('%s (%s)'):format(entry.actor, entry.role),
                    description = entry.text,
                    badge = stamp(entry.at),
                    disabled = true
                }
            end
        end

        options[#options + 1] = { title = 'Actions', header = true }
        for _, option in ipairs(Court.Actions(case)) do options[#options + 1] = option end

        show(id('case'), case.number, case.defendant and case.defendant.name or nil, options)
    end, caseId)
end

-- What this player can do in this case right now.
function Court.Actions(case)
    local options = {}
    if case.stage == 'closed' then return options end

    if case.stage == 'arraignment' and not case.plea then
        for _, plea in ipairs(Const.Pleas) do
            options[#options + 1] = {
                title = ('Plead %s'):format((plea:gsub('_', ' '))),
                icon = 'check',
                onSelect = function()
                    TriggerServerEvent(Federal.Net('court:plea'), case.id, plea)
                    Court.Case(case.id)
                end
            }
        end
    end

    if case.stage == 'trial' then
        options[#options + 1] = {
            title = 'Give a statement',
            icon = 'info',
            onSelect = function()
                DAG.Menu.Input('Statement', { { name = 'text', label = 'What do you say?', required = true } },
                    function(values)
                        if not values then return end
                        TriggerServerEvent(Federal.Net('court:testify'), case.id, values.text or values[1])
                        Court.Case(case.id)
                    end)
            end
        }
    end

    if case.stage ~= 'deliberation' and case.stage ~= 'verdict' then
        options[#options + 1] = {
            title = 'Admit evidence',
            icon = 'box',
            onSelect = function()
                DAG.Menu.Input('Admit evidence', { { name = 'evidence', label = 'Evidence id', required = true } },
                    function(values)
                        if not values then return end
                        TriggerServerEvent(Federal.Net('court:admit'), case.id, values.evidence or values[1])
                        Court.Case(case.id)
                    end)
            end
        }
    end

    if case.stage == 'deliberation' then
        options[#options + 1] = {
            title = 'Vote: guilty',
            icon = 'lock',
            badgeTone = 'danger',
            onSelect = function()
                TriggerServerEvent(Federal.Net('court:vote'), case.id, true)
                Court.Case(case.id)
            end
        }
        options[#options + 1] = {
            title = 'Vote: not guilty',
            icon = 'check',
            badgeTone = 'success',
            onSelect = function()
                TriggerServerEvent(Federal.Net('court:vote'), case.id, false)
                Court.Case(case.id)
            end
        }
    end

    -- Presiding actions. The server refuses these from anyone who is not the
    -- judge, so showing them costs nothing but a refusal.
    if case.stage == 'verdict' and case.verdict == 'guilty' then
        options[#options + 1] = {
            title = 'Pass sentence',
            icon = 'wrench',
            onSelect = function()
                DAG.Menu.Input('Sentence', {
                    { name = 'months', label = 'Months', type = 'number' },
                    { name = 'fine', label = 'Fine', type = 'number' }
                }, function(values)
                    if not values then return end
                    TriggerServerEvent(Federal.Net('court:sentence'), case.id,
                        tonumber(values.months or values[1]), tonumber(values.fine or values[2]))
                    Court.Case(case.id)
                end)
            end
        }
    else
        options[#options + 1] = {
            title = 'Move the case on',
            description = 'Presiding judge only',
            icon = 'chevron',
            onSelect = function()
                TriggerServerEvent(Federal.Net('court:advance'), case.id)
                Court.Case(case.id)
            end
        }
    end

    options[#options + 1] = {
        title = 'Stand down from your role',
        icon = 'close',
        onSelect = function()
            DAG.Menu.Input('Stand down', { { name = 'role', label = 'Role to leave', required = true } },
                function(values)
                    if not values then return end
                    TriggerServerEvent(Federal.Net('court:leave'), case.id, values.role or values[1])
                    Court.Case(case.id)
                end)
        end
    }

    return options
end

function Court.File()
    DAG.Menu.Input('File a case', {
        { name = 'identifier', label = 'Defendant identifier', required = true },
        { name = 'name', label = 'Defendant name' },
        { name = 'charges', label = 'Charges (comma separated)', required = true }
    }, function(values)
        if not values then return end

        local charges = {}
        for charge in tostring(values.charges or values[3] or ''):gmatch('[^,]+') do
            local trimmed = charge:gsub('^%s+', ''):gsub('%s+$', '')
            if trimmed ~= '' then charges[#charges + 1] = trimmed end
        end

        Bridge.TriggerCallback(Federal.Net('court:file'), function(case, err)
            if not case then return Bridge.Notify(err or 'The filing was refused.', 'error') end
            Bridge.Notify(('Case %s filed.'):format(case.number), 'success')
            Court.Case(case.id)
        end, {
            identifier = values.identifier or values[1],
            name = values.name or values[2],
            charges = charges
        })
    end)
end

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        clearRoom()
        clearZones()
    end
end)

return Court
