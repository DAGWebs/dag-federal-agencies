-- Calling something in, and the board officers respond from.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local State = Federal.State
local Reports = {}
Federal.Reports = Reports

local blips = {}

local function id(name)
    return Federal.Menus.Id('reports:' .. name)
end

local function show(menuId, title, subtitle, options)
    Federal.CAD.Show(menuId, title, subtitle, options)
end

function Reports.ClearBlips()
    for _, blip in pairs(blips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    blips = {}
end

local function markReport(report)
    if blips[report.id] and DoesBlipExist(blips[report.id]) then RemoveBlip(blips[report.id]) end
    if report.status == 'closed' then
        blips[report.id] = nil
        return
    end

    blips[report.id] = Federal.Zones.AddBlip(report.location, 'Reported incident', {
        sprite = 280,
        color = report.status == 'responding' and 3 or 1,
        scale = 0.8,
        shortRange = false
    })
end

-- Calling it in -----------------------------------------------------------------

function Reports.Call()
    DAG.Menu.Input('Report something', {
        { name = 'text', label = 'What are you reporting?', required = true },
        { name = 'anonymous', label = 'Anonymous? (yes/no)', default = 'no' }
    }, function(values)
        if not values then return end

        local anonymous = tostring(values.anonymous or values[2] or ''):lower()
        Bridge.TriggerCallback(Federal.Net('report:submit'), function(report, err)
            if not report then return Bridge.Notify(err or 'The call did not go through.', 'error') end
            Bridge.Notify('Your report has been passed to the duty desk.', 'success')
        end, {
            text = values.text or values[1],
            anonymous = anonymous == 'yes' or anonymous == 'y' or anonymous == 'true'
        })
    end)
end

-- The board -----------------------------------------------------------------------

function Reports.Board()
    Bridge.TriggerCallback(Federal.Net('reports'), function(list)
        local options = {}
        for _, report in ipairs(list or {}) do
            options[#options + 1] = {
                title = report.text,
                description = ('From %s | %s'):format(report.caller, DAG.Federal.Util.StampClock(report.at)),
                icon = 'info',
                badge = report.status == 'responding' and 'Responding' or 'New',
                badgeTone = report.status == 'responding' and 'accent' or 'danger',
                onSelect = function() Reports.Detail(report) end
            }
        end

        if #(list or {}) == 0 then
            options[1] = { title = 'Nothing reported', description = 'The line is quiet', disabled = true }
        end

        show(id('board'), 'Reported incidents', ('%d open'):format(#(list or {})), options)
    end)
end

function Reports.Detail(report)
    local options = {
        { title = report.text, description = ('Caller: %s'):format(report.caller), disabled = true }
    }

    if report.calloutId then
        options[#options + 1] = {
            title = 'Escalated to a callout',
            description = 'This one produced a full investigation',
            icon = 'check',
            badgeTone = 'success',
            disabled = true
        }
    end

    options[#options + 1] = { title = 'Actions', header = true }
    options[#options + 1] = {
        title = 'Set a waypoint',
        icon = 'car',
        onSelect = function()
            SetNewWaypoint(report.location.x, report.location.y)
            Bridge.Notify('Waypoint set.', 'inform')
        end
    }

    if State.Can('actions.detain') then
        if report.status ~= 'responding' then
            options[#options + 1] = {
                title = 'Respond to this',
                icon = 'check',
                onSelect = function()
                    TriggerServerEvent(Federal.Net('report:ack'), report.id)
                    Federal.Actions.SetStatus('enroute')
                    SetNewWaypoint(report.location.x, report.location.y)
                end
            }
        end
        options[#options + 1] = {
            title = 'Close the report',
            icon = 'close',
            onSelect = function()
                TriggerServerEvent(Federal.Net('report:close'), report.id)
                SetTimeout(250, function() Reports.Board() end)
            end
        }
    end

    show(id('detail'), 'Reported incident', report.caller, options)
end

RegisterNetEvent(Federal.Net('report'), function(report)
    if type(report) ~= 'table' then return end
    markReport(report)

    if report.status == 'open' then
        Bridge.Notify(('Report: %s'):format(report.text), 'inform', 9000)
        PlaySoundFrontend(-1, 'Text_Arrive_Tone', 'Phone_SoundSet_Default', true)
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then Reports.ClearBlips() end
end)

return Reports
