-- The court process.
--
-- A case runs filed -> arraignment -> trial -> deliberation -> verdict ->
-- closed. Every role can be filled by a real player, and any role that nobody
-- takes is filled by an NPC so a case is never blocked waiting for someone to
-- log in: no judge online means an NPC judge presides, and a short jury is
-- topped up with NPC jurors who vote on the strength of the case.
--
-- Who may file is a config list of job names, not an agency permission, which
-- is what lets the same court serve the federal agencies and any other job the
-- server wants to give it (police, sheriff, a district attorney).
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Util = Federal.Util
local Const = Federal.Constants
local Schema = Federal.Schema
local Core = Federal.Core
local CAD = Federal.CAD

local Court = {}
Federal.Court = Court

local cases = DAG.Repository.Create('federal_court_cases')
local courthouses = DAG.Repository.Create('federal_courthouses')
Court.cases, Court.courthouses = cases, courthouses

local function fail(message)
    return nil, message
end

local function settings()
    return (Config.Federal or {}).court or {}
end

local function now()
    return os.time()
end

function Court.Enabled()
    return Core.Enabled() and settings().enabled ~= false
end

-- Courthouses -----------------------------------------------------------------

local houseCache

function Court.Invalidate()
    houseCache = nil
end

-- Same two-layer merge as the agency registry: the catalog seeds it, and an
-- edited courthouse replaces the seeded one wholesale.
local function buildHouses()
    local merged, order = {}, {}

    for _, raw in ipairs((Config.Federal or {}).Courthouses or {}) do
        local house, message = Schema.Courthouse(raw)
        if house then
            if not merged[house.id] then order[#order + 1] = house.id end
            merged[house.id] = house
        else
            Bridge.Print('ignoring configured courthouse %s: %s', tostring(raw and raw.id), tostring(message))
        end
    end

    for id, stored in pairs(courthouses.all()) do
        if stored.deleted == true then
            merged[id] = nil
        else
            local house, message = Schema.Courthouse(stored)
            if house then
                if not merged[house.id] then order[#order + 1] = house.id end
                merged[house.id] = house
            else
                Bridge.Print('ignoring stored courthouse %s: %s', tostring(id), tostring(message))
            end
        end
    end

    local list = {}
    for _, id in ipairs(order) do
        if merged[id] then list[#list + 1] = merged[id] end
    end
    return { map = merged, list = list }
end

local function houses()
    if not houseCache then houseCache = buildHouses() end
    return houseCache
end

function Court.Courthouses()
    return Util.Copy(houses().list)
end

function Court.Courthouse(id)
    local house = houses().map[id]
    return house and Util.Copy(house) or nil
end

local function persistHouse(house)
    local normalized, message = Schema.Courthouse(house)
    if not normalized then return fail(message) end

    local saved, saveMessage = courthouses.save(normalized.id, normalized)
    if not saved then return fail(saveMessage or 'the courthouse could not be saved') end

    Court.Invalidate()
    Core.Sync()
    return normalized
end

function Court.SaveCourthouse(source, payload)
    if not Core.IsAdmin(source) then return fail('editing a courthouse is an admin action') end
    payload = type(payload) == 'table' and payload or {}

    local coords = Federal.Editor and Federal.Editor.Placement(source, payload) or Util.ToCoords(payload.coords)
    if not coords then return fail('no position for that courthouse') end

    local existing = payload.id and Court.Courthouse(payload.id) or nil
    return persistHouse({
        id = payload.id,
        label = payload.label or (existing and existing.label),
        coords = coords,
        blip = payload.blip or (existing and existing.blip),
        seats = existing and existing.seats or {}
    })
end

function Court.DeleteCourthouse(source, id)
    if not Core.IsAdmin(source) then return fail('editing a courthouse is an admin action') end

    local house = Court.Courthouse(id)
    if not house then return fail('no such courthouse') end

    courthouses.save(id, { deleted = true })
    Court.Invalidate()
    Core.Sync()
    return house
end

function Court.SaveSeat(source, courthouseId, payload)
    if not Core.IsAdmin(source) then return fail('editing a courthouse is an admin action') end
    payload = type(payload) == 'table' and payload or {}

    local house = Court.Courthouse(courthouseId)
    if not house then return fail('no such courthouse') end
    if not Const.SeatRoles[payload.role] then return fail('unknown seat role') end

    local coords, heading = Federal.Editor.Placement(source, payload)
    if not coords then return fail('no position for that seat') end

    local seat, message = Schema.Seat({
        id = payload.id,
        role = payload.role,
        label = payload.label,
        coords = coords,
        heading = heading
    })
    if not seat then return fail(message) end

    local _, index = Schema.FindById(house.seats, seat.id)
    if index then house.seats[index] = seat else house.seats[#house.seats + 1] = seat end

    local saved, saveMessage = persistHouse(house)
    if not saved then return fail(saveMessage) end
    return seat
end

function Court.DeleteSeat(source, courthouseId, seatId)
    if not Core.IsAdmin(source) then return fail('editing a courthouse is an admin action') end

    local house = Court.Courthouse(courthouseId)
    if not house then return fail('no such courthouse') end

    local seat, index = Schema.FindById(house.seats, seatId)
    if not index then return fail('no such seat') end

    table.remove(house.seats, index)
    local saved, saveMessage = persistHouse(house)
    if not saved then return fail(saveMessage) end
    return seat
end

-- Eligibility -------------------------------------------------------------------

local function jobName(source)
    local job = Bridge.GetJob(source)
    return job and job.name or nil
end

Court.JobName = jobName

function Court.CanFile(source)
    if Core.IsAdmin(source) then return true end
    local name = jobName(source)
    return name ~= nil and Util.Contains(settings().filingJobs or {}, name)
end

-- Which roles a given player is allowed to take. The defendant is never
-- eligible for anything else in their own case, and the officers of the
-- agency that filed are kept off the jury whatever the config says.
function Court.RoleEligible(source, role, case)
    local name = jobName(source)
    local identifier = Bridge.GetIdentifier(source)

    if case and case.defendant and case.defendant.identifier == identifier then return false end

    if role == 'judge' then
        return Core.IsAdmin(source) or (name ~= nil and Util.Contains(settings().judgeJobs or {}, name))
    end
    if role == 'prosecutor' then
        return name ~= nil and Util.Contains(settings().prosecutorJobs or {}, name)
    end
    if role == 'defense' then
        return name ~= nil and Util.Contains(settings().defenseJobs or {}, name)
    end
    if role == 'bailiff' then
        return Court.CanFile(source)
    end
    if role == 'juror' then
        local jury = settings().jury or {}
        if name and Util.Contains(jury.excludeJobs or {}, name) then return false end
        -- The people who built the case do not sit on the jury that hears it.
        if case and case.filedBy and name and Util.Contains(settings().filingJobs or {}, name) then
            if case.filedBy.job == name then return false end
        end
        return true
    end
    if role == 'witness' then return true end
    return false
end

local function eligibleJudgeOnline()
    for _, playerId in ipairs(GetPlayers()) do
        local playerSource = tonumber(playerId)
        if playerSource and Court.RoleEligible(playerSource, 'judge') then return playerSource end
    end
    return nil
end

Court.EligibleJudgeOnline = eligibleJudgeOnline

-- Case numbering -------------------------------------------------------------------

local function nextNumber(scope, prefix)
    local key = ('court:%s'):format(scope)
    local counter = DAG.Storage.Get('federal_counters', key) or { value = 0 }
    local value = (tonumber(counter.value) or 0) + 1
    DAG.Storage.Set('federal_counters', key, { value = value })
    return ('%s-%s-%04d'):format(prefix, Const.Series.court, value), value
end

-- Cases ----------------------------------------------------------------------------

local function charges(input)
    local list = {}
    if type(input) ~= 'table' then return list end
    for _, charge in ipairs(input) do
        local text = Util.Text(charge, 80)
        if text and #list < 20 then list[#list + 1] = text end
    end
    return list
end

function Court.ChargeDetail(charge)
    local catalog = (Config.Federal or {}).Charges or {}
    return catalog[charge] or settings().defaultCharge or { months = 12, fine = 5000, severity = 1 }
end

-- The recommendation a judge starts from, and the ceiling an NPC judge uses.
function Court.Recommendation(case)
    local bounds = settings().sentencing or {}
    local months, fine, severity = 0, 0, 0

    for _, charge in ipairs(case.charges or {}) do
        local detail = Court.ChargeDetail(charge)
        months = months + (tonumber(detail.months) or 0)
        fine = fine + (tonumber(detail.fine) or 0)
        severity = severity + (tonumber(detail.severity) or 1)
    end

    return {
        months = math.floor(Util.Clamp(months, 0, tonumber(bounds.maxMonths) or 240)),
        fine = math.floor(Util.Clamp(fine, 0, tonumber(bounds.maxFine) or 250000)),
        severity = severity
    }
end

function Court.File(source, payload)
    if not Court.Enabled() then return fail('the court process is disabled') end
    payload = type(payload) == 'table' and payload or {}
    if not Court.CanFile(source) then return fail('your job cannot file a case') end

    local identifier = Util.Text(payload.identifier, 80)
    if not identifier then return fail('a case requires a defendant identifier') end

    local list = charges(payload.charges)
    if #list == 0 then return fail('a case requires at least one charge') end

    local house = Court.Courthouse(payload.courthouse) or Court.Courthouses()[1]
    if not house then return fail('no courthouse is configured') end

    local membership = Core.Membership(source)
    -- Counters are scoped by PREFIX, not by job: police and sheriff both fall
    -- back to CRT, and scoping by job would issue CRT-CR-0001 twice.
    local prefix = membership and membership.agency.short or 'CRT'
    local number = nextNumber(prefix, prefix)

    local case = {
        id = Util.Slug(number),
        number = number,
        courthouse = house.id,
        stage = 'filed',
        stageAt = now(),
        agency = membership and membership.agency.id or nil,
        filedBy = {
            identifier = Bridge.GetIdentifier(source),
            name = Bridge.GetName(source),
            job = jobName(source)
        },
        defendant = {
            identifier = identifier,
            name = Util.Text(payload.name, 60, 'Unknown defendant')
        },
        charges = list,
        incidentId = Util.Text(payload.incidentId, 40),
        plea = nil,
        roles = { jurors = {} },
        evidence = {},
        transcript = {},
        votes = {},
        verdict = nil,
        sentence = nil,
        createdAt = now(),
        updatedAt = now()
    }

    cases.save(case.id, case)
    Court.EnsureJudge(case.id)
    return cases.get(case.id)
end

-- Called by the actions module when an arrest is booked.
function Court.OnArrest(source, booking)
    if not Court.Enabled() or settings().autoFileOnArrest == false then return nil end
    if type(booking) ~= 'table' or not booking.identifier then return nil end
    if type(booking.charges) ~= 'table' or #booking.charges == 0 then return nil end

    local case = Court.File(source, {
        identifier = booking.identifier,
        name = booking.name,
        charges = booking.charges,
        incidentId = booking.incidentId
    })
    return case
end

function Court.Get(id)
    return cases.get(id)
end

-- Transcript and juror votes are only visible to the people in the room.
local function redact(case, participant)
    if participant then return case end
    local copy = Util.Copy(case)
    copy.transcript = nil
    copy.votes = nil
    return copy
end

function Court.IsParticipant(source, case)
    if Core.IsAdmin(source) then return true end
    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return false end
    if case.defendant and case.defendant.identifier == identifier then return true end

    for role, holder in pairs(case.roles or {}) do
        if role == 'jurors' then
            for _, juror in ipairs(holder) do
                if juror.identifier == identifier then return true end
            end
        elseif type(holder) == 'table' and holder.identifier == identifier then
            return true
        end
    end
    return Court.CanFile(source)
end

function Court.Case(source, id)
    local case = cases.get(id)
    if not case then return nil end
    return redact(case, Court.IsParticipant(source, case))
end

function Court.Docket(source, filter)
    filter = filter or {}
    local list = {}
    for _, case in pairs(cases.all()) do
        local include = true
        if filter.open and case.stage == 'closed' then include = false end
        if filter.courthouse and case.courthouse ~= filter.courthouse then include = false end
        if include then list[#list + 1] = redact(case, Court.IsParticipant(source, case)) end
    end
    table.sort(list, function(a, b) return (a.createdAt or 0) > (b.createdAt or 0) end)
    return list
end

-- Roles ------------------------------------------------------------------------------

local function npcHolder(role)
    local models = (settings().npcModels or {})[role]
    local model = models
    if type(models) == 'table' then model = models[math.random(#models)] end
    return {
        npc = true,
        name = ('Court-appointed %s'):format(Const.CourtRoles[role] and Const.CourtRoles[role].label:lower() or role),
        model = model
    }
end

Court.NpcHolder = npcHolder

-- Assigns an NPC judge when no eligible judge is online. A case that cannot
-- start because nobody logged in is the failure this exists to prevent.
function Court.EnsureJudge(caseId)
    local case = cases.get(caseId)
    if not case or case.stage == 'closed' then return nil end
    if case.roles.judge then return case.roles.judge end

    if eligibleJudgeOnline() then return nil end

    case.roles.judge = npcHolder('judge')
    case.updatedAt = now()
    cases.save(case.id, case)
    return case.roles.judge
end

function Court.TakeRole(source, caseId, role)
    if not Const.CourtRoles[role] or role == 'defendant' then return fail('that role cannot be taken') end

    local case = cases.get(caseId)
    if not case then return fail('no such case') end
    if case.stage == 'closed' then return fail('that case is closed') end
    if not Court.RoleEligible(source, role, case) then return fail('you are not eligible for that role') end

    local identifier = Bridge.GetIdentifier(source)
    local holder = { identifier = identifier, name = Bridge.GetName(source), source = source, npc = false }

    if role == 'juror' then
        local jury = settings().jury or {}
        case.roles.jurors = case.roles.jurors or {}
        for _, juror in ipairs(case.roles.jurors) do
            if juror.identifier == identifier then return fail('you are already on this jury') end
        end
        if #case.roles.jurors >= (tonumber(jury.size) or 6) then return fail('the jury box is full') end
        case.roles.jurors[#case.roles.jurors + 1] = holder
    else
        -- A real player always displaces an NPC stand-in for a unique role.
        local existing = case.roles[role]
        if existing and existing.npc ~= true then return fail('that role is already taken') end
        case.roles[role] = holder
    end

    case.updatedAt = now()
    cases.save(case.id, case)
    return case.roles[role] or holder
end

function Court.LeaveRole(source, caseId, role)
    local case = cases.get(caseId)
    if not case then return fail('no such case') end

    local identifier = Bridge.GetIdentifier(source)
    if role == 'juror' then
        for index, juror in ipairs(case.roles.jurors or {}) do
            if juror.identifier == identifier then
                table.remove(case.roles.jurors, index)
                cases.save(case.id, case)
                return { role = role }
            end
        end
        return fail('you are not on that jury')
    end

    local holder = case.roles[role]
    if not holder or holder.identifier ~= identifier then return fail('you do not hold that role') end
    case.roles[role] = nil
    cases.save(case.id, case)
    return { role = role }
end

-- Presiding: the judge, or an admin standing in for one.
local function presiding(source, case)
    if Core.IsAdmin(source) then return true end
    local judge = case.roles and case.roles.judge
    return judge ~= nil and judge.npc ~= true and judge.identifier == Bridge.GetIdentifier(source)
end

Court.Presiding = presiding

-- Proceedings ---------------------------------------------------------------------------

function Court.Plea(source, caseId, plea)
    local case = cases.get(caseId)
    if not case then return fail('no such case') end
    if case.stage ~= 'arraignment' then return fail('a plea is entered at arraignment') end
    if not Util.Contains(Const.Pleas, plea) then return fail('unknown plea') end

    local identifier = Bridge.GetIdentifier(source)
    local isDefendant = case.defendant and case.defendant.identifier == identifier
    local isDefense = case.roles.defense and case.roles.defense.identifier == identifier
    if not isDefendant and not isDefense and not Core.IsAdmin(source) then
        return fail('only the defendant or their counsel may enter a plea')
    end

    case.plea = plea
    case.transcript[#case.transcript + 1] = {
        role = isDefense and 'defense' or 'defendant',
        actor = Bridge.GetName(source),
        text = ('Plea entered: %s'):format(plea:gsub('_', ' ')),
        at = now()
    }
    case.updatedAt = now()
    cases.save(case.id, case)
    return case
end

function Court.AdmitEvidence(source, caseId, evidenceId)
    local case = cases.get(caseId)
    if not case then return fail('no such case') end
    -- Evidence can be added from the moment the case is filed: an officer
    -- builds the case file before anyone is arraigned. It closes once the jury
    -- retires, because evidence the jury never saw cannot bear on the verdict.
    if case.stage == 'deliberation' or case.stage == 'verdict' or case.stage == 'closed' then
        return fail('evidence is admitted before deliberation')
    end

    local isProsecution = case.roles.prosecutor and case.roles.prosecutor.identifier == Bridge.GetIdentifier(source)
    if not isProsecution and not presiding(source, case) and not Court.CanFile(source) then
        return fail('you may not admit evidence in this case')
    end

    local item = CAD.evidence.get(evidenceId)
    if not item then return fail('no such evidence item') end
    if Util.Contains(case.evidence, evidenceId) then return fail('that item is already admitted') end

    case.evidence[#case.evidence + 1] = evidenceId
    case.transcript[#case.transcript + 1] = {
        role = 'prosecutor',
        actor = Bridge.GetName(source),
        text = ('Admitted %s (%s)'):format(item.number, item.label),
        at = now()
    }
    case.updatedAt = now()
    cases.save(case.id, case)
    return case
end

function Court.Testify(source, caseId, text, role)
    local case = cases.get(caseId)
    if not case then return fail('no such case') end
    if case.stage ~= 'trial' then return fail('testimony is heard at trial') end

    local entry = Util.Text(text, 400)
    if not entry then return fail('the statement is empty') end
    if #case.transcript >= 60 then return fail('the transcript is full') end

    local identifier = Bridge.GetIdentifier(source)
    local speaking = role
    if not speaking then
        for name, holder in pairs(case.roles) do
            if name ~= 'jurors' and type(holder) == 'table' and holder.identifier == identifier then speaking = name end
        end
        if case.defendant and case.defendant.identifier == identifier then speaking = 'defendant' end
    end

    case.transcript[#case.transcript + 1] = {
        role = speaking or 'witness',
        actor = Bridge.GetName(source),
        text = entry,
        at = now()
    }
    case.updatedAt = now()
    cases.save(case.id, case)
    return case
end

-- Case strength -----------------------------------------------------------------------------

-- How likely an NPC juror is to convict, in 0..1. Admitted evidence is the
-- dominant term and analysed evidence counts for more, so the investigation
-- work an officer actually did is what carries a conviction rather than the
-- number of charges typed onto the file.
function Court.Strength(case)
    local strength = 0.30

    for _, evidenceId in ipairs(case.evidence or {}) do
        local item = CAD.evidence.get(evidenceId)
        if item then
            strength = strength + (item.analysed and 0.18 or 0.10)
            if item.match and case.defendant and item.match == case.defendant.identifier then
                strength = strength + 0.10
            end
        end
    end

    local recommendation = Court.Recommendation(case)
    strength = strength + math.min(recommendation.severity * 0.02, 0.10)

    local record = CAD.records.get(case.defendant and case.defendant.identifier)
    if record and #(record.arrests or {}) > 1 then strength = strength + 0.08 end

    -- Counsel and testimony pull against each other.
    if case.roles.defense and case.roles.defense.npc ~= true then strength = strength - 0.12 end
    if case.roles.prosecutor and case.roles.prosecutor.npc ~= true then strength = strength + 0.08 end

    for _, entry in ipairs(case.transcript or {}) do
        if entry.role == 'defense' or entry.role == 'defendant' then strength = strength - 0.04 end
        if entry.role == 'prosecutor' or entry.role == 'witness' then strength = strength + 0.03 end
    end

    return Util.Clamp(strength, 0.05, 0.95)
end

-- Bail ---------------------------------------------------------------------------------------

local function bailSettings()
    return settings().bail or {}
end

-- What it costs this defendant to walk until trial, or nil when the charges
-- are not bailable.
function Court.BailAmount(case)
    local bail = bailSettings()
    if bail.enabled == false then return nil end

    for _, charge in ipairs(case.charges or {}) do
        if Util.Contains(bail.denyFor or {}, charge) then return nil, charge end
    end

    local recommendation = Court.Recommendation(case)
    local amount = math.floor(recommendation.fine * (tonumber(bail.multiplier) or 0.35))
    return math.floor(Util.Clamp(amount, tonumber(bail.minimum) or 500, tonumber(bail.maximum) or 100000))
end

function Court.SetBail(source, caseId, amount)
    local case = cases.get(caseId)
    if not case then return fail('no such case') end
    if not presiding(source, case) then return fail('only the presiding judge may set bail') end
    if case.stage ~= 'arraignment' then return fail('bail is set at arraignment') end
    if case.bail and case.bail.status == 'posted' then return fail('bail has already been posted') end

    local recommended, blocked = Court.BailAmount(case)
    if not recommended then
        return fail(blocked and ('%s is not a bailable charge'):format(blocked) or 'bail is disabled')
    end

    local bail = bailSettings()
    local value = math.floor(Util.Clamp(tonumber(amount) or recommended,
        tonumber(bail.minimum) or 500, tonumber(bail.maximum) or 100000))

    case.bail = { amount = value, status = 'set', setBy = Bridge.GetName(source), at = now() }
    case.transcript[#case.transcript + 1] = {
        role = 'judge',
        actor = Bridge.GetName(source),
        text = ('Bail set at $%d.'):format(value),
        at = now()
    }
    cases.save(case.id, case)
    return case
end

function Court.PostBail(source, caseId)
    local case = cases.get(caseId)
    if not case then return fail('no such case') end
    if not case.bail or case.bail.status ~= 'set' then return fail('no bail has been set') end

    local identifier = Bridge.GetIdentifier(source)
    if case.defendant.identifier ~= identifier and not Core.IsAdmin(source) then
        return fail('only the defendant may post their own bail')
    end

    local account = bailSettings().account or 'bank'
    if not Bridge.RemoveMoney(source, account, case.bail.amount, 'federal-bail') then
        return fail('you cannot afford that')
    end

    case.bail.status = 'posted'
    case.bail.postedAt = now()
    case.bail.appearBy = now() + (tonumber(bailSettings().appearBy) or 1800)
    cases.save(case.id, case)

    -- Out until the trial: a defendant on bail is released from custody.
    if Federal.Jail and Federal.Jail.Record(case.defendant.identifier) then
        Federal.Jail.Release(case.defendant.identifier, ('Released on bail for %s'):format(case.number))
    end

    Bridge.Notify(source, ('Bail posted. Appear for %s or it is forfeit.'):format(case.number), 'inform')
    return case
end

-- Bail is forfeit when the defendant never comes back, and a bench warrant
-- follows: skipping bail has to cost more than it saves.
function Court.ForfeitBail(caseId)
    local case = cases.get(caseId)
    if not case or not case.bail or case.bail.status ~= 'posted' then return nil end

    case.bail.status = 'forfeit'
    case.bail.forfeitAt = now()
    case.transcript[#case.transcript + 1] = {
        role = 'judge',
        actor = 'The court',
        text = 'The defendant failed to appear. Bail is forfeit.',
        at = now()
    }
    cases.save(case.id, case)

    if not CAD.ActiveWarrantFor(case.defendant.identifier) then
        local number, sequence = Core.NextNumber(case.agency or 'fib', 'warrant')
        CAD.warrants.save(Util.RecordId('wnt', sequence), {
            id = Util.RecordId('wnt', sequence),
            number = number,
            agency = case.agency or 'fib',
            target = { identifier = case.defendant.identifier, name = case.defendant.name },
            reason = ('Failure to appear on %s'):format(case.number),
            charges = { 'Failure to appear' },
            status = 'active',
            issuedBy = 'The court',
            createdAt = now()
        })
    end

    CAD.Note(case.defendant.identifier, case.defendant.name,
        ('Bail forfeit on %s; bench warrant issued'):format(case.number))
    return case
end

-- Plea bargaining -------------------------------------------------------------------------------

-- The prosecution offers a reduced sentence for a guilty plea. Bounded so a
-- bargain is a discount rather than an acquittal.
function Court.OfferPlea(source, caseId, factor)
    if (settings().plea or {}).enabled == false then return fail('plea bargaining is disabled') end

    local case = cases.get(caseId)
    if not case then return fail('no such case') end
    if case.stage ~= 'arraignment' and case.stage ~= 'trial' then
        return fail('an offer is made before the jury retires')
    end

    local identifier = Bridge.GetIdentifier(source)
    local prosecutor = case.roles.prosecutor
    local isProsecution = prosecutor and prosecutor.identifier == identifier
    if not isProsecution and not Court.CanFile(source) and not Core.IsAdmin(source) then
        return fail('only the prosecution may offer a deal')
    end

    local plea = settings().plea or {}
    local bounded = Util.Clamp(tonumber(factor) or 0.6,
        tonumber(plea.minimumFactor) or 0.4, tonumber(plea.maximumFactor) or 0.9)

    local recommendation = Court.Recommendation(case)
    case.offer = {
        factor = bounded,
        months = math.floor(recommendation.months * bounded),
        fine = math.floor(recommendation.fine * bounded),
        by = Bridge.GetName(source),
        at = now(),
        status = 'open'
    }
    case.transcript[#case.transcript + 1] = {
        role = 'prosecutor',
        actor = Bridge.GetName(source),
        text = ('Offer: plead guilty for %d months and $%d.'):format(case.offer.months, case.offer.fine),
        at = now()
    }

    cases.save(case.id, case)
    return case
end

-- Accepting is a conviction on the agreed terms: it skips the jury entirely,
-- which is the whole point of taking a deal.
function Court.AcceptPlea(source, caseId)
    local case = cases.get(caseId)
    if not case then return fail('no such case') end
    if not case.offer or case.offer.status ~= 'open' then return fail('there is no offer on the table') end

    local identifier = Bridge.GetIdentifier(source)
    local isDefendant = case.defendant.identifier == identifier
    local isDefense = case.roles.defense and case.roles.defense.identifier == identifier
    if not isDefendant and not isDefense and not Core.IsAdmin(source) then
        return fail('only the defendant or their counsel may accept')
    end

    case.offer.status = 'accepted'
    case.plea = 'guilty'
    case.verdict = 'guilty'
    case.stage = 'verdict'
    case.stageAt = now()
    case.transcript[#case.transcript + 1] = {
        role = isDefense and 'defense' or 'defendant',
        actor = Bridge.GetName(source),
        text = 'The offer is accepted.',
        at = now()
    }
    cases.save(case.id, case)

    -- Sentenced on the agreed terms rather than the recommendation, and the
    -- agreed terms are exempt from the judge's discretion band because they
    -- were bargained rather than imposed.
    return Court.ApplySentence(cases.get(case.id), case.offer.months, case.offer.fine, 'Plea agreement', true)
end

function Court.RejectPlea(source, caseId)
    local case = cases.get(caseId)
    if not case or not case.offer or case.offer.status ~= 'open' then return fail('there is no offer on the table') end

    local identifier = Bridge.GetIdentifier(source)
    local isDefendant = case.defendant.identifier == identifier
    local isDefense = case.roles.defense and case.roles.defense.identifier == identifier
    if not isDefendant and not isDefense and not Core.IsAdmin(source) then
        return fail('only the defendant or their counsel may reject')
    end

    case.offer.status = 'rejected'
    case.transcript[#case.transcript + 1] = {
        role = isDefense and 'defense' or 'defendant',
        actor = Bridge.GetName(source),
        text = 'The offer is rejected.',
        at = now()
    }
    cases.save(case.id, case)
    return case
end

-- Continuances -----------------------------------------------------------------------------------

-- Putting a case back because a party is missing. Limited, or a defendant with
-- a patient lawyer never stands trial.
function Court.Continue(source, caseId, reason)
    if (settings().continuance or {}).enabled == false then return fail('continuances are disabled') end

    local case = cases.get(caseId)
    if not case then return fail('no such case') end
    if not presiding(source, case) then return fail('only the presiding judge may grant a continuance') end
    if case.stage == 'closed' then return fail('that case is closed') end

    local limit = tonumber((settings().continuance or {}).limit) or 2
    local used = tonumber(case.continuances) or 0
    if used >= limit then return fail(('this case has already been put back %d times'):format(limit)) end

    case.continuances = used + 1
    case.stageAt = now()
    case.transcript[#case.transcript + 1] = {
        role = 'judge',
        actor = Bridge.GetName(source),
        text = ('Continued (%d of %d): %s'):format(case.continuances, limit,
            Util.Text(reason, 200, 'no reason given')),
        at = now()
    }
    cases.save(case.id, case)
    return case
end

-- Deliberation and verdict ------------------------------------------------------------------

function Court.Vote(source, caseId, guilty)
    local case = cases.get(caseId)
    if not case then return fail('no such case') end
    if case.stage ~= 'deliberation' then return fail('the jury is not deliberating') end
    if type(guilty) ~= 'boolean' then return fail('a vote is guilty or not guilty') end

    local identifier = Bridge.GetIdentifier(source)
    local onJury = false
    for _, juror in ipairs(case.roles.jurors or {}) do
        if juror.identifier == identifier then onJury = true end
    end
    if not onJury then return fail('you are not on this jury') end

    case.votes[identifier] = guilty
    case.updatedAt = now()
    cases.save(case.id, case)
    return case
end

-- Fills the jury box with NPC jurors and returns the tally. NPC jurors vote on
-- the strength of the case; real jurors who never voted are not voted for.
function Court.Tally(caseId)
    local case = cases.get(caseId)
    if not case then return nil end

    local jury = settings().jury or {}
    local size = tonumber(jury.size) or 6
    case.roles.jurors = case.roles.jurors or {}

    if jury.npcFill ~= false then
        while #case.roles.jurors < size do
            local juror = npcHolder('juror')
            juror.identifier = ('npc:juror:%d'):format(#case.roles.jurors + 1)
            juror.name = ('Juror %d'):format(#case.roles.jurors + 1)
            case.roles.jurors[#case.roles.jurors + 1] = juror
        end
    end

    local strength = Court.Strength(case)
    local guilty, total = 0, 0
    for _, juror in ipairs(case.roles.jurors) do
        local vote = case.votes[juror.identifier]
        if vote == nil and juror.npc == true then
            vote = math.random() <= strength
            case.votes[juror.identifier] = vote
        end
        if vote ~= nil then
            total = total + 1
            if vote then guilty = guilty + 1 end
        end
    end

    cases.save(case.id, case)
    return { guilty = guilty, total = total, strength = strength }
end

function Court.Verdict(caseId)
    local case = cases.get(caseId)
    if not case then return fail('no such case') end

    -- A guilty plea is a conviction; the jury is never troubled with it.
    if case.plea == 'guilty' then
        case.verdict = 'guilty'
    else
        local tally = Court.Tally(caseId)
        case = cases.get(caseId)
        if not tally or tally.total == 0 then return fail('no votes were cast') end

        local jury = settings().jury or {}
        if jury.unanimous == true then
            if tally.guilty == tally.total then
                case.verdict = 'guilty'
            elseif tally.guilty == 0 then
                case.verdict = 'not_guilty'
            else
                case.verdict = 'hung'
            end
        else
            case.verdict = (tally.guilty * 2 > tally.total) and 'guilty' or 'not_guilty'
        end
        case.tally = tally
    end

    case.stage = 'verdict'
    case.stageAt = now()
    case.updatedAt = now()
    cases.save(case.id, case)
    return case
end

-- Sentencing ------------------------------------------------------------------------------------

function Court.Sentence(source, caseId, months, fine)
    local case = cases.get(caseId)
    if not case then return fail('no such case') end
    if case.stage ~= 'verdict' then return fail('sentencing follows a verdict') end
    if not presiding(source, case) then return fail('only the presiding judge may pass sentence') end
    if case.verdict ~= 'guilty' then return fail('there is nothing to sentence') end

    return Court.ApplySentence(case, months, fine, Bridge.GetName(source))
end

-- Shared by the real judge and the NPC one, so both produce the same record.
function Court.ApplySentence(case, months, fine, byName, agreed)
    local bounds = settings().sentencing or {}
    local recommendation = Court.Recommendation(case)
    -- An agreed sentence is not subject to the discretion band: it was
    -- bargained rather than imposed, and clamping it would undo the bargain.
    local discretion = agreed and 1.0 or (tonumber(bounds.judgeDiscretion) or 0.5)

    -- A judge may depart from the recommendation, but only within the
    -- configured band: sentencing is discretionary, not arbitrary.
    local lowMonths = math.floor(recommendation.months * (1 - discretion))
    local highMonths = math.ceil(recommendation.months * (1 + discretion))
    local lowFine = math.floor(recommendation.fine * (1 - discretion))
    local highFine = math.ceil(recommendation.fine * (1 + discretion))

    local finalMonths = math.floor(Util.Clamp(tonumber(months) or recommendation.months, lowMonths, highMonths))
    local finalFine = math.floor(Util.Clamp(tonumber(fine) or recommendation.fine, lowFine, highFine))
    finalMonths = math.floor(Util.Clamp(finalMonths, 0, tonumber(bounds.maxMonths) or 240))
    finalFine = math.floor(Util.Clamp(finalFine, 0, tonumber(bounds.maxFine) or 250000))

    case.sentence = {
        months = finalMonths,
        fine = finalFine,
        by = byName or 'the court',
        recommendation = recommendation,
        at = now()
    }
    case.stage = 'closed'
    case.stageAt = now()
    case.closedAt = now()
    cases.save(case.id, case)

    Court.Close(case, ('Convicted: %d months, $%d'):format(finalMonths, finalFine))
    return cases.get(case.id)
end

-- Closes the case out: notes it on the citizen record, collects the fine from
-- a defendant who is online, pays the real players who took a role, and raises
-- an event a jail resource can act on.
function Court.Close(case, summary)
    CAD.Note(case.defendant.identifier, case.defendant.name, ('%s - %s'):format(case.number, summary))

    local defendantSource
    for _, playerId in ipairs(GetPlayers()) do
        local playerSource = tonumber(playerId)
        if playerSource and Bridge.GetIdentifier(playerSource) == case.defendant.identifier then
            defendantSource = playerSource
        end
    end

    local sentence = case.sentence
    if sentence and defendantSource then
        if sentence.fine > 0 then
            local account = (settings().sentencing or {}).fineAccount or 'bank'
            Bridge.RemoveMoney(defendantSource, account, sentence.fine, 'federal-court-fine')
        end
        Bridge.Notify(defendantSource, ('%s: %s'):format(case.number, summary), 'error')
    end

    local stipend = settings().stipend or {}
    local amount = tonumber(stipend.amount) or 0
    if amount > 0 then
        for role, holder in pairs(case.roles or {}) do
            if role == 'jurors' then
                for _, juror in ipairs(holder) do
                    if juror.npc ~= true and juror.source then
                        Bridge.AddMoney(juror.source, stipend.account or 'bank', amount, 'federal-court')
                    end
                end
            elseif type(holder) == 'table' and holder.npc ~= true and holder.source then
                Bridge.AddMoney(holder.source, stipend.account or 'bank', amount, 'federal-court')
            end
        end
    end

    -- Consumed by a jail resource. The court decides the sentence; serving it
    -- is somebody else's job and this resource does not pretend otherwise.
    TriggerEvent(Federal.Net('sentenced'), {
        number = case.number,
        identifier = case.defendant.identifier,
        name = case.defendant.name,
        source = defendantSource,
        verdict = case.verdict,
        months = sentence and sentence.months or 0,
        fine = sentence and sentence.fine or 0,
        charges = case.charges
    })
end

function Court.Acquit(case)
    case.stage = 'closed'
    case.stageAt = now()
    case.closedAt = now()
    case.sentence = nil
    cases.save(case.id, case)
    Court.Close(case, 'Acquitted')
    return cases.get(case.id)
end

-- Stage progression ---------------------------------------------------------------------------------

local STAGE_INDEX = {}
for index, stage in ipairs(Const.CourtStages) do STAGE_INDEX[stage] = index end

-- What has to be true before a case may leave its current stage.
local function readyToAdvance(case)
    if case.stage == 'filed' then
        if not case.roles.judge then return false, 'the case has no judge' end
        return true
    end
    if case.stage == 'arraignment' then
        if not case.plea then return false, 'no plea has been entered' end
        return true
    end
    if case.stage == 'trial' then
        return true
    end
    if case.stage == 'deliberation' then
        local jury = settings().jury or {}
        local real = 0
        for _, juror in ipairs(case.roles.jurors or {}) do
            if juror.npc ~= true then real = real + 1 end
        end
        if real < (tonumber(jury.minRealJurors) or 0) then return false, 'the jury is short' end
        return true
    end
    if case.stage == 'verdict' then
        -- A conviction is closed by passing sentence; an acquittal just closes.
        if case.verdict == 'guilty' then return false, 'pass sentence to close the case' end
        return true
    end
    return false, 'that case cannot be advanced'
end

Court.ReadyToAdvance = readyToAdvance

function Court.Advance(source, caseId)
    local case = cases.get(caseId)
    if not case then return fail('no such case') end
    if case.stage == 'closed' then return fail('that case is closed') end
    if not presiding(source, case) then return fail('only the presiding judge may move the case on') end

    return Court.Progress(case)
end

-- Moves a case one stage forward, applying whatever that transition means.
function Court.Progress(case)
    local ready, message = readyToAdvance(case)
    if not ready then return fail(message) end

    -- A guilty plea goes straight to the verdict: there is nothing to try.
    if case.stage == 'arraignment' and case.plea == 'guilty' then
        return Court.Verdict(case.id)
    end

    if case.stage == 'deliberation' then
        local verdict = Court.Verdict(case.id)
        if not verdict then return fail('the verdict could not be reached') end
        if verdict.verdict ~= 'guilty' then return Court.Acquit(verdict) end
        return verdict
    end

    if case.stage == 'verdict' then
        return Court.Acquit(case)
    end

    local index = STAGE_INDEX[case.stage] or 1
    case.stage = Const.CourtStages[math.min(index + 1, #Const.CourtStages)]
    case.stageAt = now()
    case.updatedAt = now()
    cases.save(case.id, case)
    return cases.get(case.id)
end

-- An NPC judge runs the case on a timer. A real judge is never on a timer:
-- they advance the case themselves.
function Court.Tick(nowSeconds)
    if not Court.Enabled() then return 0 end
    nowSeconds = nowSeconds or now()

    local delay = math.floor((tonumber(settings().npcJudgeDelay) or 45000) / 1000)
    local moved = 0

    for _, case in pairs(cases.all()) do
        if case.stage ~= 'closed' then
            -- Bail runs on wall-clock time regardless of who is presiding.
            if case.bail and case.bail.status == 'posted'
                and case.bail.appearBy and nowSeconds >= case.bail.appearBy then
                Court.ForfeitBail(case.id)
            end

            Court.EnsureJudge(case.id)
            local current = cases.get(case.id)
            local judge = current.roles.judge

            if judge and judge.npc == true and (nowSeconds - (current.stageAt or 0)) >= delay then
                -- An NPC judge enters a not-guilty plea for a defendant who
                -- never appeared, rather than stalling the docket forever.
                if current.stage == 'arraignment' and not current.plea then
                    current.plea = 'not_guilty'
                    current.transcript[#current.transcript + 1] = {
                        role = 'judge',
                        actor = judge.name,
                        text = 'No plea entered; a plea of not guilty is recorded.',
                        at = nowSeconds
                    }
                    cases.save(current.id, current)
                    current = cases.get(current.id)
                end

                if current.stage == 'verdict' then
                    if current.verdict == 'guilty' then
                        Court.ApplySentence(current, nil, nil, judge.name)
                    else
                        Court.Acquit(current)
                    end
                    moved = moved + 1
                elseif Court.Progress(current) then
                    moved = moved + 1
                end
            end
        end
    end
    return moved
end

-- Net wiring -------------------------------------------------------------------------------------

Bridge.RegisterCallback(Federal.Net('court:docket'), function(source, reply, filter)
    reply(Court.Docket(source, type(filter) == 'table' and filter or nil))
end)

Bridge.RegisterCallback(Federal.Net('court:case'), function(source, reply, caseId)
    reply(Court.Case(source, caseId))
end)

Bridge.RegisterCallback(Federal.Net('court:courthouses'), function(_, reply)
    reply(Court.Courthouses())
end)

Bridge.RegisterCallback(Federal.Net('court:file'), function(source, reply, payload)
    local case, message = Court.File(source, payload)
    reply(case, message)
end)

local function courtEvent(name, handler, describe)
    RegisterNetEvent(Federal.Net('court:' .. name), function(...)
        local playerSource = source
        local result, message = handler(playerSource, ...)
        if not result then
            return Bridge.Notify(playerSource, message or 'that action was refused', 'error')
        end
        Bridge.Notify(playerSource, describe(result), 'success')
    end)
end

courtEvent('take', Court.TakeRole, function() return 'You have taken your place.' end)
courtEvent('leave', Court.LeaveRole, function(result) return ('You stood down as %s.'):format(result.role) end)
courtEvent('plea', Court.Plea, function(case) return ('Plea recorded: %s.'):format((case.plea or ''):gsub('_', ' ')) end)
courtEvent('admit', Court.AdmitEvidence, function() return 'Evidence admitted.' end)
courtEvent('testify', Court.Testify, function() return 'Statement recorded.' end)
courtEvent('advance', Court.Advance, function(case) return ('The case moves to %s.'):format(case.stage) end)
courtEvent('vote', Court.Vote, function() return 'Your vote is recorded.' end)
courtEvent('sentence', Court.Sentence, function(case)
    return ('Sentence passed: %d months, $%d.'):format(case.sentence.months, case.sentence.fine)
end)
courtEvent('bail', Court.SetBail, function(case) return ('Bail set at $%d.'):format(case.bail.amount) end)
courtEvent('postBail', Court.PostBail, function(case) return ('Bail of $%d posted.'):format(case.bail.amount) end)
courtEvent('offer', Court.OfferPlea, function(case)
    return ('Offered %d months and $%d.'):format(case.offer.months, case.offer.fine)
end)
courtEvent('acceptOffer', Court.AcceptPlea, function(case)
    return ('Agreed: %d months, $%d.'):format(case.sentence.months, case.sentence.fine)
end)
courtEvent('rejectOffer', Court.RejectPlea, function() return 'The offer is rejected.' end)
courtEvent('continue', Court.Continue, function(case) return ('Case put back (%d).'):format(case.continuances) end)
courtEvent('houseSave', Court.SaveCourthouse, function(house) return ('Saved %s.'):format(house.label) end)
courtEvent('houseDelete', Court.DeleteCourthouse, function(house) return ('Deleted %s.'):format(house.label) end)
courtEvent('seatSave', Court.SaveSeat, function(seat) return ('Placed %s.'):format(seat.label) end)
courtEvent('seatDelete', Court.DeleteSeat, function(seat) return ('Removed %s.'):format(seat.label) end)

CreateThread(function()
    while true do
        Wait(15000)
        if Court.Enabled() then Court.Tick() end
    end
end)

return Court
