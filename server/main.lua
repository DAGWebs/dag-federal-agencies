local Bridge = DAG.Framework

-- Startup capability report. Unsupported adapter methods now return nil rather
-- than a fabricated 0/unemployed, so this line is where you find out that (for
-- example) the active core cannot report jobs before a gate silently denies
-- every player.
CreateThread(function()
    Bridge.AwaitReady(10000)
    Bridge.Print('framework adapter: %s', Bridge.Detect())
    if not Config.ReportCapabilities then return end

    local missing = Bridge.MissingCapabilities()
    if #missing == 0 then return end
    Bridge.Print('unsupported on this framework: %s', table.concat(missing, ', '))
    Bridge.Print('extend it with DAG.Framework.ExtendAdapter(%q, { ... }) if your server needs them', Bridge.Detect())
end)

-- Keep this entrypoint for your resource. The bridge reads framework-owned
-- player state; repositories should only contain data owned by your resource.
Bridge.RegisterCallback(Bridge.Event('getPlayerContext'), function(source, reply)
    reply({
        identifier = Bridge.GetIdentifier(source),
        name = Bridge.GetName(source),
        job = Bridge.GetJob(source),
        framework = Bridge.Detect()
    })
end)

-- Public integration surface for other resources to file a report into this
-- CAD without needing an on-duty officer or knowing the CAD internals. Used by
-- dag-banking's fraud module, but generic: an alarm panel, a shop, anything.
--
--   exports['dag-federal-agencies']:FileReport({
--       agency   = 'fib',                 -- agency id; defaults to the first agency
--       title    = 'Wire fraud',
--       message  = 'Fraudulent charge on a stolen card at Legion ATM',
--       coords   = vector3(x, y, z),      -- or { x, y, z }
--       code     = '10-90', priority = 2,
--       caller   = 'Fleeca Fraud Desk',
--       suspect  = { identifier = '...', name = 'John Doe', charges = { 'Fraud' } },
--       alsoJobs = { 'police' },          -- extra job names to alert
--       incident = true,                  -- also file a durable CAD incident
--       reference = 'fin:license:abc'     -- OPTIONAL investigation key: when an
--                                         -- open incident already carries this
--                                         -- reference, the message is appended
--                                         -- to it as an anonymous tip (and the
--                                         -- suspect/charges merged) instead of
--                                         -- opening a second case. This is how a
--                                         -- pattern of crime reads as tips
--                                         -- coming into one ongoing call.
--   })
--
-- Returns { dispatched = bool, incident = number|nil, updated = bool } or false
-- when reporting is impossible (no such agency and no fallback).
local function mergeList(target, additions)
    if type(additions) ~= 'table' then return target end
    target = target or {}
    for _, value in ipairs(additions) do
        local has = false
        for _, existing in ipairs(target) do if existing == value then has = true break end end
        if not has then target[#target + 1] = value end
    end
    return target
end

local function fileReport(request)
    if type(request) ~= 'table' then return false end
    local Federal = DAG.Federal
    if not Federal or not Federal.Dispatch or not Federal.Core then return false end

    local agencyId = request.agency
    if not agencyId or not Federal.Core.Agency(agencyId) then
        local first = (Federal.Core.Agencies() or {})[1]
        agencyId = first and first.id or nil
    end
    if not agencyId then return false end

    local coords = request.coords or request.location
    if type(coords) ~= 'table' then coords = { x = 0.0, y = 0.0, z = 0.0 } end

    -- Collect the agency's own jobs plus any extra jobs requested.
    local jobs = {}
    for _, job in ipairs(Federal.Dispatch.JobsFor(agencyId)) do jobs[#jobs + 1] = job end
    if type(request.alsoJobs) == 'table' then
        for _, job in ipairs(request.alsoJobs) do jobs[#jobs + 1] = job end
    end

    local dispatched = Federal.Dispatch.Alert({
        agency = agencyId,
        title = request.title or 'Report',
        message = request.message or '',
        coords = coords,
        caller = request.caller,
        code = request.code,
        priority = request.priority,
        sprite = request.sprite,
        colour = request.colour,
        jobs = jobs
    }) == true

    local incidentNumber, updated = nil, false
    if request.incident and Federal.CAD then
        local repo = DAG.Repository.Create('federal_incidents')

        -- An open case already tagged with this reference: append the tip.
        local existing = nil
        if request.reference then
            for _, incident in pairs(repo.all()) do
                if incident.reference == request.reference and incident.agency == agencyId
                    and incident.status ~= 'closed' then
                    existing = incident
                    break
                end
            end
        end

        if existing then
            existing.narrative = existing.narrative or {}
            table.insert(existing.narrative, {
                author = request.caller or 'Anonymous tip',
                text = request.message or '',
                at = os.time()
            })
            if request.suspect and request.suspect.identifier then
                existing.suspects = existing.suspects or {}
                local seen = false
                for _, suspect in ipairs(existing.suspects) do
                    if suspect.identifier == request.suspect.identifier then seen = true break end
                end
                if not seen then existing.suspects[#existing.suspects + 1] = request.suspect end
            end
            existing.charges = mergeList(existing.charges, request.charges)
            -- A lower number is a higher priority; a fresh tip can escalate.
            if request.priority and (not existing.priority or request.priority < existing.priority) then
                existing.priority = request.priority
            end
            existing.updatedAt = os.time()
            repo.save(existing.id, existing)
            incidentNumber, updated = existing.number, true

        elseif Federal.CAD.FileSystemIncident then
            local record = Federal.CAD.FileSystemIncident(agencyId, {
                title = request.title or 'Report',
                type = request.type or 'Financial crime',
                priority = request.priority,
                location = coords,
                narrative = request.message,
                charges = request.charges,
                suspect = request.suspect,
                source = request.caller
            })
            if record then
                incidentNumber = record.number
                -- Tag the new case so later tips find and update it.
                if request.reference then
                    record.reference = request.reference
                    repo.save(record.id, record)
                end
                -- A caller-supplied witness flow: what NPCs near the scene
                -- say when officers interview them.
                if request.investigation and Federal.Investigation then
                    Federal.Investigation.SetFlow(record.id, request.investigation)
                end
            end
        end
    end

    return { dispatched = dispatched, incident = incidentNumber, updated = updated }
end

exports('FileReport', fileReport)
-- Alias kept descriptive for financial callers.
exports('FileFinancialCrime', fileReport)

DAG.Commands.Register(Bridge.namespace .. ':framework', function(source)
    local job = source > 0 and Bridge.GetJob(source)
    local message = ('Framework: %s | identifier: %s | job: %s'):format(
        Bridge.Detect(),
        source > 0 and (Bridge.GetIdentifier(source) or 'unknown') or 'console',
        job and ('%s (%s)'):format(job.name, job.grade) or 'unavailable'
    )
    if source == 0 then Bridge.Print(message) else Bridge.Notify(source, message, 'inform') end
end, { help = 'Show the active framework adapter.' })
