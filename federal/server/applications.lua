-- Agency application forms.
--
-- Each agency can build a custom application form (its own questions), place
-- application desks in the world that ANYONE may use, and review what comes
-- in from the boss menu. Approving an application hires the applicant
-- automatically: they get the agency job at the grade the form is configured
-- to grant, and the division the form assigns, in one action.
--
-- The form and its desks are edited from /fedconfig (roster.manage scope);
-- submissions are stored in the resource's own store and survive restarts.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Util = Federal.Util
local Schema = Federal.Schema
local Core = Federal.Core

local Applications = {}
Federal.Applications = Applications

local forms = DAG.Repository.Create('federal_application_forms')
local inbox = DAG.Repository.Create('federal_applications')

local MAX_QUESTIONS = 12
local MAX_PLACES = 8
local MAX_ANSWER = 300
local MAX_PENDING_PER_AGENCY = 100

local function fail(message)
    return nil, message
end

-- The stored record, always whole: form meta, questions, desk places.
local function record(agencyId)
    local stored = forms.get(agencyId)
    local result = stored and Util.Copy(stored) or { id = agencyId }
    result.form = type(result.form) == 'table' and result.form or {}
    result.form.enabled = result.form.enabled == true
    result.form.title = Util.Text(result.form.title, 60, 'Application')
    result.form.rank = math.floor(Util.Clamp(tonumber(result.form.rank) or 0, 0, 100))
    result.form.division = Util.IsSlug(result.form.division) and result.form.division or nil
    result.form.questions = type(result.form.questions) == 'table' and result.form.questions or {}
    result.places = type(result.places) == 'table' and result.places or {}
    return result
end

Applications.GetForm = record

-- Every desk of every agency whose form is enabled: what the clients render.
function Applications.Places()
    local all = {}
    for _, agency in ipairs(Core.Agencies()) do
        local stored = record(agency.id)
        if stored.form.enabled then
            for _, place in ipairs(stored.places) do
                all[#all + 1] = {
                    agency = agency.id,
                    short = agency.short,
                    color = agency.blip and agency.blip.color or 26,
                    id = place.id,
                    label = place.label,
                    coords = place.coords,
                    title = stored.form.title
                }
            end
        end
    end
    return all
end

local function broadcastPlaces()
    TriggerClientEvent(Federal.Net('apps:places'), -1, Applications.Places())
end

Applications.BroadcastPlaces = broadcastPlaces

local function persist(stored)
    local saved, message = forms.save(stored.id, stored)
    if not saved then return fail(message or 'the form could not be saved') end
    broadcastPlaces()
    Core.Sync()
    return true
end

-- Form editing (config panel; roster.manage scope) ---------------------------

function Applications.SaveForm(source, agencyId, payload)
    local agency, message = Federal.Editor.EditableFor(source, agencyId, 'roster.manage')
    if not agency then return fail(message) end
    payload = type(payload) == 'table' and payload or {}

    local stored = record(agency.id)
    if payload.enabled ~= nil then stored.form.enabled = payload.enabled == true end
    if payload.title ~= nil then stored.form.title = Util.Text(payload.title, 60, stored.form.title) end
    if payload.rank ~= nil then stored.form.rank = math.floor(Util.Clamp(tonumber(payload.rank) or 0, 0, 100)) end
    if payload.division ~= nil then
        stored.form.division = Util.IsSlug(payload.division) and payload.division or nil
    end

    local ok, saveMessage = persist(stored)
    if not ok then return fail(saveMessage) end
    return stored.form
end

function Applications.SaveQuestion(source, agencyId, payload)
    local agency, message = Federal.Editor.EditableFor(source, agencyId, 'roster.manage')
    if not agency then return fail(message) end
    payload = type(payload) == 'table' and payload or {}

    local label = Util.Text(payload.label, 120)
    if not label then return fail('a question needs its text') end

    local stored = record(agency.id)

    -- A new question gets the first free q<N> id; a time-derived id would
    -- collide when two questions are added in the same second.
    local id = payload.id
    if not Util.IsSlug(id) then
        local index = 1
        repeat
            id = ('q%d'):format(index)
            index = index + 1
        until not Schema.FindById(stored.form.questions, id)
    end

    local question = {
        id = id,
        label = label,
        required = payload.required == true
    }

    local _, index = Schema.FindById(stored.form.questions, question.id)
    if index then
        stored.form.questions[index] = question
    else
        if #stored.form.questions >= MAX_QUESTIONS then
            return fail(('a form is limited to %d questions'):format(MAX_QUESTIONS))
        end
        stored.form.questions[#stored.form.questions + 1] = question
    end

    local ok, saveMessage = persist(stored)
    if not ok then return fail(saveMessage) end
    return question
end

function Applications.DeleteQuestion(source, agencyId, questionId)
    local agency, message = Federal.Editor.EditableFor(source, agencyId, 'roster.manage')
    if not agency then return fail(message) end

    local stored = record(agency.id)
    local question, index = Schema.FindById(stored.form.questions, questionId)
    if not index then return fail('no such question') end

    table.remove(stored.form.questions, index)
    local ok, saveMessage = persist(stored)
    if not ok then return fail(saveMessage) end
    return question
end

function Applications.SavePlace(source, agencyId, payload)
    local agency, message = Federal.Editor.EditableFor(source, agencyId, 'roster.manage')
    if not agency then return fail(message) end
    payload = type(payload) == 'table' and payload or {}

    local coords = Util.ToCoords(payload.coords)
    if not coords then return fail('a desk needs x, y and z coordinates') end

    local stored = record(agency.id)
    local place = {
        id = Util.IsSlug(payload.id) and payload.id or Util.Slug(payload.label or 'desk', ('desk-%d'):format(#stored.places + 1)),
        label = Util.Text(payload.label, 60, 'Application desk'),
        coords = coords
    }

    local _, index = Schema.FindById(stored.places, place.id)
    if index then
        stored.places[index] = place
    else
        if #stored.places >= MAX_PLACES then
            return fail(('an agency is limited to %d application desks'):format(MAX_PLACES))
        end
        stored.places[#stored.places + 1] = place
    end

    local ok, saveMessage = persist(stored)
    if not ok then return fail(saveMessage) end
    return place
end

function Applications.DeletePlace(source, agencyId, placeId)
    local agency, message = Federal.Editor.EditableFor(source, agencyId, 'roster.manage')
    if not agency then return fail(message) end

    local stored = record(agency.id)
    local place, index = Schema.FindById(stored.places, placeId)
    if not index then return fail('no such desk') end

    table.remove(stored.places, index)
    local ok, saveMessage = persist(stored)
    if not ok then return fail(saveMessage) end
    return place
end

-- Applying (public) ----------------------------------------------------------

local function pendingFor(agencyId, identifier)
    for _, submission in pairs(inbox.all()) do
        if submission.agency == agencyId and submission.identifier == identifier
            and submission.status == 'pending' then
            return submission
        end
    end
    return nil
end

function Applications.PendingCount(agencyId)
    local count = 0
    for _, submission in pairs(inbox.all()) do
        if submission.agency == agencyId and submission.status == 'pending' then count = count + 1 end
    end
    return count
end

-- Anyone standing at one of the agency's desks may submit; members of that
-- agency may not (they already work there). Distance is checked against the
-- desk the SERVER knows about.
function Applications.Submit(source, agencyId, answers)
    local agency = Core.Agency(agencyId)
    if not agency then return fail('no such agency') end

    local stored = record(agencyId)
    if not stored.form.enabled then return fail('that agency is not taking applications') end

    local membership = Core.Membership(source)
    if membership and membership.agency.id == agencyId then
        return fail('you already work there')
    end

    local position = Core.Coords(source)
    local atDesk = false
    for _, place in ipairs(stored.places) do
        local distance = position and Util.Distance(position, place.coords)
        if distance and distance <= 5.0 then atDesk = true break end
    end
    if not atDesk then return fail('you must be at an application desk') end

    local identifier = Bridge.GetIdentifier(source)
    if not identifier then return fail('your identity could not be read') end
    if pendingFor(agencyId, identifier) then return fail('you already have an application pending with them') end
    if Applications.PendingCount(agencyId) >= MAX_PENDING_PER_AGENCY then
        return fail('their inbox is full - try again later')
    end

    -- Answers pair up with the questions by position; required ones must be
    -- filled, and everything is truncated before it is stored.
    local filed = {}
    answers = type(answers) == 'table' and answers or {}
    for index, question in ipairs(stored.form.questions) do
        local answer = Util.Text(tostring(answers[index] or ''), MAX_ANSWER)
        if question.required and not answer then
            return fail(('"%s" needs an answer'):format(question.label))
        end
        filed[#filed + 1] = { label = question.label, answer = answer or '-' }
    end

    local submission = {
        id = ('app-%s-%d'):format(agencyId, os.time()),
        agency = agencyId,
        identifier = identifier,
        name = Bridge.GetName(source),
        answers = filed,
        status = 'pending',
        at = os.time()
    }

    local saved, message = inbox.save(submission.id, submission)
    if not saved then return fail(message or 'the application could not be filed') end

    -- Tell every online reviewer there is something to read.
    for _, playerId in ipairs(GetPlayers()) do
        local playerSource = tonumber(playerId)
        if playerSource then
            local reviewer = Core.Membership(playerSource)
            if reviewer and reviewer.agency.id == agencyId and Core.Can(playerSource, 'roster.manage') then
                Bridge.Notify(playerSource, ('New application to the %s from %s.'):format(agency.short, submission.name), 'inform')
            end
        end
    end

    return submission
end

-- Review (boss menu; roster.manage) ------------------------------------------

local function reviewer(source, agencyId)
    if Core.IsAdmin(source) then return Core.Agency(agencyId) end
    local membership = Core.Membership(source)
    if not membership or membership.agency.id ~= agencyId then return nil end
    if not Core.Can(source, 'roster.manage') then return nil end
    return membership.agency
end

function Applications.List(source, agencyId)
    if not reviewer(source, agencyId) then return {} end

    local now = os.time()
    local list = {}
    for _, submission in pairs(inbox.all()) do
        if submission.agency == agencyId and submission.status == 'pending' then
            local copy = Util.Copy(submission)
            -- The client runtime has no clock library, so age ships computed.
            copy.age = now - (tonumber(copy.at) or now)
            list[#list + 1] = copy
        end
    end
    table.sort(list, function(a, b) return (a.at or 0) < (b.at or 0) end)
    return list
end

local function onlineByIdentifier(identifier)
    for _, playerId in ipairs(GetPlayers()) do
        local playerSource = tonumber(playerId)
        if playerSource and Bridge.GetIdentifier(playerSource) == identifier then
            return playerSource
        end
    end
    return nil
end

-- Approval is the automation: agency job at the form's grade, the form's
-- division, one click. The applicant must be online, because job changes go
-- through the framework's live player object.
function Applications.Decide(source, submissionId, approve)
    local submission = inbox.get(submissionId)
    if not submission or submission.status ~= 'pending' then return fail('that application is gone') end

    local agency = reviewer(source, submission.agency)
    if not agency then return fail('not authorized') end

    if not approve then
        submission.status = 'denied'
        submission.decidedBy = Bridge.GetName(source)
        submission.decidedAt = os.time()
        inbox.save(submission.id, submission)

        local target = onlineByIdentifier(submission.identifier)
        if target then
            Bridge.Notify(target, ('Your application to the %s was declined.'):format(agency.label), 'error')
        end
        return submission
    end

    local target = onlineByIdentifier(submission.identifier)
    if not target then return fail('the applicant must be online to be hired') end

    local existing = Bridge.GetJob(target)
    if existing and Util.Contains(agency.jobs, existing.name) then
        return fail('they already work there')
    end

    local stored = record(agency.id)
    local grade = stored.form.rank or 0
    if not Bridge.SetJob(target, agency.jobs[1], grade) then
        return fail('the framework refused the job change')
    end

    if stored.form.division and Schema.FindById(agency.divisions or {}, stored.form.division) then
        Core.AssignDivision(submission.identifier, agency.id, stored.form.division)
    end

    submission.status = 'approved'
    submission.decidedBy = Bridge.GetName(source)
    submission.decidedAt = os.time()
    inbox.save(submission.id, submission)

    local rank = Core.Rank(agency, grade)
    Bridge.Notify(target, ('Your application was approved - welcome to the %s as %s.'):format(
        agency.label, rank and rank.label or ('grade ' .. grade)), 'success')
    Core.Sync(target)
    return submission
end

-- Net wiring ------------------------------------------------------------------

RegisterNetEvent(Federal.Net('apps:form'), function(agencyId, payload)
    local playerSource = source
    if type(agencyId) ~= 'string' then return end
    local form, message = Applications.SaveForm(playerSource, agencyId, payload)
    Bridge.Notify(playerSource, form and 'Application form saved.' or message, form and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('apps:question'), function(agencyId, payload)
    local playerSource = source
    if type(agencyId) ~= 'string' then return end
    local question, message = Applications.SaveQuestion(playerSource, agencyId, payload)
    Bridge.Notify(playerSource, question and 'Question saved.' or message, question and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('apps:questionDelete'), function(agencyId, questionId)
    local playerSource = source
    if type(agencyId) ~= 'string' or type(questionId) ~= 'string' then return end
    local question, message = Applications.DeleteQuestion(playerSource, agencyId, questionId)
    Bridge.Notify(playerSource, question and 'Question removed.' or message, question and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('apps:place'), function(agencyId, payload)
    local playerSource = source
    if type(agencyId) ~= 'string' then return end
    local place, message = Applications.SavePlace(playerSource, agencyId, payload)
    Bridge.Notify(playerSource, place and ('Placed %s.'):format(place.label) or message, place and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('apps:placeDelete'), function(agencyId, placeId)
    local playerSource = source
    if type(agencyId) ~= 'string' or type(placeId) ~= 'string' then return end
    local place, message = Applications.DeletePlace(playerSource, agencyId, placeId)
    Bridge.Notify(playerSource, place and ('Removed %s.'):format(place.label) or message, place and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('apps:submit'), function(agencyId, answers)
    local playerSource = source
    if type(agencyId) ~= 'string' then return end
    local submission, message = Applications.Submit(playerSource, agencyId, answers)
    Bridge.Notify(playerSource,
        submission and 'Application submitted. You will hear back from them.' or message,
        submission and 'success' or 'error')
end)

RegisterNetEvent(Federal.Net('apps:decide'), function(submissionId, approve)
    local playerSource = source
    if type(submissionId) ~= 'string' then return end
    local submission, message = Applications.Decide(playerSource, submissionId, approve == true)
    Bridge.Notify(playerSource,
        submission and ('Application from %s %s.'):format(submission.name, submission.status) or message,
        submission and 'success' or 'error')
end)

-- The public read: what an applicant is asked. No auth - anyone at a desk.
Bridge.RegisterCallback(Federal.Net('apps:questions'), function(source, reply, agencyId)
    if type(agencyId) ~= 'string' then return reply(nil, 'no agency') end
    local stored = record(agencyId)
    if not stored.form.enabled then return reply(nil, 'not taking applications') end
    reply({ title = stored.form.title, questions = stored.form.questions })
end)

Bridge.RegisterCallback(Federal.Net('apps:list'), function(source, reply, agencyId)
    reply(Applications.List(source, type(agencyId) == 'string' and agencyId or ''))
end)

Bridge.RegisterCallback(Federal.Net('apps:places'), function(source, reply)
    reply(Applications.Places())
end)

-- Same restart guarantee as the doors: desks come back on their own.
CreateThread(function()
    Wait(2000)
    broadcastPlaces()
end)

AddEventHandler('playerJoining', function()
    local playerSource = source
    SetTimeout(6000, function()
        TriggerClientEvent(Federal.Net('apps:places'), playerSource, Applications.Places())
    end)
end)

return Applications
