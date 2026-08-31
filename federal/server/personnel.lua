-- Hiring, promotion and dismissal.
--
-- This is the half of `roster.manage` that was missing: the editor changes
-- what a rank *is*, and this changes who *holds* one. Both are needed before
-- an agency can staff itself without an admin at a console.
--
-- Every change goes through Bridge.SetJob, which re-reads the job afterwards,
-- so a framework that cannot set jobs reports that plainly instead of leaving
-- a boss believing a promotion landed.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Util = Federal.Util
local Core = Federal.Core

local Personnel = {}
Federal.Personnel = Personnel

local log = DAG.Repository.Create('federal_personnel_log')
Personnel.log = log

local function fail(message)
    return nil, message
end

-- Hiring and firing are done face to face. Without this a boss could staff the
-- agency from across the map, and the person being hired would have no say in
-- being somewhere they can decline.
local function requireNearby(source, target)
    local boss, subject = Core.Coords(source), Core.Coords(target)
    if not boss or not subject then return false end

    local limit = tonumber((Config.Federal or {}).actionDistance) or 4.0
    local distance = Util.Distance(boss, subject)
    return distance ~= nil and distance <= limit + 2.0
end

Personnel.Nearby = requireNearby

function Personnel.Supported()
    return Bridge.Supports('setJob')
end

local function requireBoss(source)
    local membership = Core.Require(source, 'roster.manage')
    if not membership then return nil end

    if not Personnel.Supported() then
        Bridge.Notify(source,
            'This framework cannot change jobs. Extend the bridge adapter with setJob to enable hiring.', 'error')
        return nil
    end
    return membership
end

Personnel.RequireBoss = requireBoss

local function record(membership, action, target, detail)
    local entry = {
        id = ('%s-%d-%d'):format(membership.agency.id, os.time(), math.random(1000, 9999)),
        agency = membership.agency.id,
        action = action,
        by = membership.name,
        byIdentifier = membership.identifier,
        subject = Bridge.GetName(target),
        subjectIdentifier = Bridge.GetIdentifier(target),
        detail = detail,
        at = os.time()
    }
    log.save(entry.id, entry)
    return entry
end

-- A boss may never appoint at or above their own grade. Without this a
-- Supervisory Agent promotes themselves a peer who can then fire them.
local function highestAppointable(membership)
    if Core.IsAdmin(membership.source) then return 100 end
    return math.max(membership.grade - 1, 0)
end

Personnel.HighestAppointable = highestAppointable

function Personnel.Roster(source)
    local membership = Core.Membership(source)
    if not membership then return {} end

    local roster = {}
    for _, playerId in ipairs(GetPlayers()) do
        local playerSource = tonumber(playerId)
        if playerSource then
            local job = Bridge.GetJob(playerSource)
            if job and Util.Contains(membership.agency.jobs, job.name) then
                local rank = Core.Rank(membership.agency, job.grade)
                local identifier = Bridge.GetIdentifier(playerSource)
                local division = Core.DivisionOf(identifier, membership.agency)
                local divisionRank = division and Core.DivisionRankOf(identifier, division) or nil
                local memberMembership = Core.Membership(playerSource)
                roster[#roster + 1] = {
                    source = playerSource,
                    callsign = memberMembership and Core.CallsignFor(memberMembership) or nil,
                    callsignPrefix = memberMembership and Core.CallsignPrefix(memberMembership) or nil,
                    certs = Personnel.CertsFor(identifier),
                    name = Bridge.GetName(playerSource),
                    identifier = identifier,
                    grade = job.grade,
                    rank = rank and rank.label or 'Unranked',
                    division = division and division.label or nil,
                    divisionId = division and division.id or nil,
                    divisionRank = divisionRank and divisionRank.label or nil,
                    divisionRankGrade = divisionRank and divisionRank.grade or 0,
                    onDuty = Core.Unit(playerSource) ~= nil
                }
            end
        end
    end

    table.sort(roster, function(a, b)
        if a.grade == b.grade then return tostring(a.name) < tostring(b.name) end
        return a.grade > b.grade
    end)
    return roster
end

-- Players standing nearby who are not already in this agency: the pool a boss
-- can hire from.
function Personnel.Candidates(source)
    local membership = Core.Membership(source)
    if not membership then return {} end

    local candidates = {}
    for _, playerId in ipairs(GetPlayers()) do
        local playerSource = tonumber(playerId)
        if playerSource and playerSource ~= source and requireNearby(source, playerSource) then
            local job = Bridge.GetJob(playerSource)
            if not job or not Util.Contains(membership.agency.jobs, job.name) then
                candidates[#candidates + 1] = {
                    source = playerSource,
                    name = Bridge.GetName(playerSource),
                    job = job and job.label or 'Unknown'
                }
            end
        end
    end
    return candidates
end

function Personnel.Hire(source, target)
    local membership = requireBoss(source)
    if not membership then return fail('not authorized') end

    target = tonumber(target)
    if not target or target == source then return fail('no valid candidate selected') end
    if not requireNearby(source, target) then return fail('they need to be standing with you') end

    local existing = Bridge.GetJob(target)
    if existing and Util.Contains(membership.agency.jobs, existing.name) then
        return fail('they already work here')
    end

    local entryGrade = membership.agency.ranks[1] and membership.agency.ranks[1].grade or 0
    if not Bridge.SetJob(target, membership.agency.jobs[1], entryGrade) then
        return fail('the framework refused the job change')
    end

    local rank = Core.Rank(membership.agency, entryGrade)
    record(membership, 'hired', target, rank and rank.label or nil)

    Bridge.Notify(target, ('You have been hired by the %s.'):format(membership.agency.label), 'success')
    return { target = target, name = Bridge.GetName(target), grade = entryGrade }
end

-- One call for promotion and demotion: the direction is whichever way the
-- requested grade sits from where they are.
function Personnel.SetGrade(source, target, grade)
    local membership = requireBoss(source)
    if not membership then return fail('not authorized') end

    target = tonumber(target)
    grade = tonumber(grade)
    if not target or not grade then return fail('no valid subject or grade') end
    if target == source and not Core.IsAdmin(source) then return fail('you cannot change your own rank') end

    local job = Bridge.GetJob(target)
    if not job or not Util.Contains(membership.agency.jobs, job.name) then
        return fail('they do not work here')
    end

    local rank = Core.Rank(membership.agency, grade)
    if not rank or rank.grade ~= math.floor(grade) then return fail('that is not a rank in this agency') end

    local ceiling = highestAppointable(membership)
    if grade > ceiling then
        return fail(('you may only appoint up to grade %d'):format(ceiling))
    end
    -- Outranking somebody is what lets you change their rank at all.
    if job.grade >= membership.grade and not Core.IsAdmin(source) then
        return fail('they outrank you')
    end

    if not Bridge.SetJob(target, job.name, math.floor(grade)) then
        return fail('the framework refused the job change')
    end

    local action = grade > job.grade and 'promoted' or 'demoted'
    record(membership, action, target, rank.label)

    Bridge.Notify(target, ('You have been %s to %s.'):format(action, rank.label),
        action == 'promoted' and 'success' or 'inform')

    -- A demotion can drop them below the grade a zone or uniform needed, so
    -- the client is resynced rather than left showing options it no longer has.
    Core.Sync(target)
    return { target = target, grade = math.floor(grade), rank = rank.label, action = action }
end

function Personnel.Fire(source, target)
    local membership = requireBoss(source)
    if not membership then return fail('not authorized') end

    target = tonumber(target)
    if not target then return fail('no valid subject') end
    if target == source then return fail('you cannot dismiss yourself') end

    local job = Bridge.GetJob(target)
    if not job or not Util.Contains(membership.agency.jobs, job.name) then
        return fail('they do not work here')
    end
    if job.grade >= membership.grade and not Core.IsAdmin(source) then
        return fail('they outrank you')
    end

    local fallback = (Config.Federal or {}).unemployedJob or 'unemployed'
    if not Bridge.SetJob(target, fallback, 0) then
        return fail('the framework refused the job change')
    end

    record(membership, 'dismissed', target, nil)

    -- Off the roster immediately: a dismissed officer keeping their duty
    -- status would keep receiving callouts for an agency they left.
    Core.SetDuty(target, false)
    Bridge.Notify(target, ('You have been dismissed from the %s.'):format(membership.agency.label), 'error')
    Core.Sync(target)
    return { target = target, name = Bridge.GetName(target) }
end

-- Assigns a member to one of the agency's divisions (sub-departments), or
-- clears the assignment when divisionId is nil/''. The division must exist in
-- the agency catalog, and the member must not outrank the boss doing it.
function Personnel.SetDivision(source, target, divisionId, rankGrade)
    local membership = requireBoss(source)
    if not membership then return fail('not authorized') end

    target = tonumber(target)
    if not target then return fail('no valid subject') end

    local job = Bridge.GetJob(target)
    if not job or not Util.Contains(membership.agency.jobs, job.name) then
        return fail('they do not work here')
    end
    if target ~= source and job.grade >= membership.grade and not Core.IsAdmin(source) then
        return fail('they outrank you')
    end

    local identifier = Bridge.GetIdentifier(target)
    if not identifier then return fail('their identifier could not be read') end

    if divisionId == nil or divisionId == '' then
        Core.AssignDivision(identifier, membership.agency.id, nil)
        record(membership, 'division-cleared', target, nil)
        Core.Sync(target)
        return { target = target, name = Bridge.GetName(target), division = 'no division' }
    end

    local division = Federal.Schema.FindById(membership.agency.divisions or {}, divisionId)
    if not division then return fail('that division does not exist - create it first') end
    if job.grade < (division.minGrade or 0) then
        return fail(('%s requires grade %d+'):format(division.label, division.minGrade))
    end

    -- Keep the division rank when only re-assigning; a given rankGrade sets
    -- their place on the division's own ladder (promotion/demotion).
    local grade = tonumber(rankGrade)
    if grade == nil then
        local currentDivision, currentGrade = Core.DivisionAssignment(identifier)
        grade = currentDivision == division.id and currentGrade or 0
    end

    local ok, message = Core.AssignDivision(identifier, membership.agency.id, division.id, grade)
    if not ok then return fail(message) end

    local divisionRank = Core.DivisionRankOf(identifier, division)
    local title = divisionRank and ('%s (%s)'):format(division.label, divisionRank.label) or division.label

    record(membership, 'division', target, title)
    Bridge.Notify(target, ('You have been assigned to %s.'):format(title), 'inform')
    Core.Sync(target)
    return { target = target, name = Bridge.GetName(target), division = title }
end

function Personnel.History(source, limit)
    local membership = Core.Membership(source)
    if not membership or not Core.Can(source, 'roster.manage') then return {} end

    local entries = {}
    for _, entry in pairs(log.all()) do
        if entry.agency == membership.agency.id then entries[#entries + 1] = entry end
    end
    table.sort(entries, function(a, b) return (a.at or 0) > (b.at or 0) end)

    local capped = {}
    for index = 1, math.min(#entries, tonumber(limit) or 25) do capped[index] = entries[index] end
    return capped
end

-- Certifications ---------------------------------------------------------------
--
-- Awards from the agency's own catalog (defined in /fedconfig): Field
-- Training, SWAT, Firearms... Toggled per member by roster managers; each
-- award remembers who signed it and when. Personnel files read this.

local memberCerts = DAG.Repository.Create('federal_member_certs')

function Personnel.CertsFor(identifier)
    if type(identifier) ~= 'string' then return {} end
    local entry = memberCerts.get(identifier)
    return entry and Util.Copy(entry.list or {}) or {}
end

RegisterNetEvent(Federal.Net('personnel:certToggle'), function(targetSource, certId)
    local playerSource = source
    local membership = Core.Require(playerSource, 'roster.manage')
    if not membership then return end

    local targetId = Bridge.GetIdentifier(tonumber(targetSource) or 0)
    if not targetId then return Bridge.Notify(playerSource, 'They are not online.', 'error') end

    local cert = Federal.Schema.FindById(membership.agency.certifications or {}, tostring(certId))
    if not cert then return Bridge.Notify(playerSource, 'No such certification.', 'error') end

    local entry = memberCerts.get(targetId) or { id = targetId, list = {} }
    for index, held in ipairs(entry.list) do
        if held.id == cert.id then
            table.remove(entry.list, index)
            memberCerts.save(targetId, entry)
            return Bridge.Notify(playerSource, ('Revoked %s.'):format(cert.label), 'success')
        end
    end

    if #entry.list >= 24 then return Bridge.Notify(playerSource, 'Their file already carries the maximum awards.', 'error') end

    -- Prerequisites: every framework licence the certification demands must
    -- already be on the member before anyone may sign the award.
    if #(cert.licences or {}) > 0 and Bridge.PlayerLicences then
        local held = Bridge.PlayerLicences(tonumber(targetSource)) or {}
        for _, licence in ipairs(cert.licences) do
            if held[licence] ~= true then
                return Bridge.Notify(playerSource,
                    ('%s requires the %s licence, which they do not hold.'):format(cert.label, licence), 'error')
            end
        end
    end

    entry.list[#entry.list + 1] = { id = cert.id, label = cert.label, by = membership.name, at = os.time() }
    memberCerts.save(targetId, entry)
    Bridge.Notify(playerSource, ('Awarded %s.'):format(cert.label), 'success')
end)

-- Chain of command -------------------------------------------------------------
--
-- Who reports to whom, and who partners with whom. Stored by identifier so
-- it follows the character; the personnel menu writes it, the CAD's
-- personnel files read it.

local orgchart = DAG.Repository.Create('federal_orgchart')

local function orgEntry(identifier, name)
    local entry = orgchart.get(identifier) or { id = identifier }
    if name then entry.name = name end
    return entry
end

function Personnel.OrgFor(identifier)
    if type(identifier) ~= 'string' then return nil end
    local entry = orgchart.get(identifier) or {}

    local reports = {}
    for _, other in pairs(orgchart.all()) do
        if other.supervisorId == identifier and #reports < 10 then
            reports[#reports + 1] = other.name or other.id
        end
    end

    if not entry.supervisorName and not entry.partnerName and #reports == 0 then return nil end
    return {
        supervisor = entry.supervisorName,
        partner = entry.partnerName,
        reports = reports
    }
end

RegisterNetEvent(Federal.Net('personnel:supervisor'), function(targetSource, supervisorSource)
    local playerSource = source
    if not Core.Require(playerSource, 'roster.manage') then return end

    local targetId = Bridge.GetIdentifier(tonumber(targetSource) or 0)
    if not targetId then return Bridge.Notify(playerSource, 'They are not online.', 'error') end

    local entry = orgEntry(targetId, Bridge.GetName(tonumber(targetSource)))
    supervisorSource = tonumber(supervisorSource)
    if supervisorSource and supervisorSource > 0 then
        local supervisorId = Bridge.GetIdentifier(supervisorSource)
        if not supervisorId then return Bridge.Notify(playerSource, 'That supervisor is not online.', 'error') end
        if supervisorId == targetId then return Bridge.Notify(playerSource, 'Nobody reports to themselves.', 'error') end
        entry.supervisorId = supervisorId
        entry.supervisorName = Bridge.GetName(supervisorSource)
    else
        entry.supervisorId = nil
        entry.supervisorName = nil
    end

    orgchart.save(targetId, entry)
    Bridge.Notify(playerSource, 'Chain of command updated.', 'success')
end)

-- Partnering is mutual: setting it writes both files, clearing it clears both.
RegisterNetEvent(Federal.Net('personnel:partner'), function(targetSource, partnerSource)
    local playerSource = source
    if not Core.Require(playerSource, 'roster.manage') then return end

    local targetId = Bridge.GetIdentifier(tonumber(targetSource) or 0)
    if not targetId then return Bridge.Notify(playerSource, 'They are not online.', 'error') end

    local entry = orgEntry(targetId, Bridge.GetName(tonumber(targetSource)))

    -- Untie the existing partnership first, whichever way it points.
    if entry.partnerId then
        local previous = orgchart.get(entry.partnerId)
        if previous then
            previous.partnerId = nil
            previous.partnerName = nil
            orgchart.save(previous.id, previous)
        end
    end

    partnerSource = tonumber(partnerSource)
    if partnerSource and partnerSource > 0 then
        local partnerId = Bridge.GetIdentifier(partnerSource)
        if not partnerId then return Bridge.Notify(playerSource, 'That partner is not online.', 'error') end
        if partnerId == targetId then return Bridge.Notify(playerSource, 'Nobody partners with themselves.', 'error') end

        entry.partnerId = partnerId
        entry.partnerName = Bridge.GetName(partnerSource)
        local other = orgEntry(partnerId, Bridge.GetName(partnerSource))
        other.partnerId = targetId
        other.partnerName = entry.name
        orgchart.save(partnerId, other)
    else
        entry.partnerId = nil
        entry.partnerName = nil
    end

    orgchart.save(targetId, entry)
    Bridge.Notify(playerSource, 'Partnership updated.', 'success')
end)

-- Net wiring ------------------------------------------------------------------

Bridge.RegisterCallback(Federal.Net('personnel:roster'), function(source, reply)
    reply({
        supported = Personnel.Supported(),
        roster = Personnel.Roster(source),
        candidates = Personnel.Candidates(source),
        ceiling = (function()
            local membership = Core.Membership(source)
            return membership and highestAppointable(membership) or 0
        end)()
    })
end)

Bridge.RegisterCallback(Federal.Net('personnel:history'), function(source, reply)
    reply(Personnel.History(source))
end)

local function personnelEvent(name, handler, describe)
    RegisterNetEvent(Federal.Net('personnel:' .. name), function(...)
        local playerSource = source
        local result, message = handler(playerSource, ...)
        if not result then
            return Bridge.Notify(playerSource, message or 'that change was refused', 'error')
        end
        Bridge.Notify(playerSource, describe(result), 'success')
    end)
end

personnelEvent('hire', Personnel.Hire, function(result) return ('Hired %s.'):format(result.name) end)
personnelEvent('grade', Personnel.SetGrade, function(result) return ('Set rank to %s.'):format(result.rank) end)
personnelEvent('fire', Personnel.Fire, function(result) return ('Dismissed %s.'):format(result.name) end)
personnelEvent('division', Personnel.SetDivision, function(result) return ('%s assigned to %s.'):format(result.name, result.division) end)

return Personnel
