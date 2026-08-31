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

-- Whether rank editing would actually be accepted server-side: admins,
-- editor.manage holders, or the agency's highest rank (with roster.manage).
local function canEditRanks()
    if State.Context().admin then return true end
    if not State.Can('roster.manage') then return false end
    if State.Can('editor.manage') then return true end

    local agency = State.Mine()
    local top = 0
    for _, rank in ipairs(agency and agency.ranks or {}) do
        if rank.grade > top then top = rank.grade end
    end
    return State.Grade() >= top
end

Menus.CanEditRanks = canEditRanks

-- Main menu -------------------------------------------------------------------

function Menus.Open()
    local membership = State.Membership()
    if not membership then
        if State.Context().admin then return Federal.Editor.Open() end
        return Bridge.Notify('You are not a member of a federal agency.', 'error')
    end

    local agency = State.Mine()

    -- Off duty, the whole apparatus is out of reach: clock on first. Admins
    -- keep full access for configuration work.
    if not State.OnDuty() and not State.Context().admin then
        Federal.CAD.Show(Menus.Id('main'), agency and agency.short or 'Federal', membership.rank, {
            {
                title = agency and agency.label or 'Federal agency',
                description = ('%s | Off duty'):format(membership.rank),
                disabled = true
            },
            { title = 'Duty', header = true },
            {
                title = 'Go on duty',
                description = 'At a sign-in desk. Everything else unlocks once you clock on.',
                icon = 'check',
                onSelect = function() TriggerServerEvent(Federal.Net('duty'), true) end
            }
        })
        return
    end

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

    -- Management tools, so creating ranks, uniforms and divisions never
    -- requires walking to the command office or opening the config panel.
    local canManage = State.Can('uniform.manage') or State.Can('roster.manage')
        or State.Can('editor.manage') or State.Context().admin
    if canManage then
        options[#options + 1] = { title = 'Management', header = true }
        if State.Can('uniform.manage') then
            options[#options + 1] = {
                title = 'Design a uniform',
                description = 'Live studio: cycle clothing on your ped, then save',
                icon = 'user',
                onSelect = function() Federal.Studio.Uniform(agency and agency.id) end
            }
        end
        if canEditRanks() then
            options[#options + 1] = {
                title = 'Manage ranks',
                description = 'Create, rename, set permissions, delete',
                icon = 'lock',
                onSelect = Menus.Ranks
            }
        end
        if State.Can('roster.manage') or State.Context().admin then
            options[#options + 1] = {
                title = 'Applications',
                description = 'Review pending applications to your agency',
                icon = 'info',
                onSelect = function() Federal.ApplicationsUI.Review() end
            }
            options[#options + 1] = {
                title = 'Rank loadouts',
                description = 'Tie uniforms, items and vehicles to ranks',
                icon = 'box',
                onSelect = function() Federal.Studio.RankLoadouts(agency and agency.id) end
            }
            options[#options + 1] = {
                title = 'Divisions / taskforces',
                description = 'Create and manage sub-departments',
                icon = 'user',
                onSelect = function() Federal.Studio.Divisions(agency and agency.id) end
            }
        end
    end

    if State.Can('editor.manage') then
        options[#options + 1] = { title = 'Administration', header = true }
        options[#options + 1] = { title = 'Open the editor', icon = 'wrench', onSelect = Federal.Editor.Open }
    end

    show(Menus.Id('main'), agency and agency.short or 'Federal', membership.rank, options)
end

-- Rank management -------------------------------------------------------------
--
-- Menu-driven rank editing: create, rename, toggle each permission, delete.
-- Writes go through the same editor:rankSave/rankDelete endpoints as the
-- config panel; the server pushes a new context and the menu reopens on it.

local function reopenRanks()
    SetTimeout(350, function() Menus.Ranks() end)
end

local function reopenRank(grade)
    SetTimeout(350, function()
        local agency = State.Mine()
        if not agency then return end
        for _, rank in ipairs(agency.ranks or {}) do
            if rank.grade == grade then return Menus.Rank(rank) end
        end
        Menus.Ranks()
    end)
end

function Menus.RankPermissions(rank)
    local options = { {
        title = rank.label,
        description = 'Selecting a permission toggles it',
        disabled = true
    } }

    local names = {}
    for name in pairs(Const.Permissions) do names[#names + 1] = name end
    table.sort(names)

    for _, name in ipairs(names) do
        local granted = rank.permissions and rank.permissions[name] == true
        options[#options + 1] = {
            title = name,
            icon = granted and 'check' or 'close',
            badge = granted and 'Granted' or 'Off',
            badgeTone = granted and 'success' or nil,
            onSelect = function()
                local permissions = {}
                for key, value in pairs(rank.permissions or {}) do permissions[key] = value end
                permissions[name] = not granted or nil
                TriggerServerEvent(Federal.Net('editor:rankSave'), State.Membership().agencyId, {
                    grade = rank.grade, label = rank.label, permissions = permissions
                })
                SetTimeout(350, function()
                    local agency = State.Mine()
                    if not agency then return end
                    for _, fresh in ipairs(agency.ranks or {}) do
                        if fresh.grade == rank.grade then return Menus.RankPermissions(fresh) end
                    end
                end)
            end
        }
    end

    show(Menus.Id('rank-permissions'), 'Permissions', rank.label, options)
end

function Menus.Rank(rank)
    local options = {
        {
            title = rank.label,
            description = ('Grade %d'):format(rank.grade),
            disabled = true
        },
        {
            title = 'Rename',
            icon = 'wrench',
            onSelect = function()
                DAG.Menu.Input('Rename rank', {
                    { name = 'label', label = 'Rank name', required = true, default = rank.label }
                }, function(values)
                    if not values or not values.label then return end
                    TriggerServerEvent(Federal.Net('editor:rankSave'), State.Membership().agencyId, {
                        grade = rank.grade, label = values.label, permissions = rank.permissions
                    })
                    reopenRank(rank.grade)
                end)
            end
        },
        {
            title = 'Permissions',
            description = 'What this rank may do',
            icon = 'lock',
            onSelect = function() Menus.RankPermissions(rank) end
        },
        {
            title = 'Delete this rank',
            icon = 'close',
            badgeTone = 'danger',
            onSelect = function()
                DAG.Menu.Confirm(('Delete %s?'):format(rank.label),
                    'Members on this grade fall back to the rank below.', function(confirmed)
                    if not confirmed then return end
                    TriggerServerEvent(Federal.Net('editor:rankDelete'), State.Membership().agencyId, rank.grade)
                    reopenRanks()
                end)
            end
        }
    }

    show(Menus.Id('rank'), rank.label, ('Grade %d'):format(rank.grade), options)
end

function Menus.Ranks()
    local agency = State.Mine()
    if not agency then return end

    local options = {}
    for _, rank in ipairs(agency.ranks or {}) do
        options[#options + 1] = {
            title = rank.label,
            description = (function()
                local count = 0
                for _ in pairs(rank.permissions or {}) do count = count + 1 end
                return ('%d permission(s)'):format(count)
            end)(),
            icon = 'user',
            badge = ('Grade %d'):format(rank.grade),
            onSelect = function() Menus.Rank(rank) end
        }
    end

    options[#options + 1] = { title = 'Manage', header = true }
    options[#options + 1] = {
        title = 'Create a rank',
        description = 'Name and grade first, then set its permissions',
        icon = 'check',
        onSelect = function()
            DAG.Menu.Input('New rank', {
                { name = 'label', label = 'Rank name', required = true },
                { name = 'grade', label = 'Grade (job grade it maps to)', type = 'number', required = true }
            }, function(values)
                if not values or not values.label then return end
                TriggerServerEvent(Federal.Net('editor:rankSave'), State.Membership().agencyId, {
                    grade = tonumber(values.grade) or 0, label = values.label, permissions = {}
                })
                reopenRank(tonumber(values.grade) or 0)
            end)
        end
    }

    show(Menus.Id('ranks'), 'Ranks', agency.label, options)
end

function Menus.Actions()
    local options = Federal.Actions.Options()
    if #options == 0 then
        options[1] = { title = 'Your rank has no field actions', disabled = true }
    end
    show(Menus.Id('actions'), 'LEO actions', 'Acts on the nearest subject', options)
end

-- Boss office ------------------------------------------------------------------

-- The wardrobe management list: try a uniform on, overwrite it, duplicate
-- it, delete it. Reached from the Command office.
function Menus.BossUniforms()
    local agency = State.Mine()
    if not agency then return end

    local options = {}
    for _, uniform in ipairs(agency.uniforms or {}) do
        options[#options + 1] = {
            title = uniform.label,
            description = ('Grade %d+ | %s'):format(uniform.minGrade or 0, uniform.variant or 'any'),
            icon = 'user',
            onSelect = function() Menus.Uniform(uniform) end
        }
    end
    if #options == 0 then
        options[1] = { title = 'No uniforms yet', description = 'Design one in the studio', disabled = true }
    end
    show(Menus.Id('bossUniforms'), 'Uniform wardrobe', agency.label, options)
end

-- The Command office: a card desk, not a scroll of rows. Cards the member's
-- rank cannot use do not appear at all.
function Menus.Boss()
    local agency = State.Mine()
    if not agency then return end

    local admin = State.Context().admin
    local topGrade = 0
    for _, rank in ipairs(agency.ranks or {}) do
        if (rank.grade or 0) > topGrade then topGrade = rank.grade end
    end

    local handlers = {}

    local function section(label)
        return { label = label, items = {} }
    end

    local function card(target, cardId, label, icon, sub, run)
        handlers[cardId] = run
        target.items[#target.items + 1] = { id = cardId, label = label, icon = icon, sub = sub }
    end

    -- CONFIGURATION: the panel is the headline; the studios feed it.
    local configuration = section('Configuration')
    if admin or State.Grade() >= topGrade or State.Can('editor.manage') then
        card(configuration, 'panel', 'Agency configuration', '🛠',
            'Stations, ranks, callsigns, armory, doors - the full panel',
            function() ExecuteCommand('fedconfig') end)
    end
    if State.Can('uniform.manage') then
        card(configuration, 'uniform-studio', 'Uniform studio', '👕',
            'Design a uniform live on your ped',
            function() Federal.Studio.Uniform(agency.id) end)
        card(configuration, 'save-outfit', 'Save my outfit', '📸',
            'File what you are wearing as a uniform', Menus.SaveUniform)
        card(configuration, 'wardrobe', 'Uniform wardrobe', '🧥',
            'Try on, duplicate or retire uniforms', Menus.BossUniforms)
    end
    if admin or State.Can('editor.manage') then
        card(configuration, 'vehicle-studio', 'Vehicle studio', '🚔',
            'Spawn, customize and save to the motor pool',
            function() Federal.Studio.Vehicle(agency.id) end)
        card(configuration, 'divisions', 'Divisions', '🧩',
            'Sub-departments and their rank ladders',
            function() Federal.Studio.Divisions(agency.id) end)
    end
    if State.Can('armory.manage') then
        card(configuration, 'stock', 'Stock the armory', '📦',
            'Searchable item catalog',
            function() Federal.Studio.Item(agency.id) end)
    end
    if State.Can('roster.manage') or State.Can('editor.manage') then
        card(configuration, 'loadouts', 'Rank loadouts', '🎖',
            'Tie uniforms, items and vehicles to ranks',
            function() Federal.Studio.RankLoadouts(agency.id) end)
    end

    -- COMMAND: people.
    local command = section('Command')
    if State.Can('roster.manage') then
        card(command, 'personnel', 'Personnel', '👥',
            'Hire, promote, dismiss, callsigns, divisions', Federal.Personnel.Open)
        card(command, 'applications', 'Applications', '📨',
            'Review recruits - approval hires automatically',
            function() Federal.ApplicationsUI.Review() end)
        if canEditRanks() then
            card(command, 'ranks', 'Ranks & permissions', '🔐',
                'Create ranks and set what each may do', Menus.Ranks)
        end
    end

    -- OPERATIONS: the working tools.
    local operations = section('Operations')
    card(operations, 'roster', 'Duty roster', '🗂', 'Who is on the air right now', Federal.CAD.Units)
    if State.Can('cad.view') then
        card(operations, 'cad', 'Open the CAD', '🖥', 'Dispatch, records, the live map',
            function() Federal.MDT.Open() end)
    end
    if State.Can('editor.manage') then
        card(operations, 'editor', 'World editor', '🗺', 'Stations and zones, placed in the world',
            function() Federal.Editor.Open() end)
    end

    local gridSections = {}
    for _, entry in ipairs({ configuration, command, operations }) do
        if #entry.items > 0 then gridSections[#gridSections + 1] = entry end
    end
    if #gridSections == 0 then
        return Bridge.Notify('Your rank carries no command duties.', 'error')
    end

    DAG.Menu.Grid({
        title = 'Command office',
        subtitle = agency.label,
        hint = 'Pick a desk',
        sections = gridSections
    }, function(selected)
        local run = handlers[selected]
        DAG.Menu.GridClose()
        if run then run() end
    end)
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
            title = 'Duplicate this uniform',
            description = 'A copy to start a new uniform from',
            icon = 'check',
            onSelect = function()
                local membership = State.Membership()
                TriggerServerEvent(Federal.Net('uniform:adminSave'), membership and membership.agencyId or '', {
                    label = ('%s (copy)'):format(uniform.label),
                    minGrade = uniform.minGrade,
                    variant = uniform.variant,
                    division = uniform.division,
                    armour = uniform.armour,
                    components = uniform.components,
                    props = uniform.props
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
    -- The dialog needs the forced prefix and whether this rank may self-serve
    -- at all, so the server is asked before the menu draws.
    Bridge.TriggerCallback(Federal.Net('callsign:info'), function(info)
        info = info or {}
        local options = {
            {
                title = State.OnDuty() and 'Go off duty' or 'Go on duty',
                description = info.current and ('Your callsign: %s'):format(info.current) or nil,
                icon = 'check',
                onSelect = function()
                    TriggerServerEvent(Federal.Net('duty'), not State.OnDuty(), station.id)
                end
            }
        }

        if info.canSelf then
            options[#options + 1] = {
                title = 'Set your callsign',
                description = ('The %s prefix is fixed; you choose what follows it'):format(info.prefix or ''),
                icon = 'user',
                badge = info.current,
                onSelect = function()
                    DAG.Menu.Input('Callsign', {
                        { name = 'suffix', label = ('Suffix after %s'):format(info.prefix or ''), required = true }
                    }, function(values)
                        if not values then return end
                        TriggerServerEvent(Federal.Net('callsign:set'), nil, values.suffix or values[1])
                    end)
                end
            }
        end

        options[#options + 1] = { title = 'Set your status', icon = 'info', onSelect = Federal.CAD.StatusMenu }
        show(Menus.Id('duty'), 'Sign-in desk', station.label, options)
    end)
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
