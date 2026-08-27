-- Menu assembly: the main menu, the boss office, and the dispatcher that
-- decides what each station zone opens.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Const = Federal.Constants
local State = Federal.State
local Menus = {}
Federal.Menus = Menus

-- Menu ids are namespaced per resource so two resources built from this
-- template never register the same menu.
function Menus.Id(name)
    return ('%s:federal:%s'):format(Bridge.namespace, name)
end

local function show(id, title, subtitle, options)
    Federal.CAD.Show(id, title, subtitle, options)
end

-- Main menu -------------------------------------------------------------------

function Menus.Open()
    local membership = State.Membership()
    if not membership then
        if State.Context().admin then return Federal.Editor.Open() end
        return Bridge.Notify('You are not a member of a federal agency.', 'error')
    end

    local agency = State.Mine()
    local options = {
        {
            title = agency and agency.label or 'Federal agency',
            description = ('%s | %s'):format(membership.rank, State.OnDuty() and 'On duty' or 'Off duty'),
            disabled = true
        },
        { title = 'Field', header = true },
        { title = 'LEO actions', icon = 'lock', onSelect = Menus.Actions },
        { title = 'Active callouts', icon = 'info', onSelect = Federal.Callouts.Menu },
        { title = 'Reported incidents', icon = 'info', onSelect = Federal.Reports.Board },
        { title = 'Set your status', icon = 'user', onSelect = Federal.CAD.StatusMenu },
        { title = 'Field equipment', icon = 'box', onSelect = Federal.Equipment.Menu }
    }

    if State.Can('cad.view') then
        options[#options + 1] = { title = 'Records', header = true }
        options[#options + 1] = {
            title = 'Open the terminal',
            description = 'The full MDT',
            icon = 'box',
            onSelect = Federal.MDT.Open
        }
        options[#options + 1] = { title = 'Quick CAD menu', icon = 'info', onSelect = Federal.CAD.Open }
    end

    options[#options + 1] = { title = 'Court', header = true }
    options[#options + 1] = { title = 'Court docket', icon = 'info', onSelect = function() Federal.Court.Docket() end }

    options[#options + 1] = { title = 'Duty', header = true }
    options[#options + 1] = {
        title = State.OnDuty() and 'Go off duty' or 'Go on duty',
        description = State.OnDuty() and nil or 'You must be at a sign-in desk',
        icon = 'check',
        onSelect = function() TriggerServerEvent(Federal.Net('duty'), not State.OnDuty()) end
    }

    if State.Can('editor.manage') then
        options[#options + 1] = { title = 'Administration', header = true }
        options[#options + 1] = { title = 'Open the editor', icon = 'wrench', onSelect = Federal.Editor.Open }
    end

    show(Menus.Id('main'), agency and agency.short or 'Federal', membership.rank, options)
end

function Menus.Actions()
    local options = Federal.Actions.Options()
    if #options == 0 then
        options[1] = { title = 'Your rank has no field actions', disabled = true }
    end
    show(Menus.Id('actions'), 'LEO actions', 'Acts on the nearest subject', options)
end

-- Boss office ------------------------------------------------------------------

function Menus.Boss()
    local agency = State.Mine()
    if not agency then return end

    local options = { { title = 'Uniforms', header = true } }

    for _, uniform in ipairs(agency.uniforms or {}) do
        options[#options + 1] = {
            title = uniform.label,
            description = ('Grade %d+ | %s'):format(uniform.minGrade, uniform.variant),
            icon = 'user',
            onSelect = function() Menus.Uniform(uniform) end
        }
    end

    if State.Can('uniform.manage') then
        options[#options + 1] = {
            title = 'Save my current outfit',
            description = 'Wear it first, then save it here',
            icon = 'check',
            onSelect = Menus.SaveUniform
        }
    end

    options[#options + 1] = { title = 'Armory', header = true }
    for _, entry in ipairs(agency.armory or {}) do
        options[#options + 1] = {
            title = entry.label,
            description = ('%s | grade %d+'):format(entry.item, entry.minGrade),
            icon = 'box',
            badge = entry.price > 0 and ('$%d'):format(entry.price) or nil,
            onSelect = function()
                if not State.Can('armory.manage') then return end
                DAG.Menu.Confirm(('Remove %s?'):format(entry.label), 'It can be stocked again.', function(confirmed)
                    if confirmed then TriggerServerEvent(Federal.Net('armory:delete'), entry.id) end
                end)
            end
        }
    end

    if State.Can('armory.manage') then
        options[#options + 1] = { title = 'Stock a new item', icon = 'check', onSelect = Menus.StockItem }
    end

    options[#options + 1] = { title = 'Command', header = true }
    if State.Can('roster.manage') then
        options[#options + 1] = {
            title = 'Personnel',
            description = 'Hire, promote and dismiss',
            icon = 'user',
            onSelect = Federal.Personnel.Open
        }
    end
    options[#options + 1] = { title = 'Duty roster', icon = 'user', onSelect = Federal.CAD.Units }
    if State.Can('editor.manage') then
        options[#options + 1] = { title = 'Open the editor', icon = 'wrench', onSelect = Federal.Editor.Open }
    end

    show(Menus.Id('boss'), 'Command office', agency.label, options)
end

function Menus.SaveUniform()
    DAG.Menu.Input('Save this outfit', {
        { name = 'label', label = 'Uniform name', required = true },
        { name = 'minGrade', label = 'Minimum grade', type = 'number', default = 0 },
        { name = 'variant', label = 'any, male or female', default = 'any' }
    }, function(values)
        if not values then return end

        local captured = Federal.Uniforms.Capture()
        TriggerServerEvent(Federal.Net('uniform:save'), {
            label = values.label or values[1],
            minGrade = tonumber(values.minGrade or values[2]) or 0,
            variant = tostring(values.variant or values[3] or 'any'):lower(),
            components = captured.components,
            props = captured.props
        })
    end)
end

function Menus.Uniform(uniform)
    local options = {
        { title = uniform.label, description = ('%d component(s)'):format(#(uniform.components or {})), disabled = true },
        { title = 'Try it on', icon = 'user', onSelect = function() Federal.Uniforms.Apply(uniform) end }
    }

    if State.Can('uniform.manage') then
        options[#options + 1] = {
            title = 'Overwrite with my current outfit',
            icon = 'wrench',
            onSelect = function()
                local captured = Federal.Uniforms.Capture()
                TriggerServerEvent(Federal.Net('uniform:save'), {
                    id = uniform.id,
                    label = uniform.label,
                    minGrade = uniform.minGrade,
                    variant = uniform.variant,
                    components = captured.components,
                    props = captured.props
                })
            end
        }
        options[#options + 1] = {
            title = 'Delete this uniform',
            icon = 'close',
            badgeTone = 'danger',
            onSelect = function()
                DAG.Menu.Confirm(('Delete %s?'):format(uniform.label), 'This cannot be undone.', function(confirmed)
                    if confirmed then TriggerServerEvent(Federal.Net('uniform:delete'), uniform.id) end
                end)
            end
        }
    end

    show(Menus.Id('uniform'), uniform.label, nil, options)
end

function Menus.StockItem()
    DAG.Menu.Input('Stock an item', {
        { name = 'item', label = 'Item name', required = true },
        { name = 'label', label = 'Display name' },
        { name = 'count', label = 'Quantity per draw', type = 'number', default = 1 },
        { name = 'minGrade', label = 'Minimum grade', type = 'number', default = 0 },
        { name = 'price', label = 'Price', type = 'number', default = 0 }
    }, function(values)
        if not values then return end
        TriggerServerEvent(Federal.Net('armory:save'), {
            item = values.item or values[1],
            label = values.label or values[2],
            count = tonumber(values.count or values[3]) or 1,
            minGrade = tonumber(values.minGrade or values[4]) or 0,
            price = tonumber(values.price or values[5]) or 0
        })
    end)
end

-- Cells --------------------------------------------------------------------------

function Menus.Cells()
    local options = {}
    if State.Can('actions.arrest') then
        options[#options + 1] = { title = 'Book the nearest subject', icon = 'lock', onSelect = Federal.Actions.Arrest }
        options[#options + 1] = { title = 'Release the nearest subject', icon = 'check', onSelect = Federal.Actions.Release }
    end
    options[#options + 1] = { title = 'Custody roster', icon = 'user', onSelect = Federal.Jail.Roster }
    options[#options + 1] = { title = 'Court docket', icon = 'info', onSelect = function() Federal.Court.Docket() end }

    show(Menus.Id('cells'), 'Holding cells', nil, options)
end

-- Zone dispatch -------------------------------------------------------------------

local ZONE_HANDLERS = {}

ZONE_HANDLERS.duty = function(_, station)
    local options = {
        {
            title = State.OnDuty() and 'Go off duty' or 'Go on duty',
            icon = 'check',
            onSelect = function()
                TriggerServerEvent(Federal.Net('duty'), not State.OnDuty(), station.id)
            end
        },
        {
            title = 'Set your callsign',
            icon = 'user',
            onSelect = function()
                DAG.Menu.Input('Callsign', { { name = 'callsign', label = 'Callsign', required = true } },
                    function(values)
                        if not values then return end
                        TriggerServerEvent(Federal.Net('duty'), true, station.id, values.callsign or values[1])
                    end)
            end
        },
        { title = 'Set your status', icon = 'info', onSelect = Federal.CAD.StatusMenu }
    }
    show(Menus.Id('duty'), 'Sign-in desk', station.label, options)
end

ZONE_HANDLERS.locker = function() Federal.Armory.Locker() end
ZONE_HANDLERS.armory = function() Federal.Armory.Open() end
ZONE_HANDLERS.garage = function() Federal.Armory.Garage() end
ZONE_HANDLERS.cad = function() Federal.MDT.Open() end
ZONE_HANDLERS.evidence = function() Federal.CAD.Evidence() end
ZONE_HANDLERS.boss = function() Menus.Boss() end
ZONE_HANDLERS.cells = function() Menus.Cells() end

function Menus.OpenZone(kind, agency, station, zone)
    local handler = ZONE_HANDLERS[kind]
    if handler then return handler(agency, station, zone) end

    local detail = Const.ZoneKinds[kind]
    Bridge.Notify(('%s is not wired to anything yet.'):format(detail and detail.label or kind), 'inform')
end

RegisterNetEvent(Federal.Net('openMenu'), function()
    Menus.Open()
end)

return Menus
