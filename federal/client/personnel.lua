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
                description = member.division
                    and ('%s | grade %d | %s%s'):format(member.rank, member.grade, member.division,
                        member.divisionRank and (' - ' .. member.divisionRank) or '')
                    or ('%s | grade %d'):format(member.rank, member.grade),
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

    -- Sub-departments. Only offered when the agency has any configured.
    if #(agency.divisions or {}) > 0 then
        options[#options + 1] = { title = 'Division', header = true }
        for _, division in ipairs(agency.divisions) do
            local current = member.divisionId == division.id
            options[#options + 1] = {
                title = division.label,
                icon = current and 'check' or 'user',
                badge = current and 'Current' or ((division.minGrade or 0) > 0 and ('Grade %d+'):format(division.minGrade) or nil),
                badgeTone = current and 'success' or nil,
                disabled = current,
                onSelect = function()
                    TriggerServerEvent(Federal.Net('personnel:division'), member.source, division.id)
                    Personnel.Reopen()
                end
            }
        end
        if member.divisionId then
            -- Promotion within the taskforce: the division's own ladder.
            local division = DAG.Federal.Schema.FindById(agency.divisions, member.divisionId)
            if division and #(division.ranks or {}) > 0 then
                options[#options + 1] = { title = ('%s rank'):format(division.label), header = true }
                for _, rank in ipairs(division.ranks) do
                    local current = member.divisionRank == rank.label
                    options[#options + 1] = {
                        title = rank.label,
                        icon = current and 'check' or 'user',
                        badge = current and 'Current' or ('Grade %d'):format(rank.grade),
                        badgeTone = current and 'success' or nil,
                        disabled = current,
                        onSelect = function()
                            TriggerServerEvent(Federal.Net('personnel:division'), member.source, member.divisionId, rank.grade)
                            Personnel.Reopen()
                        end
                    }
                end
            end

            options[#options + 1] = {
                title = 'Remove from their division',
                icon = 'close',
                onSelect = function()
                    TriggerServerEvent(Federal.Net('personnel:division'), member.source, '')
                    Personnel.Reopen()
                end
            }
        end
    end

    -- Certifications: toggled from the agency's own catalog (/fedconfig).
    options[#options + 1] = { title = 'Certifications', header = true }
    local heldNames = {}
    for _, cert in ipairs(member.certs or {}) do heldNames[#heldNames + 1] = cert.label end
    options[#options + 1] = {
        title = 'Manage certifications',
        description = #heldNames > 0 and table.concat(heldNames, ', ') or 'None awarded yet',
        icon = 'check',
        onSelect = function()
            local catalog = agency.certifications or {}
            if #catalog == 0 then
                return Bridge.Notify('Define certifications in /fedconfig first (Certifications tab).', 'error')
            end
            local held = {}
            for _, cert in ipairs(member.certs or {}) do held[cert.id] = true end
            local picks = {}
            for _, cert in ipairs(catalog) do
                local requires = #(cert.licences or {}) > 0
                    and ('Requires: %s'):format(table.concat(cert.licences, ', ')) or nil
                picks[#picks + 1] = {
                    title = cert.label,
                    description = requires or cert.description
                        or (held[cert.id] and 'Click to revoke' or 'Click to award'),
                    icon = held[cert.id] and 'check' or 'lock',
                    badge = held[cert.id] and 'Awarded' or nil,
                    badgeTone = held[cert.id] and 'success' or nil,
                    onSelect = function()
                        TriggerServerEvent(Federal.Net('personnel:certToggle'), member.source, cert.id)
                        Personnel.Reopen()
                    end
                }
            end
            show(id('certs'), 'Certifications', member.name, picks)
        end
    }

    -- Chain of command: who this member reports to, and who rides with them.
    options[#options + 1] = { title = 'Chain of command', header = true }
    local function pickColleague(title, event)
        ask(function(payload)
            local picks = {}
            for _, colleague in ipairs(payload.roster or {}) do
                if colleague.source ~= member.source then
                    picks[#picks + 1] = {
                        title = colleague.name,
                        description = colleague.rank,
                        icon = 'user',
                        onSelect = function()
                            TriggerServerEvent(Federal.Net(event), member.source, colleague.source)
                            Personnel.Reopen()
                        end
                    }
                end
            end
            picks[#picks + 1] = {
                title = 'None',
                description = 'Clear the assignment',
                icon = 'close',
                onSelect = function()
                    TriggerServerEvent(Federal.Net(event), member.source, 0)
                    Personnel.Reopen()
                end
            }
            show(id('pick'), title, member.name, picks)
        end)
    end
    options[#options + 1] = {
        title = 'Set supervisor',
        description = 'Who this member reports to',
        icon = 'user',
        onSelect = function() pickColleague('Set supervisor', 'personnel:supervisor') end
    }
    options[#options + 1] = {
        title = 'Set partner',
        description = 'Mutual: both files are updated',
        icon = 'user',
        onSelect = function() pickColleague('Set partner', 'personnel:partner') end
    }

    options[#options + 1] = { title = 'Callsign', header = true }
    options[#options + 1] = {
        title = 'Set their callsign',
        description = ('Currently %s - the %s prefix is fixed'):format(
            member.callsign or 'unassigned', member.callsignPrefix or ''),
        icon = 'info',
        badge = member.callsign,
        onSelect = function()
            DAG.Menu.Input(('Callsign for %s'):format(member.name), {
                { name = 'suffix', label = ('Suffix after %s'):format(member.callsignPrefix or ''), required = true }
            }, function(values)
                if not values then return end
                TriggerServerEvent(Federal.Net('callsign:set'), member.source, values.suffix or values[1])
                Personnel.Reopen()
            end)
        end
    }

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
                badge = DAG.Federal.Util.Stamp(entry.at),
                disabled = true
            }
        end
        show(id('history'), 'Personnel history', ('%d change(s)'):format(#(entries or {})), options)
    end)
end

return Personnel
