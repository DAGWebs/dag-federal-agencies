-- Serving the sentence.
--
-- The court used to pass sentence and stop: it fired an event and left the
-- payoff of the whole process to a resource the server owner had to go and
-- find. This is that resource, and it is optional -- `federal:sentenced` still
-- fires, so an existing jail script can consume it and this one can be
-- switched off.
--
-- Time is counted in wall-clock seconds against a release timestamp rather
-- than ticked down, so it survives a restart and, when configured, keeps
-- running while the inmate is offline. Otherwise the obvious play is to
-- disconnect for the length of the sentence.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Util = Federal.Util
local Core = Federal.Core
local CAD = Federal.CAD

local Jail = {}
Federal.Jail = Jail

local inmates = DAG.Repository.Create('federal_inmates')
Jail.inmates = inmates

local function fail(message)
    return nil, message
end

local function settings()
    return (Config.Federal or {}).jail or {}
end

function Jail.Enabled()
    return Core.Enabled() and settings().enabled ~= false
end

-- Sentence length in real seconds, bounded so a life sentence is not a life
-- sentence.
function Jail.Seconds(months)
    local perMonth = tonumber(settings().secondsPerMonth) or 20
    local maximum = tonumber(settings().maximumSeconds) or 3600
    local seconds = math.floor((tonumber(months) or 0) * perMonth)
    return math.max(0, math.min(seconds, maximum))
end

function Jail.Record(identifier)
    if type(identifier) ~= 'string' then return nil end
    return inmates.get(identifier)
end

-- Seconds left to serve. Offline time counts when `serveOffline` is on; when
-- it is off, the clock is pushed forward by however long they were away.
function Jail.Remaining(identifier, nowSeconds)
    local record = Jail.Record(identifier)
    if not record then return 0 end

    nowSeconds = nowSeconds or os.time()
    return math.max(0, math.floor((record.releaseAt or 0) - nowSeconds))
end

function Jail.Commit(payload)
    if not Jail.Enabled() then return fail('the jail is disabled') end
    payload = type(payload) == 'table' and payload or {}

    local identifier = Util.Text(payload.identifier, 80)
    if not identifier then return fail('a committal requires an identifier') end

    local seconds = Jail.Seconds(payload.months)
    if seconds <= 0 then return fail('that sentence carries no custodial time') end

    local nowSeconds = os.time()
    local existing = Jail.Record(identifier)

    -- Consecutive, not concurrent: a second conviction while inside adds to
    -- what is left rather than replacing it.
    local base = existing and math.max(existing.releaseAt or 0, nowSeconds) or nowSeconds

    local record = {
        identifier = identifier,
        name = Util.Text(payload.name, 60, existing and existing.name or 'Unknown inmate'),
        caseNumber = payload.caseNumber or (existing and existing.caseNumber),
        months = (existing and existing.months or 0) + (tonumber(payload.months) or 0),
        committedAt = existing and existing.committedAt or nowSeconds,
        releaseAt = base + seconds,
        confiscated = existing and existing.confiscated or nil,
        labourAt = existing and existing.labourAt or 0
    }

    inmates.save(identifier, record)
    CAD.Note(identifier, record.name,
        ('Committed to custody for %d month(s)%s'):format(
            tonumber(payload.months) or 0,
            payload.caseNumber and (' on ' .. payload.caseNumber) or ''))

    local target = Jail.SourceFor(identifier)
    if target then Jail.Deliver(target, record) end
    return record
end

function Jail.SourceFor(identifier)
    for _, playerId in ipairs(GetPlayers()) do
        local playerSource = tonumber(playerId)
        if playerSource and Bridge.GetIdentifier(playerSource) == identifier then return playerSource end
    end
    return nil
end

-- Puts a player who is online inside, and takes their contraband.
function Jail.Deliver(target, record)
    if settings().confiscate ~= false then Jail.Confiscate(target, record) end

    TriggerClientEvent(Federal.Net('jailed'), target, {
        cells = settings().cells,
        remaining = Jail.Remaining(record.identifier),
        leash = settings().leash,
        name = record.name,
        caseNumber = record.caseNumber
    })
    Bridge.Notify(target, ('You are in custody for %d month(s).'):format(record.months or 0), 'error')
end

-- Contraband is held, not destroyed: it comes back on release, which is what
-- makes taking it a consequence rather than a punishment.
function Jail.Confiscate(target, record)
    local held = {}
    for _, item in ipairs((Config.Federal or {}).contraband or {}) do
        local count = Bridge.GetItemCount(target, item)
        if count and count > 0 and Bridge.RemoveItem(target, item, count) then
            held[#held + 1] = { item = item, count = count }
        end
    end

    if #held == 0 then return record end
    record.confiscated = held
    inmates.save(record.identifier, record)
    return record
end

function Jail.ReturnProperty(target, record)
    for _, entry in ipairs(record.confiscated or {}) do
        Bridge.AddItem(target, entry.item, entry.count)
    end
    record.confiscated = nil
    return record
end

function Jail.Release(identifier, reason)
    local record = Jail.Record(identifier)
    if not record then return fail('they are not in custody') end

    local target = Jail.SourceFor(identifier)
    if target then
        Jail.ReturnProperty(target, record)
        TriggerClientEvent(Federal.Net('released'), target, { release = settings().release })
        Bridge.Notify(target, 'You have been released.', 'success')
    end

    inmates.delete(identifier)
    CAD.Note(identifier, record.name, reason or 'Released from custody')
    TriggerEvent(Federal.Net('released:server'), { identifier = identifier, name = record.name, reason = reason })
    return record
end

-- An officer letting somebody out early: a pardon, a successful appeal, or
-- time served.
function Jail.ReleaseEarly(source, identifier, reason)
    local membership = Core.Require(source, 'actions.arrest')
    if not membership then return fail('not authorized') end

    local record = Jail.Record(identifier)
    if not record then return fail('they are not in custody') end

    return Jail.Release(identifier, reason or ('Released early by %s'):format(membership.name))
end

-- Labour: work inside to take time off. Cheap to offer and it stops a sentence
-- being a screen you stare at.
function Jail.Labour(source)
    local labour = settings().labour or {}
    if labour.enabled == false then return fail('there is no work available') end

    local identifier = Bridge.GetIdentifier(source)
    local record = Jail.Record(identifier)
    if not record then return fail('you are not in custody') end

    local nowSeconds = os.time()
    local cooldown = tonumber(labour.cooldown) or 45
    if (nowSeconds - (record.labourAt or 0)) < cooldown then
        return fail('you have only just finished a task')
    end

    local reward = tonumber(labour.reward) or 60
    record.labourAt = nowSeconds
    record.releaseAt = math.max(nowSeconds, (record.releaseAt or nowSeconds) - reward)
    inmates.save(identifier, record)

    local remaining = Jail.Remaining(identifier, nowSeconds)
    if remaining <= 0 then
        Jail.Release(identifier, 'Released after time served')
        return { released = true, remaining = 0 }
    end

    return { released = false, remaining = remaining, reduced = reward }
end

function Jail.Roster()
    local list = {}
    local nowSeconds = os.time()
    for identifier, record in pairs(inmates.all()) do
        list[#list + 1] = {
            identifier = identifier,
            name = record.name,
            caseNumber = record.caseNumber,
            months = record.months,
            remaining = Jail.Remaining(identifier, nowSeconds),
            online = Jail.SourceFor(identifier) ~= nil
        }
    end
    table.sort(list, function(a, b) return (a.remaining or 0) > (b.remaining or 0) end)
    return list
end

-- A player who logs in mid-sentence goes straight back inside. When offline
-- time does not count, their release is pushed back by the time they were away.
function Jail.Resume(target)
    if not Jail.Enabled() then return nil end

    local identifier = Bridge.GetIdentifier(target)
    local record = Jail.Record(identifier)
    if not record then return nil end

    local nowSeconds = os.time()
    if settings().serveOffline == false and record.leftAt then
        record.releaseAt = (record.releaseAt or nowSeconds) + (nowSeconds - record.leftAt)
    end
    record.leftAt = nil
    inmates.save(identifier, record)

    if Jail.Remaining(identifier, nowSeconds) <= 0 then
        return Jail.Release(identifier, 'Released after time served')
    end

    Jail.Deliver(target, record)
    return record
end

function Jail.Tick(nowSeconds)
    if not Jail.Enabled() then return 0 end
    nowSeconds = nowSeconds or os.time()

    local released = 0
    for identifier in pairs(inmates.all()) do
        if Jail.Remaining(identifier, nowSeconds) <= 0 then
            Jail.Release(identifier, 'Released after time served')
            released = released + 1
        end
    end
    return released
end

-- Wiring -------------------------------------------------------------------------

-- The court raises this; so could any other resource that sentences somebody.
AddEventHandler(Federal.Net('sentenced'), function(sentence)
    if not Jail.Enabled() or type(sentence) ~= 'table' then return end
    if (tonumber(sentence.months) or 0) <= 0 then return end

    Jail.Commit({
        identifier = sentence.identifier,
        name = sentence.name,
        months = sentence.months,
        caseNumber = sentence.number
    })
end)

AddEventHandler('playerDropped', function()
    local dropped = source
    local identifier = Bridge.GetIdentifier(dropped)
    local record = identifier and Jail.Record(identifier)
    if not record then return end

    -- Stamped so the clock can be corrected on return when offline time is
    -- not meant to count.
    record.leftAt = os.time()
    inmates.save(identifier, record)
end)

Bridge.RegisterCallback(Federal.Net('jail:status'), function(source, reply)
    local identifier = Bridge.GetIdentifier(source)
    local record = Jail.Record(identifier)
    reply(record and {
        name = record.name,
        caseNumber = record.caseNumber,
        months = record.months,
        remaining = Jail.Remaining(identifier)
    } or nil)
end)

Bridge.RegisterCallback(Federal.Net('jail:roster'), function(source, reply)
    reply(Core.Can(source, 'cad.view') and Jail.Roster() or {})
end)

Bridge.RegisterCallback(Federal.Net('jail:labour'), function(source, reply)
    local result, message = Jail.Labour(source)
    reply(result, message)
end)

RegisterNetEvent(Federal.Net('jail:release'), function(identifier)
    local playerSource = source
    if type(identifier) ~= 'string' then return end
    local record, message = Jail.ReleaseEarly(playerSource, identifier)
    Bridge.Notify(playerSource, record and ('Released %s.'):format(record.name) or message,
        record and 'success' or 'error')
end)

-- A player who logs in mid-sentence goes straight back inside.
AddEventHandler('playerJoining', function()
    local joined = source
    SetTimeout(5000, function() Jail.Resume(joined) end)
end)

CreateThread(function()
    while true do
        Wait(10000)
        Jail.Tick()
    end
end)

return Jail
