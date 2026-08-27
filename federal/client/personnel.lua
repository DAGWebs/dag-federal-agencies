-- The personnel side of the boss office: who works here, hiring the person
-- standing in front of you, moving people up and down the ladder, and the
-- audit log of who did what.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local State = Federal.State
local Personnel = {}
Federal.Personnel = Personnel

local function id(name)
    return Federal.Menus.Id('personnel:' .. name)
end

local function show(menuId, title, subtitle, options)
    Federal.CAD.Show(menuId, title, subtitle, options)
end

local function ask(callback)
    Bridge.TriggerCallback(Federal.Net('personnel:roster'), function(payload)
        callback(payload or { supported = false, roster = {}, candidates = {}, ceiling = 0 })
    end)
end

function Personnel.Open()
    ask(function(payload)
        local options = {}

        -- A framework with no setJob cannot hire at all. Saying so once, at the
        -- top, beats every action below failing one at a time.
        if not payload.supported then
            options[#options + 1] = {
                title = 'Hiring is unavailable',
                description = 'This framework cannot change jobs. Extend the bridge adapter with setJob.',
                icon = 'close',
                badge = 'Unsupported',
                badgeTone = 'danger',
                disabled = true
            }
        end

        options[#options + 1] = { title = 'Roster', header = true }
        for _, member in ipairs(payload.roster) do
            options[#options + 1] = {
                title = member.name,
                description = ('%s | grade %d'):format(member.rank, member.grade),
                icon = 'user',
                badge = member.onDuty and 'On duty' or 'Off duty',
                badgeTone = member.onDuty and 'success' or nil,
                onSelect = function() Personnel.Member(member, payload.ceiling) end
            }
        end
        if #payload.roster == 0 then
            options[#options + 1] = { title = 'Nobody is online', disabled = true }
        end

        options[#options + 1] = { title = 'Hire', header = true }
        for _, candidate in ipairs(payload.candidates) do
            options[#options + 1] = {
                title = candidate.name,
                description = ('Currently: %s'):format(candidate.job),
                icon = 'check',
                badge = 'Hire',
                badgeTone = 'accent',
                disabled = not payload.supported,
                onSelect = function()
                    DAG.Menu.Confirm(('Hire %s?'):format(candidate.name), 'They join on the entry rank.',
                        function(confirmed)
                            if not confirmed then return end
                            TriggerServerEvent(Federal.Net('personnel:hire'), candidate.source)
                            Personnel.Reopen()
                        end)
                end
            }
        end
        if #payload.candidates == 0 then
            options[#options + 1] = {
                title = 'Nobody nearby to hire',
                description = 'They have to be standing with you',
                disabled = true
            }
        end

        options[#options + 1] = { title = 'Records', header = true }
        options[#options + 1] = { title = 'Personnel history', icon = 'info', onSelect = Personnel.History }

        show(id('root'), 'Personnel', State.Mine() and State.Mine().label or nil, options)
    end)
end

-- The server is the one that actually changed anything, so the menu is rebuilt
-- from a fresh read rather than from what it had a moment ago.
function Personnel.Reopen()
    SetTimeout(250, function() Personnel.Open() end)
end

function Personnel.Member(member, ceiling)
    local agency = State.Mine()
    if not agency then return end

    local options = {
        { title = member.name, description = ('%s | grade %d'):format(member.rank, member.grade), disabled = true },
        { title = 'Rank', header = true }
    }

    for _, rank in ipairs(agency.ranks or {}) do
        local tooHigh = rank.grade > (ceiling or 0)
        local current = rank.grade == member.grade
        options[#options + 1] = {
            title = rank.label,
            description = tooHigh and 'Above what your own rank may appoint' or nil,
            icon = current and 'check' or 'user',
            badge = current and 'Current' or ('Grade %d'):format(rank.grade),
            badgeTone = current and 'success' or (tooHigh and 'danger' or nil),
            disabled = current or tooHigh,
            onSelect = function()
                TriggerServerEvent(Federal.Net('personnel:grade'), member.source, rank.grade)
                Personnel.Reopen()
            end
        }
    end

    options[#options + 1] = { title = 'Employment', header = true }
    options[#options + 1] = {
        title = 'Dismiss from the agency',
        icon = 'close',
        badgeTone = 'danger',
        onSelect = function()
            DAG.Menu.Confirm(('Dismiss %s?'):format(member.name), 'They return to the unemployed job.',
                function(confirmed)
                    if not confirmed then return end
                    TriggerServerEvent(Federal.Net('personnel:fire'), member.source)
                    Personnel.Reopen()
                end)
        end
    }

    show(id('member'), member.name, member.rank, options)
end

function Personnel.History()
    Bridge.TriggerCallback(Federal.Net('personnel:history'), function(entries)
        local options = {}
        for _, entry in ipairs(entries or {}) do
            options[#options + 1] = {
                title = ('%s %s'):format(entry.action, entry.subject),
                description = ('by %s%s'):format(entry.by, entry.detail and (' - ' .. entry.detail) or ''),
                icon = 'info',
                badge = os.date('%d %b %H:%M', entry.at or 0),
                disabled = true
            }
        end
        show(id('history'), 'Personnel history', ('%d change(s)'):format(#(entries or {})), options)
    end)
end

return Personnel
