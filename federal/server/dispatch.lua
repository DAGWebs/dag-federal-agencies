-- Dispatch alerts.
--
-- Most servers already run a dispatch resource, and two alert systems shouting
-- over each other is worse than either alone. This picks one: whichever
-- supported resource is started, or the built-in notification when none is.
--
-- Every alert in the resource goes through Dispatch.Alert, so a server that
-- swaps dispatch resources changes one config line rather than hunting for
-- notification calls.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Core = Federal.Core

local Dispatch = {}
Federal.Dispatch = Dispatch

local function settings()
    return (Config.Federal or {}).dispatch or {}
end

-- Providers, in the order 'auto' prefers them. Each is a resource name and the
-- shape it wants an alert in.
local PROVIDERS = {
    { name = 'ps-dispatch', send = function(alert)
        exports['ps-dispatch']:CustomAlert({
            coords = alert.coords,
            message = alert.message,
            dispatchCode = alert.code,
            description = alert.title,
            radius = 0,
            sprite = alert.sprite or 480,
            color = alert.colour or 5,
            scale = 1.0,
            length = 3,
            jobs = alert.jobs
        })
    end },
    { name = 'cd_dispatch', send = function(alert)
        TriggerEvent('cd_dispatch:AddNotification', {
            job_table = alert.jobs,
            coords = alert.coords,
            title = alert.code or alert.title,
            message = alert.message,
            flash = 0,
            unique_id = alert.id,
            blip = {
                sprite = alert.sprite or 480,
                scale = 1.0,
                colour = alert.colour or 5,
                flashes = false,
                text = alert.title,
                time = 3
            }
        })
    end },
    { name = 'linden_outlawalert', send = function(alert)
        TriggerEvent('wf-alerts:svNotify', {
            dispatchData = {
                displayCode = alert.code or '10-90',
                description = alert.title,
                isImportant = alert.priority and alert.priority >= 3 and 1 or 0,
                recipientList = alert.jobs,
                length = '10000',
                infoM = 'fa-info-circle',
                info = alert.message
            },
            caller = alert.caller or 'Dispatch',
            coords = alert.coords
        })
    end }
}

Dispatch.Providers = PROVIDERS

-- Which provider is actually going to handle this. Returns nil for the
-- built-in path.
function Dispatch.Provider()
    local configured = settings().provider or 'auto'
    if configured == 'internal' then return nil end

    for _, provider in ipairs(PROVIDERS) do
        if configured == provider.name then
            -- Explicitly named but not running is worth saying out loud once,
            -- rather than silently falling back and looking broken.
            if GetResourceState(provider.name) == 'started' then return provider end
            Dispatch.WarnMissing(provider.name)
            return nil
        end
    end

    if configured ~= 'auto' then return nil end
    for _, provider in ipairs(PROVIDERS) do
        if GetResourceState(provider.name) == 'started' then return provider end
    end
    return nil
end

local warned = {}

function Dispatch.WarnMissing(name)
    if warned[name] then return end
    warned[name] = true
    Bridge.Print("dispatch provider '%s' is configured but not started; using the built-in alert", name)
end

-- The job names an alert should reach, which is what every external provider
-- filters on.
function Dispatch.JobsFor(agencyId)
    local agency = Core.Agency(agencyId)
    if not agency then return {} end
    return agency.jobs or {}
end

-- The one entry point. `alert` carries coords, a title, a message and the
-- agency it belongs to; everything else is optional.
function Dispatch.Alert(alert)
    if type(alert) ~= 'table' or type(alert.coords) ~= 'table' then return false end

    alert.jobs = alert.jobs or Dispatch.JobsFor(alert.agency)
    alert.id = alert.id or ('federal-%d'):format(os.time())

    local provider = Dispatch.Provider()
    if provider then
        local ok, err = pcall(provider.send, alert)
        if not ok then
            -- A provider that errors must not take the alert with it: the
            -- officers still need to hear about this.
            Bridge.Print("dispatch provider '%s' errored: %s", provider.name, tostring(err))
            Dispatch.Internal(alert)
            return true
        end
        if settings().alsoInternal == true then Dispatch.Internal(alert) end
        return true
    end

    Dispatch.Internal(alert)
    return true
end

-- The built-in path: a notification and a blip for every on-duty officer of
-- the agency, which is what the resource did before any of this existed.
function Dispatch.Internal(alert)
    for _, playerSource in ipairs(Core.OnDutySources(alert.agency)) do
        TriggerClientEvent(Federal.Net('dispatch'), playerSource, {
            title = alert.title,
            message = alert.message,
            coords = alert.coords,
            sprite = alert.sprite,
            colour = alert.colour,
            priority = alert.priority,
            code = alert.code
        })
    end
    return true
end

return Dispatch
