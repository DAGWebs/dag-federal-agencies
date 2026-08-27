-- Reports from the public.
--
-- Before this, every callout came from a timer, which means the same seven
-- cases forever. A player who phones something in is the only source of work
-- nobody could have predicted, and it costs the server nothing to listen.
--
-- A report is dispatchable in its own right: it lands on the board with a
-- location and a caller, and officers respond to it directly. When the text
-- matches a configured keyword it also escalates into a full investigation
-- callout, so a phone call can become a case.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Util = Federal.Util
local Core = Federal.Core

local Reports = {}
Federal.Reports = Reports

-- In memory on purpose: a report is live work, not a record. Anything worth
-- keeping becomes a CAD incident when an officer files one.
local active, sequence = {}, 0
local cooldowns = {}

Reports.active = active

local function fail(message)
    return nil, message
end

local function settings()
    return (Config.Federal or {}).reports or {}
end

function Reports.Enabled()
    return Core.Enabled() and settings().enabled ~= false
end

function Reports.Count()
    local total = 0
    for _ in pairs(active) do total = total + 1 end
    return total
end

-- Who may call it in. Defaults to everybody, because restricting who can report
-- a crime is a strange thing for a server to want.
function Reports.CanReport(source)
    if not Reports.Enabled() then return false end

    local allowed = settings().jobs
    if type(allowed) ~= 'table' then return true end

    local job = Bridge.GetJob(source)
    return job ~= nil and Util.Contains(allowed, job.name)
end

local function onCooldown(source, nowSeconds)
    local last = cooldowns[source]
    local wait = tonumber(settings().cooldown) or 60
    return last ~= nil and (nowSeconds - last) < wait
end

Reports.OnCooldown = onCooldown

-- Which agency should hear about this. A report naming an escalation keyword
-- goes to an agency that runs that template; otherwise it goes to whichever
-- agency has officers on duty, so a call is never filed to an empty room.
function Reports.RouteTo(templateId)
    local staffed = {}
    for _, agency in ipairs(Core.Agencies()) do
        if #Core.OnDutySources(agency.id) > 0 then staffed[#staffed + 1] = agency end
    end
    if #staffed == 0 then return nil end

    if templateId and Federal.Callouts then
        for _, agency in ipairs(staffed) do
            for _, template in ipairs(Federal.Callouts.TemplatesFor(agency.id)) do
                if template.id == templateId then return agency.id end
            end
        end
    end
    return staffed[1].id
end

-- Matches the report text against the configured keywords. First match wins,
-- checked in a stable order so the same text always routes the same way.
function Reports.Escalation(text)
    local escalate = settings().escalate
    if type(escalate) ~= 'table' or type(text) ~= 'string' then return nil end

    local haystack = text:lower()
    local keywords = {}
    for keyword in pairs(escalate) do keywords[#keywords + 1] = keyword end
    table.sort(keywords)

    for _, keyword in ipairs(keywords) do
        if haystack:find(keyword, 1, true) then return escalate[keyword], keyword end
    end
    return nil
end

function Reports.Submit(source, payload)
    payload = type(payload) == 'table' and payload or {}
    if not Reports.Enabled() then return fail('the tip line is closed') end
    if not Reports.CanReport(source) then return fail('you cannot call this in') end

    local nowSeconds = os.time()
    if onCooldown(source, nowSeconds) then return fail('you have only just called that in') end

    local text = Util.Text(payload.text, 300)
    if not text then return fail('say what you are reporting') end

    local location = Core.Coords(source)
    if not location then return fail('your position could not be read') end

    local anonymous = payload.anonymous == true and settings().allowAnonymous ~= false
    local templateId, keyword = Reports.Escalation(text)
    local agencyId = Reports.RouteTo(templateId)

    -- Nobody on duty anywhere: the caller is told plainly rather than the
    -- report vanishing into a queue nobody reads.
    if not agencyId then return fail('nobody is on duty to take that right now') end

    sequence = sequence + 1
    local report = {
        id = Util.RecordId('rep', sequence),
        agency = agencyId,
        text = text,
        keyword = keyword,
        anonymous = anonymous,
        -- Withheld from the board when anonymous, but kept here so abuse is
        -- traceable by anyone with server access.
        callerIdentifier = Bridge.GetIdentifier(source),
        caller = anonymous and 'Anonymous' or Bridge.GetName(source),
        callerSource = source,
        location = location,
        status = 'open',
        at = nowSeconds
    }

    active[report.id] = report
    cooldowns[source] = nowSeconds

    if templateId and Federal.Callouts then
        local callout = Federal.Callouts.Dispatch(agencyId, templateId)
        if callout then
            report.calloutId = callout.id
            report.status = 'dispatched'
        end
    end

    Reports.Broadcast(report)
    return Reports.View(report)
end

-- What officers see. The caller is withheld on an anonymous tip.
function Reports.View(report)
    return {
        id = report.id,
        agency = report.agency,
        text = report.text,
        caller = report.caller,
        anonymous = report.anonymous,
        location = report.location,
        status = report.status,
        calloutId = report.calloutId,
        at = report.at
    }
end

function Reports.Broadcast(report)
    for _, playerSource in ipairs(Core.OnDutySources(report.agency)) do
        TriggerClientEvent(Federal.Net('report'), playerSource, Reports.View(report))
    end

    -- New reports also go out through the dispatch layer; updates to an
    -- existing one do not, or every acknowledgement re-alerts the shift.
    if report.status == 'open' and Federal.Dispatch then
        Federal.Dispatch.Alert({
            id = report.id,
            agency = report.agency,
            title = 'Reported incident',
            message = report.text,
            coords = report.location,
            caller = report.caller,
            sprite = 280,
            colour = 1,
            priority = 2,
            code = '10-90'
        })
    end
end

function Reports.Board(source)
    local membership = Core.Membership(source)
    if not membership then return {} end

    local list = {}
    for _, report in pairs(active) do
        if report.agency == membership.agency.id and report.status ~= 'closed' then
            list[#list + 1] = Reports.View(report)
        end
    end
    table.sort(list, function(a, b) return (a.at or 0) > (b.at or 0) end)
    return list
end

function Reports.Get(id)
    return active[id]
end

function Reports.Acknowledge(source, reportId)
    local membership = Core.Require(source, 'actions.detain')
    if not membership then return fail('not authorized') end

    local report = active[reportId]
    if not report then return fail('that report is no longer on the board') end
    if report.agency ~= membership.agency.id then return fail('that report belongs to another agency') end

    report.status = 'responding'
    report.respondedBy = membership.name
    Reports.Broadcast(report)
    return Reports.View(report)
end

function Reports.Close(source, reportId)
    local membership = Core.Require(source, 'actions.detain')
    if not membership then return fail('not authorized') end

    local report = active[reportId]
    if not report then return fail('that report is no longer on the board') end
    if report.agency ~= membership.agency.id then return fail('that report belongs to another agency') end

    report.status = 'closed'
    Reports.Broadcast(report)
    active[reportId] = nil

    if report.callerSource then
        Bridge.Notify(report.callerSource, 'Your report has been dealt with. Thank you.', 'success')
    end
    return Reports.View(report)
end

function Reports.Expire(nowSeconds)
    local limit = tonumber(settings().expire) or 1800
    local removed = 0
    for id, report in pairs(active) do
        if (nowSeconds - (report.at or 0)) > limit then
            active[id] = nil
            removed = removed + 1
        end
    end
    return removed
end

AddEventHandler('playerDropped', function()
    local dropped = source
    cooldowns[dropped] = nil
    -- The report stays on the board; the caller merely stops being reachable.
    for _, report in pairs(active) do
        if report.callerSource == dropped then report.callerSource = nil end
    end
end)

-- Net wiring ---------------------------------------------------------------------

Bridge.RegisterCallback(Federal.Net('report:submit'), function(source, reply, payload)
    local report, message = Reports.Submit(source, payload)
    reply(report, message)
end)

Bridge.RegisterCallback(Federal.Net('reports'), function(source, reply)
    reply(Reports.Board(source))
end)

RegisterNetEvent(Federal.Net('report:ack'), function(reportId)
    local playerSource = source
    if type(reportId) ~= 'string' then return end
    local report, message = Reports.Acknowledge(playerSource, reportId)
    if not report then Bridge.Notify(playerSource, message, 'error') end
end)

RegisterNetEvent(Federal.Net('report:close'), function(reportId)
    local playerSource = source
    if type(reportId) ~= 'string' then return end
    local report, message = Reports.Close(playerSource, reportId)
    Bridge.Notify(playerSource, report and 'Report closed.' or message, report and 'success' or 'error')
end)

CreateThread(function()
    while true do
        Wait(60000)
        if Reports.Enabled() then Reports.Expire(os.time()) end
    end
end)

return Reports
