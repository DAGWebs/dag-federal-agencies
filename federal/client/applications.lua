-- Client side of agency applications.
--
-- Renders every agency's application desks for EVERYONE (a desk nobody can
-- find recruits nobody), walks an applicant through the agency's custom form
-- in the input dialog, and gives reviewers the approve/deny screens the boss
-- menu opens. All decisions and validations live on the server.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local State = Federal.State

local Applications = {}
Federal.ApplicationsUI = Applications

local places = {}
local blips = {}
local interactions = {}

local function clearWorld()
    for _, blip in ipairs(blips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    blips = {}
    for _, id in ipairs(interactions) do DAG.Interactions.Remove(id) end
    interactions = {}
end

-- Filling in the form: fetch the questions, render them as one dialog, post
-- the answers back by position.
local function apply(place)
    Bridge.TriggerCallback(Federal.Net('apps:questions'), function(form, err)
        if not form then return Bridge.Notify(err or 'They are not taking applications.', 'error') end

        local fields = {}
        for index, question in ipairs(form.questions or {}) do
            fields[#fields + 1] = {
                name = ('q%d'):format(index),
                label = question.label,
                required = question.required == true
            }
        end
        if #fields == 0 then
            fields[1] = { name = 'q1', label = 'Why do you want to join?', required = true }
        end

        DAG.Menu.Input(form.title or 'Application', fields, function(values)
            if not values then return end
            local answers = {}
            for index = 1, #fields do
                answers[index] = values[('q%d'):format(index)] or ''
            end
            TriggerServerEvent(Federal.Net('apps:submit'), place.agency, answers)
        end)
    end, place.agency)
end

local function rebuild(list)
    places = type(list) == 'table' and list or {}
    clearWorld()

    local membership = State.Membership()
    for _, place in ipairs(places) do
        if type(place.coords) == 'table' then
            -- Your own agency's recruitment desk is not for you: no blip on a
            -- member's map. Everyone else - including members of the OTHER
            -- agencies - still sees it.
            if not membership or membership.agencyId ~= place.agency then
                local blip = AddBlipForCoord(place.coords.x, place.coords.y, place.coords.z)
                SetBlipSprite(blip, 1)
                SetBlipColour(blip, place.color or 26)
                SetBlipScale(blip, 0.65)
                SetBlipAsShortRange(blip, true)
                BeginTextCommandSetBlipName('STRING')
                AddTextComponentString(('%s Recruitment'):format(place.short or 'FED'))
                EndTextCommandSetBlipName(blip)
                blips[#blips + 1] = blip
            end

            local id = ('federal-apply:%s:%s'):format(place.agency, place.id)
            DAG.Interactions.Register({
                id = id,
                coords = vector3(place.coords.x, place.coords.y, place.coords.z),
                distance = 2.0,
                label = ('Press ~INPUT_CONTEXT~ to apply to the %s'):format(place.short or 'agency'),
                canInteract = function()
                    -- Members of the agency do not apply to it; everyone else may.
                    local membership = State.Membership()
                    return not membership or membership.agencyId ~= place.agency
                end,
                onSelect = function() apply(place) end
            })
            interactions[#interactions + 1] = id
        end
    end
end

RegisterNetEvent(Federal.Net('apps:places'), function(list)
    rebuild(list)
end)

-- Joining or leaving an agency changes which recruitment desks are yours to
-- see, so the world rebuilds from the cached list on every state push.
State.OnChange(function() rebuild(places) end)

CreateThread(function()
    Wait(2500)
    Bridge.TriggerCallback(Federal.Net('apps:places'), function(list)
        if list then rebuild(list) end
    end)
end)

-- Review screens (boss menu) ---------------------------------------------------

local function id(name)
    return Federal.Menus.Id('apps:' .. name)
end

local function when(age)
    age = tonumber(age) or 0
    if age < 60 then return 'just now' end
    if age < 3600 then return ('%d min ago'):format(math.floor(age / 60)) end
    if age < 86400 then return ('%d hr ago'):format(math.floor(age / 3600)) end
    return ('%d day(s) ago'):format(math.floor(age / 86400))
end

function Applications.Detail(submission)
    local options = { {
        title = submission.name,
        description = ('Applied %s'):format(when(submission.age)),
        disabled = true
    } }

    for _, entry in ipairs(submission.answers or {}) do
        options[#options + 1] = {
            title = entry.label,
            description = entry.answer,
            disabled = true
        }
    end

    options[#options + 1] = { title = 'Decision', header = true }
    options[#options + 1] = {
        title = 'Approve',
        description = 'Hires them at the configured rank and division',
        icon = 'check',
        badgeTone = 'success',
        onSelect = function()
            DAG.Menu.Confirm(('Hire %s?'):format(submission.name),
                'They join at the rank and division the form grants.', function(confirmed)
                if not confirmed then return end
                TriggerServerEvent(Federal.Net('apps:decide'), submission.id, true)
                SetTimeout(400, Applications.Review)
            end)
        end
    }
    options[#options + 1] = {
        title = 'Deny',
        icon = 'close',
        badgeTone = 'danger',
        onSelect = function()
            DAG.Menu.Confirm(('Deny %s?'):format(submission.name), 'They are told it was declined.', function(confirmed)
                if not confirmed then return end
                TriggerServerEvent(Federal.Net('apps:decide'), submission.id, false)
                SetTimeout(400, Applications.Review)
            end)
        end
    }

    Federal.CAD.Show(id('detail'), submission.name, 'Application', options)
end

function Applications.Review()
    local membership = State.Membership()
    if not membership then return end

    Bridge.TriggerCallback(Federal.Net('apps:list'), function(list)
        local options = {}
        for _, submission in ipairs(list or {}) do
            options[#options + 1] = {
                title = submission.name,
                description = ('Applied %s'):format(when(submission.age)),
                icon = 'user',
                badge = 'Pending',
                badgeTone = 'accent',
                onSelect = function() Applications.Detail(submission) end
            }
        end

        if #options == 0 then
            options[1] = {
                title = 'No pending applications',
                description = 'New ones appear here the moment they are filed',
                disabled = true
            }
        end

        Federal.CAD.Show(id('inbox'), 'Applications', nil, options)
    end, membership.agencyId)
end

return Applications
