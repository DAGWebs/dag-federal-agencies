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
