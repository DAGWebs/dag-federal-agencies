-- The in-game editor.
--
-- The whole point of this screen is that you edit a thing by standing where it
-- belongs and pressing "place here". Every placement sends `here = true` and
-- the server writes the position it reads for you, so what you see is what
-- gets stored.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Const = Federal.Constants
local State = Federal.State
local Editor = {}
Federal.Editor = Editor

local function id(name)
    return Federal.Menus.Id('editor:' .. name)
end

local function show(menuId, title, subtitle, options)
    Federal.CAD.Show(menuId, title, subtitle, options)
end

-- Anything the editor changes comes back as a context push, so the menu is
-- reopened from fresh state rather than from what it had before the edit.
local function afterEdit(reopen)
    SetTimeout(250, function()
        if reopen then reopen() end
    end)
end

function Editor.Open()
    if not State.Can('editor.manage') then
        return Bridge.Notify('You are not authorized to edit agencies.', 'error')
    end

    local options = { { title = 'Agencies', header = true } }
    for _, agency in ipairs(State.Agencies()) do
        options[#options + 1] = {
            title = agency.label,
            description = ('%d station(s), %d uniform(s), %d armory line(s)'):format(
                #agency.stations, #agency.uniforms, #agency.armory),
            icon = 'box',
            badge = agency.short,
            onSelect = function() Editor.Agency(agency.id) end
        }
    end

    options[#options + 1] = { title = 'Administration', header = true }
    options[#options + 1] = { title = 'Create an agency', icon = 'check', onSelect = Editor.CreateAgency }
    options[#options + 1] = { title = 'Courthouses', icon = 'info', onSelect = Editor.Courthouses }

    show(id('root'), 'Federal editor', 'Edit where you are standing', options)
end

function Editor.CreateAgency()
    DAG.Menu.Input('Create an agency', {
        { name = 'label', label = 'Full name', required = true },
        { name = 'short', label = 'Short code (FIB)', required = true },
        { name = 'jobs', label = 'Framework job names (comma separated)' }
    }, function(values)
        if not values then return end

        local jobs = {}
        for job in tostring(values.jobs or values[3] or ''):gmatch('[^,]+') do
            local trimmed = job:gsub('^%s+', ''):gsub('%s+$', '')
            if trimmed ~= '' then jobs[#jobs + 1] = trimmed end
        end

        TriggerServerEvent(Federal.Net('editor:agencyCreate'), {
            label = values.label or values[1],
            short = values.short or values[2],
            jobs = jobs
        })
        afterEdit(Editor.Open)
    end)
end

function Editor.Agency(agencyId)
    local agency = State.Agency(agencyId)
    if not agency then return Editor.Open() end

    local options = {
        { title = agency.label, description = ('Boss grade %d'):format(agency.bossGrade), disabled = true },
        { title = 'Stations', header = true }
    }

    for _, station in ipairs(agency.stations or {}) do
        options[#options + 1] = {
            title = station.label,
            description = ('%d room(s)'):format(#(station.zones or {})),
            icon = 'box',
            onSelect = function() Editor.Station(agencyId, station.id) end
        }
    end

    options[#options + 1] = {
        title = 'Add a station here',
        icon = 'check',
        description = 'Uses your current position',
        onSelect = function()
            DAG.Menu.Input('New station', { { name = 'label', label = 'Station name', required = true } },
                function(values)
                    if not values then return end
                    TriggerServerEvent(Federal.Net('editor:stationSave'), agencyId, {
                        label = values.label or values[1], here = true
                    })
                    afterEdit(function() Editor.Agency(agencyId) end)
                end)
        end
    }

    options[#options + 1] = { title = 'Agency', header = true }
    options[#options + 1] = { title = 'Rename / retune', icon = 'wrench', onSelect = function() Editor.Details(agencyId) end }
    options[#options + 1] = { title = 'Ranks', icon = 'user', onSelect = function() Editor.Ranks(agencyId) end }
    options[#options + 1] = {
        title = 'Delete this agency',
        icon = 'close',
        badgeTone = 'danger',
        onSelect = function()
            DAG.Menu.Confirm('Delete this agency?', agency.label, function(confirmed)
                if not confirmed then return end
                TriggerServerEvent(Federal.Net('editor:agencyDelete'), agencyId)
                afterEdit(Editor.Open)
            end)
        end
    }

    show(id('agency'), agency.label, agency.short, options)
end

function Editor.Details(agencyId)
    local agency = State.Agency(agencyId)
    if not agency then return end

    DAG.Menu.Input('Agency details', {
        { name = 'label', label = 'Full name', default = agency.label },
        { name = 'short', label = 'Short code', default = agency.short },
        { name = 'bossGrade', label = 'Boss grade', type = 'number', default = agency.bossGrade },
        { name = 'jobs', label = 'Job names (comma separated)', default = table.concat(agency.jobs or {}, ',') }
    }, function(values)
        if not values then return end

        local jobs = {}
        for job in tostring(values.jobs or values[4] or ''):gmatch('[^,]+') do
            local trimmed = job:gsub('^%s+', ''):gsub('%s+$', '')
            if trimmed ~= '' then jobs[#jobs + 1] = trimmed end
        end

        TriggerServerEvent(Federal.Net('editor:agencyUpdate'), agencyId, {
            label = values.label or values[1],
            short = values.short or values[2],
            bossGrade = tonumber(values.bossGrade or values[3]),
            jobs = #jobs > 0 and jobs or nil
        })
        afterEdit(function() Editor.Agency(agencyId) end)
    end)
end

function Editor.Station(agencyId, stationId)
    local agency = State.Agency(agencyId)
    local station = agency and Federal.Schema.FindById(agency.stations or {}, stationId)
    if not station then return Editor.Agency(agencyId) end

    local options = { { title = 'Rooms', header = true } }
    for _, zone in ipairs(station.zones or {}) do
        local kind = Const.ZoneKinds[zone.kind] or {}
        options[#options + 1] = {
            title = zone.label,
            description = kind.description,
            icon = kind.icon,
            badge = zone.minGrade > 0 and ('Grade %d+'):format(zone.minGrade) or nil,
            onSelect = function()
                DAG.Menu.Confirm(('Remove %s?'):format(zone.label), 'It can be placed again.', function(confirmed)
                    if not confirmed then return end
                    TriggerServerEvent(Federal.Net('editor:zoneDelete'), agencyId, stationId, zone.id)
                    afterEdit(function() Editor.Station(agencyId, stationId) end)
                end)
            end
        }
    end

    options[#options + 1] = { title = 'Place a room here', header = true }
    for _, kind in ipairs(Const.ZoneKindOrder) do
        local detail = Const.ZoneKinds[kind]
        options[#options + 1] = {
            title = detail.label,
            description = detail.description,
            icon = detail.icon,
            onSelect = function()
                DAG.Menu.Input(('Place a %s'):format(detail.label:lower()), {
                    { name = 'label', label = 'Name', default = detail.label },
                    { name = 'minGrade', label = 'Minimum grade', type = 'number', default = 0 },
                    { name = 'radius', label = 'Radius', type = 'number', default = 2.0 }
                }, function(values)
                    if not values then return end
                    TriggerServerEvent(Federal.Net('editor:zoneSave'), agencyId, stationId, {
                        kind = kind,
                        label = values.label or values[1],
                        minGrade = tonumber(values.minGrade or values[2]) or 0,
                        radius = tonumber(values.radius or values[3]) or 2.0,
                        here = true
                    })
                    afterEdit(function() Editor.Station(agencyId, stationId) end)
                end)
            end
        }
    end

    options[#options + 1] = { title = 'Station', header = true }
    options[#options + 1] = {
        title = 'Move the station here',
        description = 'Keeps the rooms already placed',
        icon = 'wrench',
        onSelect = function()
            TriggerServerEvent(Federal.Net('editor:stationSave'), agencyId, {
                id = stationId, label = station.label, here = true
            })
            afterEdit(function() Editor.Station(agencyId, stationId) end)
        end
    }
    options[#options + 1] = {
        title = 'Delete the station',
        icon = 'close',
        badgeTone = 'danger',
        onSelect = function()
            DAG.Menu.Confirm('Delete this station?', station.label, function(confirmed)
                if not confirmed then return end
                TriggerServerEvent(Federal.Net('editor:stationDelete'), agencyId, stationId)
                afterEdit(function() Editor.Agency(agencyId) end)
            end)
        end
    }

    show(id('station'), station.label, ('%d room(s)'):format(#(station.zones or {})), options)
end

function Editor.Ranks(agencyId)
    local agency = State.Agency(agencyId)
    if not agency then return end

    local options = {}
    for _, rank in ipairs(agency.ranks or {}) do
        local granted = 0
        for _ in pairs(rank.permissions or {}) do granted = granted + 1 end
        options[#options + 1] = {
            title = rank.label,
            description = ('%d permission(s)'):format(granted),
            icon = 'user',
            badge = ('Grade %d'):format(rank.grade),
            onSelect = function() Editor.Rank(agencyId, rank) end
        }
    end

    options[#options + 1] = { title = 'Add', header = true }
    options[#options + 1] = {
        title = 'Add a rank',
        icon = 'check',
        onSelect = function()
            DAG.Menu.Input('New rank', {
                { name = 'grade', label = 'Grade', type = 'number', required = true },
                { name = 'label', label = 'Rank name', required = true }
            }, function(values)
                if not values then return end
                TriggerServerEvent(Federal.Net('editor:rankSave'), agencyId, {
                    grade = tonumber(values.grade or values[1]),
                    label = values.label or values[2],
                    permissions = {}
                })
                afterEdit(function() Editor.Ranks(agencyId) end)
            end)
        end
    }

    show(id('ranks'), 'Ranks', agency.label, options)
end

-- Permissions are toggled one at a time and saved as a whole rank, because the
-- server validates the full permission set on every write.
function Editor.Rank(agencyId, rank)
    local options = { { title = rank.label, description = ('Grade %d'):format(rank.grade), disabled = true } }

    for _, permission in ipairs(Const.PermissionOrder) do
        local granted = (rank.permissions or {})[permission] == true
        options[#options + 1] = {
            title = Const.Permissions[permission],
            description = permission,
            icon = granted and 'check' or 'close',
            badge = granted and 'Granted' or 'Denied',
            badgeTone = granted and 'success' or nil,
            onSelect = function()
                local permissions = {}
                for name, value in pairs(rank.permissions or {}) do permissions[name] = value end
                permissions[permission] = not granted or nil

                TriggerServerEvent(Federal.Net('editor:rankSave'), agencyId, {
                    grade = rank.grade, label = rank.label, permissions = permissions
                })
                afterEdit(function() Editor.Ranks(agencyId) end)
            end
        }
    end

    options[#options + 1] = {
        title = 'Delete this rank',
        icon = 'close',
        badgeTone = 'danger',
        onSelect = function()
            TriggerServerEvent(Federal.Net('editor:rankDelete'), agencyId, rank.grade)
            afterEdit(function() Editor.Ranks(agencyId) end)
        end
    }

    show(id('rank'), rank.label, ('Grade %d'):format(rank.grade), options)
end

-- Courthouses ------------------------------------------------------------------------

function Editor.Courthouses()
    Federal.Court.Refresh(function(list)
        local options = {}
        for _, house in ipairs(list) do
            options[#options + 1] = {
                title = house.label,
                description = ('%d seat(s)'):format(#(house.seats or {})),
                icon = 'box',
                onSelect = function() Editor.Courthouse(house.id) end
            }
        end

        options[#options + 1] = { title = 'Add', header = true }
        options[#options + 1] = {
            title = 'Add a courthouse here',
            icon = 'check',
            onSelect = function()
                DAG.Menu.Input('New courthouse', { { name = 'label', label = 'Name', required = true } },
                    function(values)
                        if not values then return end
                        TriggerServerEvent(Federal.Net('court:houseSave'), {
                            label = values.label or values[1], here = true
                        })
                        afterEdit(Editor.Courthouses)
                    end)
            end
        }

        show(id('courthouses'), 'Courthouses', ('%d configured'):format(#list), options)
    end)
end

function Editor.Courthouse(courthouseId)
    local house
    for _, candidate in ipairs(Federal.Court.Houses()) do
        if candidate.id == courthouseId then house = candidate end
    end
    if not house then return Editor.Courthouses() end

    local options = { { title = 'Seats', header = true } }
    for _, seat in ipairs(house.seats or {}) do
        options[#options + 1] = {
            title = seat.label,
            description = seat.role,
            icon = 'user',
            onSelect = function()
                DAG.Menu.Confirm(('Remove %s?'):format(seat.label), 'It can be placed again.', function(confirmed)
                    if not confirmed then return end
                    TriggerServerEvent(Federal.Net('court:seatDelete'), courthouseId, seat.id)
                    afterEdit(function() Editor.Courthouse(courthouseId) end)
                end)
            end
        }
    end

    options[#options + 1] = { title = 'Place a seat here', header = true }
    for _, role in ipairs(Const.SeatRoleOrder) do
        local detail = Const.SeatRoles[role]
        options[#options + 1] = {
            title = detail.label,
            description = detail.multiple and 'Several of these may be placed' or 'Re-placing moves the existing one',
            icon = 'user',
            onSelect = function()
                TriggerServerEvent(Federal.Net('court:seatSave'), courthouseId, {
                    -- A single-position role keeps a stable id so re-placing
                    -- it moves the seat instead of adding a second one.
                    id = not detail.multiple and role or nil,
                    role = role,
                    label = detail.label,
                    here = true
                })
                afterEdit(function() Editor.Courthouse(courthouseId) end)
            end
        }
    end

    options[#options + 1] = { title = 'Courthouse', header = true }
    options[#options + 1] = {
        title = 'Delete this courthouse',
        icon = 'close',
        badgeTone = 'danger',
        onSelect = function()
            DAG.Menu.Confirm('Delete this courthouse?', house.label, function(confirmed)
                if not confirmed then return end
                TriggerServerEvent(Federal.Net('court:houseDelete'), courthouseId)
                afterEdit(Editor.Courthouses)
            end)
        end
    }

    show(id('courthouse'), house.label, ('%d seat(s)'):format(#(house.seats or {})), options)
end

return Editor
