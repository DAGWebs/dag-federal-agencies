-- Field investigation: interviewing the world.
--
-- An auto-filed crime (a bank flagging fraud, an alarm panel) leaves a
-- scene but no scripted actors, and a scene with nobody to talk to used to
-- be a dead end. This makes ANY nearby NPC interviewable: they get a
-- persistent identity, they answer with a statement written for the kind of
-- case being worked, pressing them can shake loose a real lead, a formal
-- statement files onto the case, and the scene's CCTV can be pulled once as
-- documentary evidence.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Util = Federal.Util
local Core = Federal.Core
local CAD = Federal.CAD

local Investigation = {}
Federal.Investigation = Investigation

local function fail(message)
    return nil, message
end

-- Witness identities, keyed by the stable per-ped key the client mints.
-- In memory on purpose: ambient peds do not survive restarts either.
local witnesses = {}

local FIRST = {
    'Alex', 'Morgan', 'Jamie', 'Casey', 'Riley', 'Jordan', 'Taylor', 'Quinn',
    'Avery', 'Dana', 'Lee', 'Sam', 'Robin', 'Frankie', 'Marion', 'Harper'
}
local LAST = {
    'Alvarez', 'Brooks', 'Carter', 'Delgado', 'Ellis', 'Fischer', 'Grant',
    'Hughes', 'Iverson', 'Jennings', 'Klein', 'Lawson', 'Mercer', 'Novak', 'Osei', 'Price'
}

local DESCRIPTORS = {
    'a tall man in a grey suit', 'a woman in a red jacket', 'two men in hoodies',
    'a nervous younger guy', 'a well-dressed older man', 'someone in a courier uniform',
    'a woman who kept her sunglasses on indoors'
}

-- First statements, written per kind of case. %s is the suspect descriptor.
local STATEMENTS = {
    financial = {
        'I was near the counter when %s came in. They kept pushing papers at the teller and would not show a second ID.',
        'The teller looked rattled. %s wanted a large withdrawal and claimed a manager had already approved it.',
        '%s has been in twice this week. Same account, but the name on the slip was different the second time.',
        'I heard %s arguing about a declined transfer. They knew the account numbers by heart, which felt wrong.'
    },
    theft = {
        'It happened fast. %s grabbed what they came for and walked straight out like they owned the place.',
        'I saw %s watching the place for a while first, checking the doors.',
        '%s bumped into me on the way out - in a real hurry, kept looking back.'
    },
    generic = {
        'I did see something. %s was hanging around here right before it happened.',
        'There was %s acting strangely - kept checking a phone and watching the entrance.',
        'You should ask about %s. They left in a hurry right around then.'
    }
}

-- What pressing a witness can shake loose. Each becomes a real lead.
local LEAD_DETAILS = {
    { kind = 'contact', text = 'Now that you mention it - they spoke to a courier out front. He works this block most days.' },
    { kind = 'ledger', text = 'They dropped a receipt. I did not touch it, but it had account numbers scribbled on the back.' },
    { kind = 'contact', text = 'A cab picked them up. Same driver waits outside the coffee place around the corner.' },
    { kind = 'name', text = 'The teller called them by name - I only caught the surname, but it did not match the slip.' }
}

local PRESSED_NOTHING = {
    'That is honestly everything I saw.',
    'I have told you what I know. I was not trying to get involved.',
    'No - that is all of it. I need to get going.'
}

local function generateIdentity(key)
    return {
        key = key,
        name = ('%s %s'):format(FIRST[math.random(#FIRST)], LAST[math.random(#LAST)]),
        dob = ('%02d/%02d/%d'):format(math.random(1, 28), math.random(1, 12), math.random(1958, 2004)),
        identifier = ('wit:%s'):format(key),
        statements = 0
    }
end

-- A location of (0,0) is "no location": auto-filed incidents ship that when
-- the reporting resource had nothing better.
local function realLocation(location)
    if type(location) ~= 'table' then return nil end
    local x, y = tonumber(location.x) or 0, tonumber(location.y) or 0
    if math.abs(x) < 1.0 and math.abs(y) < 1.0 then return nil end
    return location
end

Investigation.RealLocation = realLocation

-- The open, located incident of the officer's agency nearest to where they
-- are standing: the case this interview is being worked FOR.
local function nearestIncident(membership, coords, radius)
    if not coords then return nil end
    local best, bestDistance
    for _, record in pairs(CAD.incidents.all()) do
        if record.agency == membership.agency.id and record.status ~= 'closed' then
            local location = realLocation(record.location)
            if location then
                local distance = Util.Distance(coords, location)
                if distance and distance <= (radius or 80.0) and (not bestDistance or distance < bestDistance) then
                    best, bestDistance = record, distance
                end
            end
        end
    end
    return best
end

Investigation.NearestIncident = nearestIncident

local function statementBucket(kind)
    kind = tostring(kind or ''):lower()
    if kind:find('financ') or kind:find('fraud') or kind:find('launder') then return 'financial' end
    if kind:find('theft') or kind:find('robb') or kind:find('burg') then return 'theft' end
    return 'generic'
end

-- Custom flows ----------------------------------------------------------------
--
-- What witnesses say is configurable at three levels, most specific first:
--   1. per incident  - set by the filing script (dag-banking etc.) via the
--                      FileReport/SetInvestigationFlow exports
--   2. per callout   - an `investigation` block on the callout template
--   3. per agency    - flows managed in /fedconfig, matched by keyword
--                      against the case type
-- with the built-in statement buckets as the final fallback.

local incidentFlows = {}

-- Accepts { statements = {'...'}, leads = { {kind,text} or 'kind: text' } }.
local function normalizeFlow(flow)
    if type(flow) ~= 'table' then return nil end
    local out = { statements = {}, leads = {} }
    for _, line in ipairs(flow.statements or {}) do
        local text = Util.Text(line, 240)
        if text and #out.statements < 10 then out.statements[#out.statements + 1] = text end
    end
    for _, entry in ipairs(flow.leads or {}) do
        local kind, text
        if type(entry) == 'table' then
            kind, text = entry.kind, entry.text
        elseif type(entry) == 'string' then
            kind, text = entry:match('^(%w+)%s*:%s*(.+)$')
            if not kind then kind, text = 'contact', entry end
        end
        text = Util.Text(text, 240)
        if text and #out.leads < 8 then
            out.leads[#out.leads + 1] = {
                kind = (kind == 'ledger' or kind == 'name' or kind == 'address') and kind or 'contact',
                text = text
            }
        end
    end
    if #out.statements == 0 and #out.leads == 0 then return nil end
    return out
end

function Investigation.SetFlow(incidentId, flow)
    local normalized = normalizeFlow(flow)
    if type(incidentId) ~= 'string' or not normalized then return false end
    incidentFlows[incidentId] = normalized
    return true
end

-- The flow that applies to this interview's context.
local function resolveFlow(membership, incident, callout)
    if callout and type(callout.investigation) == 'table' then
        local flow = normalizeFlow(callout.investigation)
        if flow then return flow end
    end
    if incident and incidentFlows[incident.id] then
        return incidentFlows[incident.id]
    end
    local matchText = tostring((incident and incident.type) or (callout and callout.label) or ''):lower()
    for _, configured in ipairs(membership.agency.investigations or {}) do
        if configured.match and matchText:find(configured.match, 1, true) then
            local flow = normalizeFlow(configured)
            if flow then return flow end
        end
    end
    return nil
end

-- One round of questions. The first round gets the eyewitness account; each
-- further round presses them, and once per witness that can produce a lead.
function Investigation.Interview(source, key)
    local membership = Core.Require(source, 'actions.search')
    if not membership then return fail('not authorized') end

    key = Util.Text(key, 48)
    if not key then return fail('nobody to interview') end

    local coords = Core.Coords(source)
    local callout = Federal.Callouts and Federal.Callouts.NearestScene
        and Federal.Callouts.NearestScene(membership.agency.id, coords, 60.0) or nil
    local incident = nearestIncident(membership, coords)
    local caseNumber = (callout and callout.number) or (incident and incident.number) or nil
    local flow = resolveFlow(membership, incident, callout)

    local witness = witnesses[key]
    if not witness then
        witness = generateIdentity(key)
        witnesses[key] = witness
    end
    witness.statements = witness.statements + 1
    if incident then witness.incidentId = incident.id end
    if callout then witness.calloutId = callout.id end

    local statement, leadNote
    if witness.statements == 1 then
        witness.descriptor = DESCRIPTORS[math.random(#DESCRIPTORS)]
        local lines = (flow and #flow.statements > 0) and flow.statements
            or STATEMENTS[statementBucket((incident and incident.type) or (callout and callout.label))]
        statement = lines[math.random(#lines)]:format(witness.descriptor)
    elseif not witness.leadGiven and (incident or callout)
        and math.random() < math.max(0.15, 0.8 - (witness.attitude or 0) * 0.06) then
        witness.leadGiven = true
        local pool = (flow and #flow.leads > 0) and flow.leads or LEAD_DETAILS
        local detail = pool[math.random(#pool)]
        statement = detail.text
        -- The detail is a real lead when the officer can file one. A lead
        -- tied to a callout feeds that callout's reveal machinery too.
        if Core.Can(source, 'cad.write') and Federal.Leads and Federal.Leads.Manual then
            local lead = Federal.Leads.Manual(source, {
                kind = detail.kind,
                calloutId = witness.calloutId,
                origin = ('Interview: %s'):format(witness.name),
                subject = witness.identifier,
                summary = ('%s (re %s): %s'):format(witness.name, caseNumber or 'the scene', statement)
            })
            if lead then leadNote = ('Lead %s filed from this interview.'):format(lead.number) end
        end
    else
        statement = PRESSED_NOTHING[math.random(#PRESSED_NOTHING)]
    end
    witness.lastStatement = statement

    return {
        name = witness.name,
        dob = witness.dob,
        identifier = witness.identifier,
        statement = statement,
        caseNumber = caseNumber,
        lead = leadNote,
        attitude = witness.attitude or 0,
        pressed = witness.statements > 1
    }
end

-- Approach and compliance ------------------------------------------------------
--
-- Every person carries an attitude score for how the officers have treated
-- them: reassurance lowers it, leaning on them raises it. High attitude
-- risks a reaction - the ped bolting or swinging - and lowers cooperation.

local function attitudeOf(witness)
    return witness.attitude or 0
end

local function rollReaction(witness)
    local attitude = attitudeOf(witness)
    if attitude < 4 then return nil end
    if math.random() < (attitude - 3) * 0.12 then
        return math.random() < 0.5 and 'attack' or 'flee'
    end
    return nil
end

local CALM_LINES = {
    'They breathe out and relax a little. "Okay. Okay - I want to help."',
    'A nod. "Thanks for being straight with me, officer."',
    'They lower their shoulders. "Ask what you need to ask."'
}
local HARD_LINES = {
    'Their jaw tightens. "You cannot talk to me like that."',
    'They step back, hands up. "I do not have to say anything."',
    'A glare. "Keep pushing and I am done talking."'
}

function Investigation.Approach(source, key, tone)
    local membership = Core.Require(source, 'actions.search')
    if not membership then return fail('not authorized') end

    local witness = witnesses[Util.Text(key, 48) or '']
    if not witness then return fail('interview them first') end

    if tone == 'calm' then
        witness.attitude = math.max(0, attitudeOf(witness) - 2)
        return {
            attitude = witness.attitude,
            line = CALM_LINES[math.random(#CALM_LINES)],
            reaction = nil
        }
    end

    -- Leaning on them: shakes loose details more readily, at a price.
    witness.attitude = math.min(10, attitudeOf(witness) + 2)
    return {
        attitude = witness.attitude,
        line = HARD_LINES[math.random(#HARD_LINES)],
        reaction = rollReaction(witness)
    }
end

-- The verbal arrest: ordered, not forced. Compliance falls as attitude
-- rises; a hostile subject may bolt or swing instead of complying.
function Investigation.OrderArrest(source, key)
    local membership = Core.Require(source, 'actions.arrest')
    if not membership then return fail('not authorized') end

    local witness = witnesses[Util.Text(key, 48) or '']
    if not witness then return fail('make contact with them first') end

    local attitude = attitudeOf(witness)
    local compliance = 0.9 - attitude * 0.09
    if math.random() < compliance then
        witness.underArrest = true
        return { result = 'comply', attitude = attitude,
            line = ('%s raises their hands. "Alright! Alright - do not shoot."'):format(witness.name) }
    end

    witness.attitude = math.min(10, attitude + 2)
    local reaction = math.random() < 0.5 and 'attack' or 'flee'
    return { result = reaction, attitude = witness.attitude,
        line = reaction == 'attack'
            and ('%s squares up instead of complying.'):format(witness.name)
            or ('%s bolts.'):format(witness.name) }
end

-- Booking an NPC: the arrest lands on their record like any other booking,
-- and where the court module is present a case is filed against them.
function Investigation.ArrestNPC(source, key, charges)
    local membership = Core.Require(source, 'actions.arrest')
    if not membership then return fail('not authorized') end

    local witness = witnesses[Util.Text(key, 48) or '']
    if not witness then return fail('make contact with them first') end

    local chargeList = {}
    for _, charge in ipairs(type(charges) == 'table' and charges or {}) do
        local text = Util.Text(charge, 60)
        if text and #chargeList < 8 then chargeList[#chargeList + 1] = text end
    end
    if #chargeList == 0 then return fail('an arrest requires at least one charge') end

    local record = CAD.Record(witness.identifier, witness.name)
    if not record then return fail('no usable identity') end
    record.arrests = record.arrests or {}
    record.arrests[#record.arrests + 1] = {
        at = os.time(),
        officer = membership.name,
        charges = chargeList
    }
    CAD.records.save(record.identifier, record)

    local caseNumber
    if Federal.Court and Federal.Court.File then
        local ok, case = pcall(Federal.Court.File, source, {
            identifier = witness.identifier,
            name = witness.name,
            charges = chargeList
        })
        if ok and type(case) == 'table' then caseNumber = case.number end
    end

    witness.arrested = true
    return {
        name = witness.name,
        charges = chargeList,
        caseNumber = caseNumber
    }
end

-- The formal version: what they said goes onto the case as a witness entry
-- plus a narrative line, under their taken identity.
function Investigation.Statement(source, key)
    local membership = Core.Require(source, 'actions.search')
    if not membership then return fail('not authorized') end

    local witness = witnesses[Util.Text(key, 48) or '']
    if not witness or not witness.lastStatement then return fail('interview them first') end

    -- Callout scenes without a filed incident: the statement rides on the
    -- callout and lands in its record for the court file.
    if not witness.incidentId and witness.calloutId then
        if Federal.Callouts and Federal.Callouts.AddStatement then
            Federal.Callouts.AddStatement(witness.calloutId, {
                name = witness.name, dob = witness.dob, text = witness.lastStatement, at = os.time()
            })
        end
        return { caseNumber = 'the active callout', name = witness.name }
    end
    if not witness.incidentId then return fail('no open case near this scene to file against') end

    local attached = CAD.AttachWitness(source, witness.incidentId, {
        name = witness.name,
        identifier = witness.identifier,
        statement = witness.lastStatement:sub(1, 200)
    })
    -- "Already on the case" just means the earlier statement stood; the
    -- narrative line below still lands.
    CAD.AddNarrative(source, witness.incidentId,
        ('Witness statement - %s (DOB %s): "%s"'):format(witness.name, witness.dob, witness.lastStatement))

    local incident = CAD.incidents.get(witness.incidentId)
    return {
        caseNumber = incident and incident.number or witness.incidentId,
        name = witness.name,
        alreadyListed = attached == nil
    }
end

-- Pulling the scene's CCTV: once per case, produces documentary evidence, a
-- narrative entry, and (usually) something worth chasing.
function Investigation.CCTV(source)
    local membership = Core.Require(source, 'actions.search')
    if not membership then return fail('not authorized') end

    local coords = Core.Coords(source)
    local incident = nearestIncident(membership, coords, 50.0)
    if not incident then return fail('no open case scene near here - mark the scene on the case first') end
    if incident.cctvReviewed then return fail('the footage for that case has already been pulled') end

    incident.cctvReviewed = true
    incident.updatedAt = os.time()
    CAD.incidents.save(incident.id, incident)

    local descriptor = DESCRIPTORS[math.random(#DESCRIPTORS)]
    local summary = ('Footage shows %s at the location in the relevant window.'):format(descriptor)

    local evidence = CAD.CollectEvidence(source, {
        kind = 'document',
        label = ('CCTV export - %s'):format(incident.number),
        incidentId = incident.id,
        location = incident.location
    })
    CAD.AddNarrative(source, incident.id, ('CCTV reviewed: %s'):format(summary))

    local leadNote
    if math.random() < 0.6 and Core.Can(source, 'cad.write') and Federal.Leads and Federal.Leads.Manual then
        local lead = Federal.Leads.Manual(source, {
            kind = 'name',
            origin = 'CCTV review',
            summary = ('CCTV (re %s): %s A partial view of their ID may be recoverable.'):format(incident.number, summary)
        })
        if lead then leadNote = ('Lead %s filed from the footage.'):format(lead.number) end
    end

    return {
        caseNumber = incident.number,
        summary = summary,
        evidenceNumber = evidence and evidence.number or nil,
        lead = leadNote
    }
end

-- Net wiring -------------------------------------------------------------------

Bridge.RegisterCallback(Federal.Net('investigate:interview'), function(source, reply, key)
    local result, message = Investigation.Interview(source, key)
    reply(result, message)
end)

Bridge.RegisterCallback(Federal.Net('investigate:statement'), function(source, reply, key)
    local result, message = Investigation.Statement(source, key)
    reply(result, message)
end)

Bridge.RegisterCallback(Federal.Net('investigate:cctv'), function(source, reply)
    local result, message = Investigation.CCTV(source)
    reply(result, message)
end)

Bridge.RegisterCallback(Federal.Net('investigate:approach'), function(source, reply, key, tone)
    local result, message = Investigation.Approach(source, key, tone == 'calm' and 'calm' or 'hard')
    reply(result, message)
end)

Bridge.RegisterCallback(Federal.Net('investigate:order'), function(source, reply, key)
    local result, message = Investigation.OrderArrest(source, key)
    reply(result, message)
end)

Bridge.RegisterCallback(Federal.Net('investigate:arrestNpc'), function(source, reply, key, charges)
    local result, message = Investigation.ArrestNPC(source, key, charges)
    reply(result, message)
end)

-- Public API ------------------------------------------------------------------
--
-- For other resources (dag-banking and friends). FileInvestigation opens a
-- system incident WITH a scene and, optionally, its own witness flow:
--
--   exports['dag-federal-agencies']:FileInvestigation('fib', {
--       title = 'Structured deposits at Fleeca Legion',
--       type = 'Financial crime',
--       narrative = '...',
--       location = vector3(x, y, z),      -- the actual branch!
--       suspect = { name = '...', identifier = '...' },
--       investigation = {
--           statements = { 'The teller said %s insisted on...', ... },
--           leads = { 'ledger: They left a deposit slip behind.', ... }
--       }
--   })

exports('FileInvestigation', function(agencyId, payload)
    payload = type(payload) == 'table' and payload or {}
    local record, message = CAD.FileSystemIncident(tostring(agencyId or ''), payload)
    if not record then return nil, message end
    if payload.investigation then Investigation.SetFlow(record.id, payload.investigation) end
    return { id = record.id, number = record.number }
end)

exports('SetInvestigationFlow', function(incidentId, flow)
    return Investigation.SetFlow(tostring(incidentId or ''), flow)
end)

exports('AddRecordNote', function(identifier, name, text)
    local record = CAD.Note(tostring(identifier or ''), name, text)
    return record ~= nil
end)

return Investigation
