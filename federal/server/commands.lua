-- Server commands. Names are derived from the resource name so two resources
-- built from this template never fight over one, and every command goes
-- through DAG.Commands so ACE and framework permissions are checked the same
-- way everywhere.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Core = Federal.Core

local prefix = Bridge.namespace .. ':fed'

local function report(source, message)
    if source == 0 then return Bridge.Print(message) end
    Bridge.Notify(source, message, 'inform')
end

-- Opens the main menu for a player who would rather type than walk to a desk.
DAG.Commands.Register(prefix, function(source)
    if source == 0 then return Bridge.Print('this command is for players') end
    TriggerClientEvent(Federal.Net('openMenu'), source)
end, {
    help = 'Open the federal agency menu.',
    allowConsole = false
})

DAG.Commands.Register(prefix .. ':status', function(source)
    local agencies = Core.Agencies()
    local lines = {}
    for _, agency in ipairs(agencies) do
        lines[#lines + 1] = ('%s: %d station(s), %d on duty'):format(
            agency.short, #agency.stations, #Core.OnDutySources(agency.id))
    end
    report(source, ('Federal agencies (%d) | %s'):format(#agencies, table.concat(lines, ' | ')))
end, {
    help = 'Show configured agencies and who is on duty.',
    permission = 'federal.admin'
})

-- Dispatching by hand is what a supervisor uses when the shift is quiet, and
-- what a server owner uses to check a template without waiting for the timer.
DAG.Commands.Register(prefix .. ':dispatch', function(source, args)
    local agencyId = args[1]
    local templateId = args[2]

    if source > 0 and not Core.Can(source, 'callout.manage') then
        return Bridge.Notify(source, 'You are not authorized to dispatch callouts.', 'error')
    end

    if not agencyId then
        local membership = source > 0 and Core.Membership(source)
        agencyId = membership and membership.agency.id
    end
    if not agencyId then return report(source, 'Usage: /' .. prefix .. ':dispatch <agency> [template]') end

    local callout, message = Federal.Callouts.Dispatch(agencyId, templateId)
    report(source, callout and ('Dispatched %s: %s'):format(callout.number, callout.label) or tostring(message))
end, {
    help = 'Dispatch an investigation callout.',
    arguments = {
        { name = 'agency', help = 'Agency id (defaults to yours)' },
        { name = 'template', help = 'Callout template id (optional)' }
    }
})

DAG.Commands.Register(prefix .. ':duty', function(source)
    if source == 0 then return Bridge.Print('this command is for players') end

    local membership = Core.Membership(source)
    if not membership then return Bridge.Notify(source, 'You are not a member of a federal agency.', 'error') end

    Core.SetDuty(source, not membership.onDuty)
    Core.Sync(source)
end, {
    help = 'Toggle federal duty status.',
    allowConsole = false
})

-- Config commands ------------------------------------------------------------
--
-- Everything the in-game editor can do, as typed commands, plus the motor
-- pool. Short names on purpose: these are for the server owner standing where
-- the thing belongs. Authorization is the editor's: federal.admin ACE, or
-- editor.manage over your own agency. Nothing here trusts the client.

local Util = Federal.Util
local Const = Federal.Constants

-- Resolves which agency a command acts on: the named one, or the caller's own.
local function commandAgency(source, agencyId)
    if agencyId and agencyId ~= '' then
        local agency = Core.Agency(agencyId:lower())
        if not agency then return nil, ('no agency called "%s" (try fib, iaa, doa, usss)'):format(agencyId) end
        return agency
    end
    local membership = source > 0 and Core.Membership(source)
    if membership then return membership.agency end
    return nil, 'name an agency: fib, iaa, doa or usss'
end

local function nearestStation(source, agency)
    local position = Core.Coords(source)
    if not position then return nil end
    local best, bestDistance
    for _, station in ipairs(agency.stations or {}) do
        local distance = Util.Distance(position, station.coords)
        if distance and (not bestDistance or distance < bestDistance) then
            best, bestDistance = station, distance
        end
    end
    return best
end

local function say(source, message)
    if source == 0 then return Bridge.Print(message) end
    TriggerClientEvent('chat:addMessage', source, { args = { '^3FED', message } })
end

local ZONE_KIND_LIST = 'duty (sign-in desk), locker, armory, evidence, cad, boss, cells, garage'

-- /fedzone <agency> <kind> [station]: place (or move) a room where you stand.
DAG.Commands.Register('fedzone', function(source, args)
    local agency, message = commandAgency(source, args[1])
    if not agency then return say(source, message) end

    local kind = (args[2] or ''):lower()
    if not Const.ZoneKinds[kind] then
        return say(source, ('Usage: /fedzone <agency> <kind> [station]. Kinds: %s'):format(ZONE_KIND_LIST))
    end

    local station = args[3] and Federal.Schema.FindById(agency.stations or {}, args[3]) or nearestStation(source, agency)
    if not station then return say(source, 'That agency has no station yet - place one with /fedstation first.') end

    local existing = Federal.Schema.FindById(station.zones or {}, kind)
    local zone, zoneMessage = Federal.Editor.SaveZone(source, agency.id, station.id, {
        id = kind,
        kind = kind,
        label = existing and existing.label or nil,
        radius = existing and existing.radius or nil,
        minGrade = existing and existing.minGrade or nil,
        here = true
    })
    say(source, zone and ('Placed %s at your position in %s.'):format(zone.label, station.label) or tostring(zoneMessage))
end, {
    help = 'Place a federal room (sign-in desk, locker, armory...) where you stand.',
    arguments = {
        { name = 'agency', help = 'fib, iaa, doa or usss' },
        { name = 'kind', help = ZONE_KIND_LIST },
        { name = 'station', help = 'Station id (defaults to the nearest)' }
    },
    allowConsole = false
})

DAG.Commands.Register('fedzoneremove', function(source, args)
    local agency, message = commandAgency(source, args[1])
    if not agency then return say(source, message) end

    local kind = (args[2] or ''):lower()
    local station = args[3] and Federal.Schema.FindById(agency.stations or {}, args[3]) or nearestStation(source, agency)
    if not station then return say(source, 'No station found.') end

    local zone, zoneMessage = Federal.Editor.DeleteZone(source, agency.id, station.id, kind)
    say(source, zone and ('Removed %s from %s.'):format(zone.label, station.label) or tostring(zoneMessage))
end, {
    help = 'Remove a federal room from a station.',
    arguments = {
        { name = 'agency', help = 'fib, iaa, doa or usss' },
        { name = 'kind', help = ZONE_KIND_LIST },
        { name = 'station', help = 'Station id (defaults to the nearest)' }
    },
    allowConsole = false
})

-- /fedstation <agency> <label...>: place (or move) a whole station.
DAG.Commands.Register('fedstation', function(source, args)
    local agency, message = commandAgency(source, args[1])
    if not agency then return say(source, message) end

    local label = table.concat(args, ' ', 2)
    if label == '' then return say(source, 'Usage: /fedstation <agency> <label>') end

    local station, stationMessage = Federal.Editor.SaveStation(source, agency.id, {
        id = Util.Slug(label),
        label = label,
        here = true
    })
    say(source, station and ('Placed station %s (id %s). Now place its rooms with /fedzone.'):format(station.label, station.id) or tostring(stationMessage))
end, {
    help = 'Place a federal station where you stand.',
    arguments = {
        { name = 'agency', help = 'fib, iaa, doa or usss' },
        { name = 'label', help = 'Station name (its id is derived from this)' }
    },
    allowConsole = false
})

DAG.Commands.Register('fedstationremove', function(source, args)
    local agency, message = commandAgency(source, args[1])
    if not agency then return say(source, message) end

    local station, stationMessage = Federal.Editor.DeleteStation(source, agency.id, args[2])
    say(source, station and ('Deleted station %s.'):format(station.label) or tostring(stationMessage))
end, {
    help = 'Delete a federal station (see ids with /fedconfig).',
    arguments = {
        { name = 'agency', help = 'fib, iaa, doa or usss' },
        { name = 'station', help = 'Station id' }
    }
})

-- /fedaddcar <agency> [label...]: sitting in a vehicle captures it as it
-- stands. On foot it opens the vehicle studio: pick a model from a searchable
-- list, a preview spawns, customize it live, then save it to the motor pool.
DAG.Commands.Register('fedaddcar', function(source, args)
    if source == 0 then return Bridge.Print('this command is for players') end
    local agency, message = commandAgency(source, args[1])
    if not agency then return say(source, message) end

    local editableAgency, editMessage = Federal.Editor.Editable(source, agency.id)
    if not editableAgency then return say(source, tostring(editMessage)) end

    local label = table.concat(args, ' ', 2)
    local ped = GetPlayerPed(source)
    if ped and ped ~= 0 and GetVehiclePedIsIn(ped, false) ~= 0 then
        TriggerClientEvent(Federal.Net('captureVehicle'), source, agency.id, label ~= '' and label or nil)
    else
        TriggerClientEvent(Federal.Net('openStudio'), source, 'vehicle', agency.id)
    end
end, {
    help = 'Add a vehicle to an agency motor pool: capture the one you sit in, or open the live studio on foot.',
    arguments = {
        { name = 'agency', help = 'fib, iaa, doa or usss' },
        { name = 'label', help = 'Display name (optional, capture only)' }
    },
    allowConsole = false
})

DAG.Commands.Register('fedremovecar', function(source, args)
    local agency, message = commandAgency(source, args[1])
    if not agency then return say(source, message) end

    local entry, removeMessage = Federal.Armory.RemoveVehicle(source, agency.id, args[2] or '')
    say(source, entry and ('Removed %s (%s) from the %s motor pool.'):format(entry.label, entry.model, agency.short) or tostring(removeMessage))
end, {
    help = 'Remove a vehicle from an agency motor pool (see ids with /fedcars).',
    arguments = {
        { name = 'agency', help = 'fib, iaa, doa or usss' },
        { name = 'vehicle', help = 'Vehicle id or model' }
    }
})

DAG.Commands.Register('fedcars', function(source, args)
    local agency, message = commandAgency(source, args[1])
    if not agency then return say(source, message) end

    local list, origin = Federal.Armory.Vehicles(agency.id)
    if #list == 0 then return say(source, ('%s motor pool is empty. Add one with /fedaddcar.'):format(agency.short)) end

    say(source, ('%s motor pool (%s):'):format(agency.short, origin == 'stored' and 'edited in game' or 'from config'))
    for _, entry in ipairs(list) do
        say(source, ('  %s - %s (%s)%s'):format(entry.id, entry.label, entry.model, entry.props and ' [saved mods]' or ''))
    end
end, {
    help = 'List an agency motor pool.',
    arguments = { { name = 'agency', help = 'fib, iaa, doa or usss' } }
})

-- /feduniform <agency> <minGrade> <label...>: save the outfit you are wearing.
DAG.Commands.Register('feduniform', function(source, args)
    if source == 0 then return Bridge.Print('this command is for players') end
    local agency, message = commandAgency(source, args[1])
    if not agency then return say(source, message) end

    local editableAgency, editMessage = Federal.Editor.Editable(source, agency.id)
    if not editableAgency then return say(source, tostring(editMessage)) end

    local minGrade = tonumber(args[2])
    local label = table.concat(args, ' ', minGrade and 3 or 2)
    if label == '' then
        -- No name given: open the live uniform studio instead. Cycle clothing
        -- on your own ped and save the result from the menu.
        return TriggerClientEvent(Federal.Net('openStudio'), source, 'uniform', agency.id)
    end

    TriggerClientEvent(Federal.Net('captureOutfit'), source, agency.id, label, minGrade or 0)
end, {
    help = 'Save the outfit you are wearing as an agency uniform, or open the live uniform studio with no name.',
    arguments = {
        { name = 'agency', help = 'fib, iaa, doa or usss' },
        { name = 'minGrade', help = 'Minimum grade (optional, default 0)' },
        { name = 'label', help = 'Uniform name (omit to open the studio)' }
    },
    allowConsole = false
})

DAG.Commands.Register('fedremoveuniform', function(source, args)
    local agency, message = commandAgency(source, args[1])
    if not agency then return say(source, message) end

    local uniform, removeMessage = Federal.Uniforms.AdminDelete(source, agency.id, args[2])
    say(source, uniform and ('Deleted uniform %s.'):format(uniform.label) or tostring(removeMessage))
end, {
    help = 'Delete an agency uniform (see ids with /fedconfig).',
    arguments = {
        { name = 'agency', help = 'fib, iaa, doa or usss' },
        { name = 'uniform', help = 'Uniform id' }
    }
})

-- /fedadditem <agency> <item> [minGrade] [price] [label...]: stock the armory.
DAG.Commands.Register('fedadditem', function(source, args)
    local agency, message = commandAgency(source, args[1])
    if not agency then return say(source, message) end

    local item = args[2]
    if not item then
        -- No item named: open the searchable picker instead of failing.
        if source > 0 then
            return TriggerClientEvent(Federal.Net('openStudio'), source, 'item', agency.id)
        end
        return say(source, 'Usage: /fedadditem <agency> <item> [minGrade] [price] [label]')
    end

    local label = table.concat(args, ' ', 5)
    local entry, saveMessage = Federal.Armory.AdminSave(source, agency.id, {
        item = item,
        minGrade = tonumber(args[3]) or 0,
        price = tonumber(args[4]) or 0,
        label = label ~= '' and label or nil
    })
    say(source, entry and ('Stocked %s (%s) in the %s armory.'):format(entry.label, entry.item, agency.short) or tostring(saveMessage))
end, {
    help = 'Stock an item in an agency armory.',
    arguments = {
        { name = 'agency', help = 'fib, iaa, doa or usss' },
        { name = 'item', help = 'Inventory item name' },
        { name = 'minGrade', help = 'Minimum grade (optional)' },
        { name = 'price', help = 'Price (optional)' },
        { name = 'label', help = 'Display name (optional)' }
    }
})

DAG.Commands.Register('fedremoveitem', function(source, args)
    local agency, message = commandAgency(source, args[1])
    if not agency then return say(source, message) end

    local entry, removeMessage = Federal.Armory.AdminDelete(source, agency.id, args[2])
    say(source, entry and ('Removed %s from the %s armory.'):format(entry.label, agency.short) or tostring(removeMessage))
end, {
    help = 'Remove an item from an agency armory (see ids with /fedconfig).',
    arguments = {
        { name = 'agency', help = 'fib, iaa, doa or usss' },
        { name = 'item', help = 'Armory entry id' }
    }
})

-- /fedranks <agency>: the rank loadout editor - tie uniforms, armory items
-- and vehicles to specific ranks from one menu.
DAG.Commands.Register('fedranks', function(source, args)
    if source == 0 then return Bridge.Print('this command is for players') end
    local agency, message = commandAgency(source, args[1])
    if not agency then return say(source, message) end

    local editableAgency, editMessage = Federal.Editor.Editable(source, agency.id)
    if not editableAgency then return say(source, tostring(editMessage)) end

    TriggerClientEvent(Federal.Net('openStudio'), source, 'ranks', agency.id)
end, {
    help = 'Open the rank loadout editor: tie uniforms, items and vehicles to ranks.',
    arguments = { { name = 'agency', help = 'fib, iaa, doa or usss' } },
    allowConsole = false
})

-- /feddivision <agency> [add <name...> | remove <id> | list]: sub-departments.
DAG.Commands.Register('feddivision', function(source, args)
    local agency, message = commandAgency(source, args[1])
    if not agency then return say(source, message) end

    local action = (args[2] or ''):lower()

    if action == 'add' then
        local label = table.concat(args, ' ', 3)
        if label == '' then return say(source, 'Usage: /feddivision <agency> add <name>') end
        local division, saveMessage = Federal.Editor.SaveDivision(source, agency.id, { label = label })
        return say(source, division and ('Created division %s (id %s).'):format(division.label, division.id) or tostring(saveMessage))
    end

    if action == 'remove' then
        local division, removeMessage = Federal.Editor.DeleteDivision(source, agency.id, args[3])
        return say(source, division and ('Removed division %s.'):format(division.label) or tostring(removeMessage))
    end

    if action == 'list' or action == '' then
        local divisions = Federal.Core.Agency(agency.id).divisions or {}
        if #divisions == 0 then return say(source, ('%s has no divisions. Add one with /feddivision %s add <name>.'):format(agency.short, agency.id)) end
        for _, division in ipairs(divisions) do
            say(source, ('  %s - %s%s'):format(division.id, division.label,
                (division.minGrade or 0) > 0 and (' (grade %d+)'):format(division.minGrade) or ''))
        end
        return
    end

    -- Anything else opens the menu-driven manager in game.
    if source > 0 then
        TriggerClientEvent(Federal.Net('openStudio'), source, 'divisions', agency.id)
    end
end, {
    help = 'Manage agency sub-departments: add, remove, list.',
    arguments = {
        { name = 'agency', help = 'fib, iaa, doa or usss' },
        { name = 'action', help = 'add, remove or list' },
        { name = 'value', help = 'Division name (add) or id (remove)' }
    }
})

-- /fedconfig [agency]: opens the configuration GUI. Access: the federal.admin
-- ACE, or the HIGHEST rank of the agency you work for. `text` after the
-- agency (or running it from the console) prints the plain-text dump instead.
DAG.Commands.Register('fedconfig', function(source, args)
    -- A nil module here means the server is running an OLD manifest: FiveM
    -- caches the resource file list, so files added to fxmanifest.lua only
    -- load after `refresh` + `ensure` (a plain restart is not enough).
    if not Federal.ConfigPanel then
        return say(source, 'Server files changed: run `refresh` then `ensure dag-federal-agencies` in the server console (a plain restart does not reload the manifest).')
    end

    local wantsText = source == 0 or (args[2] and args[2]:lower() == 'text')

    if not wantsText then
        local agency, message = Federal.ConfigPanel.CanOpen(source, args[1] and args[1]:lower() or nil)
        if not agency then return say(source, tostring(message)) end
        return TriggerClientEvent(Federal.Net('openConfig'), source, agency.id)
    end

    local agency, message = commandAgency(source, args[1])
    if not agency then return say(source, message) end

    local editableAgency, editMessage = Federal.Editor.Editable(source, agency.id)
    if not editableAgency then return say(source, tostring(editMessage)) end

    say(source, ('%s (%s) - boss grade %d, jobs: %s'):format(agency.label, agency.id, agency.bossGrade or 4, table.concat(agency.jobs or {}, ', ')))

    for _, station in ipairs(agency.stations or {}) do
        say(source, ('Station %s (id %s) at %.1f, %.1f, %.1f'):format(station.label, station.id, station.coords.x, station.coords.y, station.coords.z))
        for _, zone in ipairs(station.zones or {}) do
            say(source, ('  room %s [%s] at %.1f, %.1f, %.1f'):format(zone.label, zone.kind, zone.coords.x, zone.coords.y, zone.coords.z))
        end
    end

    for _, rank in ipairs(agency.ranks or {}) do
        say(source, ('Rank %d: %s'):format(rank.grade, rank.label))
    end
    for _, division in ipairs(agency.divisions or {}) do
        say(source, ('Division %s (id %s)%s'):format(division.label, division.id,
            (division.minGrade or 0) > 0 and (' - grade %d+'):format(division.minGrade) or ''))
    end
    for _, uniform in ipairs(agency.uniforms or {}) do
        say(source, ('Uniform %s (id %s) - grade %d+, %s'):format(uniform.label, uniform.id, uniform.minGrade or 0, uniform.variant or 'any'))
    end
    for _, entry in ipairs(agency.armory or {}) do
        say(source, ('Armory %s (id %s) - %s, grade %d+, $%d'):format(entry.label, entry.id, entry.item, entry.minGrade or 0, entry.price or 0))
    end
    for _, entry in ipairs(Federal.Armory.Vehicles(agency.id)) do
        say(source, ('Vehicle %s (id %s) - %s%s'):format(entry.label, entry.id, entry.model, entry.props and ' [saved mods]' or ''))
    end
    for _, door in ipairs(Federal.Doors.List(agency.id)) do
        say(source, ('Door %s (id %s) - grade %d+, %s'):format(door.label, door.id, door.minGrade or 0, door.locked and 'locked' or 'unlocked'))
    end
end, {
    help = 'Open the agency configuration GUI (append "text" for a chat dump).',
    arguments = {
        { name = 'agency', help = 'fib, iaa, doa or usss (defaults to yours)' },
        { name = 'mode', help = "'text' for the chat dump instead of the GUI" }
    }
})

-- /feddoor <agency> [minGrade] [label...]: register the door or gate you are
-- aiming at as an agency-locked door.
DAG.Commands.Register('feddoor', function(source, args)
    if source == 0 then return Bridge.Print('this command is for players') end
    if not Federal.Doors then
        return say(source, 'Server files changed: run `refresh` then `ensure dag-federal-agencies` in the server console.')
    end
    local agency, message = commandAgency(source, args[1])
    if not agency then return say(source, message) end

    local editableAgency, editMessage = Federal.Editor.Editable(source, agency.id)
    if not editableAgency then return say(source, tostring(editMessage)) end

    local minGrade = tonumber(args[2])
    local label = table.concat(args, ' ', minGrade and 3 or 2)
    TriggerClientEvent(Federal.Net('captureDoor'), source, agency.id,
        label ~= '' and label or nil, minGrade or 0)
end, {
    help = 'Register the door you are aiming at as an agency-locked door.',
    arguments = {
        { name = 'agency', help = 'fib, iaa, doa or usss' },
        { name = 'minGrade', help = 'Grade that may control it (optional)' },
        { name = 'label', help = 'Door name (optional)' }
    },
    allowConsole = false
})

-- A rebuild is the escape hatch when a store file is edited by hand while the
-- server is up: it reloads the registry and pushes it to every client.
DAG.Commands.Register(prefix .. ':reload', function(source)
    Core.Invalidate()
    Federal.Callouts.Invalidate()
    if Federal.Court then Federal.Court.Invalidate() end
    Core.Sync()
    report(source, ('Reloaded %d agencies and %d callout templates.'):format(
        #Core.Agencies(), #Federal.Callouts.Templates()))
end, {
    help = 'Reload agencies, courthouses and callout templates.',
    permission = 'federal.admin'
})

return true
