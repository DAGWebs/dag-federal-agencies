-- The investigation callout engine.
--
-- A callout is a case with stages, not a waypoint. Officers attach to it, work
-- the stages in order, and closing it files a real CAD incident carrying the
-- evidence they collected. Stage progress is validated here: the client says
-- "I interviewed the witness", the server checks that this officer is attached
-- to that callout and is standing at the scene before it believes them.
--
-- Suspects come from one of two places. When `playerSuspects` is on and a real
-- player is carrying an active warrant, they become the subject of the
-- investigation; otherwise an NPC is spawned by the scene host. This is what
-- keeps the warrants players write from being a dead end.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Bridge = DAG.Framework
local Util = Federal.Util
local Const = Federal.Constants
local Core = Federal.Core
local CAD = Federal.CAD

local Callouts = {}
Federal.Callouts = Callouts

local active, sequence = {}, 0
Callouts.active = active

local function fail(message)
    return nil, message
end

local function settings()
    return (Config.Federal or {}).callouts or {}
end

-- Templates -------------------------------------------------------------------

local templateCache

-- Rejects a template rather than dispatching a case whose stages can never be
-- completed: an unknown objective kind has no validator, so it would strand
-- every officer who attached to it.
local function normalizeTemplate(raw)
    if type(raw) ~= 'table' then return nil, 'a callout template must be a table' end
    if not Util.IsSlug(raw.id) then return nil, 'a callout template requires an id' end
    if type(raw.locations) ~= 'table' or #raw.locations == 0 then return nil, 'a callout template requires locations' end
    if type(raw.stages) ~= 'table' or #raw.stages == 0 then return nil, 'a callout template requires stages' end

    local locations = {}
    for _, entry in ipairs(raw.locations) do
        local coords = Util.ToCoords(entry)
        if coords then locations[#locations + 1] = coords end
    end
    if #locations == 0 then return nil, 'a callout template requires usable locations' end

    local stages = {}
    for index, stage in ipairs(raw.stages) do
        if not Const.ObjectiveKinds[stage.kind] then
            return nil, ('unknown objective kind "%s" in template "%s"'):format(tostring(stage.kind), raw.id)
        end
        stages[index] = {
            id = Util.Slug(stage.id or stage.kind, stage.kind),
            kind = stage.kind,
            label = Util.Text(stage.label, 90, Const.ObjectiveKinds[stage.kind]),
            radius = Util.Clamp(tonumber(stage.radius) or 25.0, 5.0, 200.0),
            count = math.floor(Util.Clamp(tonumber(stage.count) or 1, 1, 10)),
            kinds = type(stage.kinds) == 'table' and stage.kinds or nil,
            -- A perimeter: an arrive stage that also demands this many
            -- pieces of field equipment physically deployed at the scene.
            deploy = tonumber(stage.deploy)
                and math.floor(Util.Clamp(tonumber(stage.deploy), 1, 8)) or nil
        }
    end

    local agencies = {}
    for _, agencyId in ipairs(type(raw.agencies) == 'table' and raw.agencies or {}) do
        if Util.IsSlug(agencyId) then agencies[#agencies + 1] = agencyId end
    end

    -- Joint operations: supporting agencies see the callout, may attach, and
    -- get the dispatch alert, while the case still belongs to the primary.
    local support = {}
    for _, agencyId in ipairs(type(raw.support) == 'table' and raw.support or {}) do
        if Util.IsSlug(agencyId) then support[#support + 1] = agencyId end
    end

    local suspect = type(raw.suspect) == 'table' and raw.suspect or {}
    return {
        id = raw.id,
        label = Util.Text(raw.label, 80, raw.id),
        description = Util.Text(raw.description, 400, ''),
        agencies = agencies,
        support = support,
        priority = math.floor(Util.Clamp(tonumber(raw.priority) or 2, 1, 3)),
        blip = type(raw.blip) == 'table' and raw.blip or { sprite = 480, color = 5 },
        locations = locations,
        stages = stages,
        suspect = {
            source = Util.Contains({ 'auto', 'npc', 'player' }, suspect.source) and suspect.source or 'auto',
            models = type(suspect.models) == 'table' and suspect.models or {}
        },
        witnesses = type(raw.witnesses) == 'table' and raw.witnesses or { count = 0 },
        evidence = type(raw.evidence) == 'table' and raw.evidence or { radius = 15.0 },
        incident = type(raw.incident) == 'table' and raw.incident or { type = 'Investigation', charges = {} }
    }
end

function Callouts.Templates()
    if templateCache then return templateCache end

    templateCache = {}
    for _, raw in ipairs((Config.Federal or {}).Callouts or {}) do
        local template, message = normalizeTemplate(raw)
        if template then
            templateCache[#templateCache + 1] = template
        else
            Bridge.Print('ignoring callout template %s: %s', tostring(raw and raw.id), tostring(message))
        end
    end
    return templateCache
end

function Callouts.TemplatesFor(agencyId)
    local list = {}
    for _, template in ipairs(Callouts.Templates()) do
        if #template.agencies == 0 or Util.Contains(template.agencies, agencyId) then
            list[#list + 1] = template
        end
    end
    return list
end

function Callouts.Invalidate()
    templateCache = nil
end

-- Suspect selection --------------------------------------------------------------

-- Prefers a real player carrying an active warrant. On-duty federal officers
-- are never selected: an investigation into the agent investigating it is not
-- the gameplay anyone asked for.
function Callouts.PlayerSuspect()
    if settings().playerSuspects == false then return nil end

    local candidates = {}
    for _, playerId in ipairs(GetPlayers()) do
        local playerSource = tonumber(playerId)
        if playerSource and not Core.Unit(playerSource) then
            local identifier = Bridge.GetIdentifier(playerSource)
            local warrant = identifier and CAD.ActiveWarrantFor(identifier)
            if warrant then
                candidates[#candidates + 1] = {
                    kind = 'player',
                    source = playerSource,
                    identifier = identifier,
                    name = Bridge.GetName(playerSource),
                    warrant = warrant.number
                }
            end
        end
    end

    if #candidates == 0 then return nil end
    return candidates[math.random(#candidates)]
end

local function npcSuspect(template)
    local models = template.suspect.models
    return {
        kind = 'npc',
        model = #models > 0 and models[math.random(#models)] or 'a_m_y_business_01',
        name = 'Unidentified subject'
    }
end

local function chooseSuspect(template)
    if template.suspect.source == 'npc' then return npcSuspect(template) end

    local player = Callouts.PlayerSuspect()
    if player then return player end
    -- A 'player' template with nobody warranted simply does not run.
    if template.suspect.source == 'player' then return nil end
    return npcSuspect(template)
end

-- Dispatch --------------------------------------------------------------------------

local function currentStage(callout)
    return callout.stages[callout.stage]
end

local function publicView(callout)
    return {
        id = callout.id,
        number = callout.number,
        agency = callout.agency,
        support = callout.support,
        template = callout.templateId,
        label = callout.label,
        description = callout.description,
        priority = callout.priority,
        blip = callout.blip,
        location = callout.location,
        status = callout.status,
        stage = callout.stage,
        stages = callout.stages,
        evidence = callout.evidence,
        witnesses = callout.witnesses,
        assigned = callout.assigned,
        host = callout.host,
        -- The suspect stays anonymous until a lead names them. Shipping the
        -- name with the dispatch would make every lead pointless.
        suspect = callout.suspect and {
            kind = callout.suspect.kind,
            identified = callout.identified == true,
            name = callout.identified and callout.suspect.name or 'Unidentified subject',
            model = callout.suspect.model,
            source = (callout.identified and callout.suspect.kind == 'player')
                and callout.suspect.source or nil
        } or nil,
        leads = callout.leads or {}
    }
end

Callouts.PublicView = publicView

-- Every agency working the case: the primary plus any supporting agencies.
local function calloutAgencies(callout)
    local list = { callout.agency }
    for _, agencyId in ipairs(callout.support or {}) do
        if agencyId ~= callout.agency then list[#list + 1] = agencyId end
    end
    return list
end

local function involves(callout, agencyId)
    return callout.agency == agencyId or Util.Contains(callout.support or {}, agencyId)
end

Callouts.Involves = involves

local function notify(callout, event, payload)
    for _, agencyId in ipairs(calloutAgencies(callout)) do
        for _, playerSource in ipairs(Core.OnDutySources(agencyId)) do
            TriggerClientEvent(Federal.Net(event), playerSource, payload)
        end
    end
end

function Callouts.CountFor(agencyId)
    local total = 0
    for _, callout in pairs(active) do
        if callout.agency == agencyId and callout.status ~= 'closed' then total = total + 1 end
    end
    return total
end

-- `templateId` and `locationIndex` are optional and exist so a dispatch can be
-- made deterministic, which is what the tests and the supervisor menu use.
function Callouts.Dispatch(agencyId, templateId, locationIndex)
    local agency = Core.Agency(agencyId)
    if not agency then return fail('no such agency') end
    if agency.callouts == false then return fail('that agency has callouts disabled') end

    local eligible = Callouts.TemplatesFor(agencyId)
    if #eligible == 0 then return fail('no callout templates apply to that agency') end

    local template
    if templateId then
        for _, candidate in ipairs(eligible) do
            if candidate.id == templateId then template = candidate end
        end
        if not template then return fail('that template does not apply to this agency') end
    else
        template = eligible[math.random(#eligible)]
    end

    local suspect = chooseSuspect(template)
    if not suspect then return fail('no eligible suspect for that template') end

    sequence = sequence + 1
    local number = Core.NextNumber(agencyId, 'callout')
    local index = locationIndex or math.random(#template.locations)
    local location = template.locations[math.min(math.max(index, 1), #template.locations)]

    local callout = {
        id = Util.RecordId('cal', sequence),
        number = number,
        agency = agencyId,
        support = Util.Copy(template.support or {}),
        templateId = template.id,
        label = template.label,
        description = template.description,
        priority = template.priority,
        blip = template.blip,
        location = location,
        status = 'dispatched',
        stage = 1,
        stages = Util.Copy(template.stages),
        evidence = template.evidence,
        witnesses = template.witnesses,
        incident = template.incident,
        -- What ambient witnesses near this scene say when interviewed.
        investigation = template.investigation,
        suspect = suspect,
        assigned = {},
        host = nil,
        flags = {},
        leads = {},
        identified = false,
        createdAt = os.time()
    }

    active[callout.id] = callout
    notify(callout, 'callout:dispatch', publicView(callout))

    -- Also through the dispatch layer, so a server running ps-dispatch or
    -- cd_dispatch gets the alert in the system its players already watch.
    -- Joint operations alert every involved agency.
    if Federal.Dispatch then
        for _, involvedId in ipairs(calloutAgencies(callout)) do
            Federal.Dispatch.Alert({
                id = callout.id,
                agency = involvedId,
                title = callout.label,
                message = callout.description,
                coords = callout.location,
                sprite = callout.blip and callout.blip.sprite or 480,
                colour = callout.blip and callout.blip.color or 5,
                priority = callout.priority,
                code = callout.number
            })
        end
    end

    return publicView(callout)
end

function Callouts.Get(calloutId)
    return active[calloutId]
end

function Callouts.Active(source)
    local membership = Core.Membership(source)
    if not membership then return {} end

    local list = {}
    for _, callout in pairs(active) do
        if involves(callout, membership.agency.id) and callout.status ~= 'closed' then
            list[#list + 1] = publicView(callout)
        end
    end
    table.sort(list, function(a, b) return (a.number or '') < (b.number or '') end)
    return list
end

-- The active callout of `agencyId` whose scene is nearest to `coords`, for
-- the investigation layer: interviews near a callout use ITS witness flow.
function Callouts.NearestScene(agencyId, coords, radius)
    if not coords then return nil end
    local best, bestDistance
    for _, callout in pairs(active) do
        if involves(callout, agencyId) and callout.status ~= 'closed' and type(callout.location) == 'table' then
            local distance = Util.Distance(coords, callout.location)
            if distance and distance <= (radius or 60.0) and (not bestDistance or distance < bestDistance) then
                best, bestDistance = callout, distance
            end
        end
    end
    return best
end

-- Formal witness statements taken at a callout scene before any incident is
-- filed: they ride the callout and land in the court file on completion.
function Callouts.AddStatement(calloutId, entry)
    local callout = active[calloutId]
    if not callout or type(entry) ~= 'table' then return false end
    callout.statements = callout.statements or {}
    if #callout.statements >= 12 then return false end
    callout.statements[#callout.statements + 1] = entry
    return true
end

local function isAssigned(callout, source)
    return Util.Contains(callout.assigned, source)
end

-- The number of the callout this unit is riding, for radio traffic
-- ("show me en route to FIB-CAD-0022").
function Callouts.AssignedNumber(source)
    for _, callout in pairs(active) do
        if callout.status ~= 'closed' and isAssigned(callout, source) then
            return callout.number
        end
    end
    return nil
end

Callouts.IsAssigned = isAssigned

-- The first officer to attach hosts the scene: their client owns the NPCs, so
-- exactly one machine spawns them.
function Callouts.Attach(source, calloutId)
    local membership = Core.Require(source, 'actions.detain')
    if not membership then return fail('not authorized') end

    local callout = active[calloutId]
    if not callout or callout.status == 'closed' then return fail('that callout is no longer active') end
    if not involves(callout, membership.agency.id) then return fail('that callout belongs to another agency') end
    if isAssigned(callout, source) then return fail('you are already assigned') end

    callout.assigned[#callout.assigned + 1] = source
    if not callout.host then
        callout.host = source
        callout.status = 'active'
    end

    Core.SetStatus(source, 'enroute')
    notify(callout, 'callout:update', publicView(callout))
    return publicView(callout)
end

function Callouts.Detach(source, calloutId)
    local callout = active[calloutId]
    if not callout then return fail('that callout is no longer active') end

    for index, assigned in ipairs(callout.assigned) do
        if assigned == source then table.remove(callout.assigned, index) break end
    end

    -- Hosting passes to whoever is left, so the scene does not go unowned.
    if callout.host == source then callout.host = callout.assigned[1] end
    notify(callout, 'callout:update', publicView(callout))
    return publicView(callout)
end

-- Stage progress -----------------------------------------------------------------------

local function atScene(source, callout, radius)
    local position = Core.Coords(source)
    if not position then return false end
    local distance = Util.Distance(position, callout.location)
    return distance ~= nil and distance <= (radius or 60.0)
end

Callouts.AtScene = atScene

-- Each objective kind decides for itself what counts as done. Kinds backed by
-- a server-side fact (evidence filed, suspect arrested) check that fact rather
-- than believing the client's report.
local validators = {}

validators.arrive = function(source, callout, stage)
    if not atScene(source, callout, stage.radius) then return false, 'you are not at the scene yet' end

    -- A perimeter stage: the cordon has to physically exist. Deployed field
    -- equipment (cones, barriers - the Field equipment menu) near the scene
    -- is what counts, whoever put it out.
    if stage.deploy then
        local nearby = 0
        for _, record in pairs((Federal.Equipment and Federal.Equipment.deployed) or {}) do
            if record.agency == callout.agency and record.netId then
                local entity = NetworkGetEntityFromNetworkId(record.netId)
                if entity and entity ~= 0 and DoesEntityExist(entity) then
                    local at = GetEntityCoords(entity)
                    local distance = Util.Distance({ x = at.x, y = at.y, z = at.z }, callout.location)
                    if distance and distance <= (stage.radius or 25.0) + 20.0 then
                        nearby = nearby + 1
                    end
                end
            end
        end
        if nearby < stage.deploy then
            return false, ('set the perimeter: deploy %d more cone(s) or barrier(s) at the scene (Field equipment menu)')
                :format(stage.deploy - nearby)
        end
    end

    return true
end

validators.interview = function(source, callout, stage)
    if not atScene(source, callout, stage.radius) then return false, 'you are not at the scene' end
    callout.flags.interviewed = (callout.flags.interviewed or 0) + 1
    if callout.flags.interviewed < (stage.count or 1) then
        return false, 'there is still someone to interview'
    end
    return true
end

validators.evidence = function(_, callout, stage)
    -- Counted from the evidence actually filed against this callout, so the
    -- stage cannot be completed by reporting it.
    local collected = 0
    for _, record in pairs(CAD.evidence.all()) do
        if record.calloutId == callout.id then collected = collected + 1 end
    end
    if collected < (stage.count or 1) then
        return false, ('%d of %d items collected'):format(collected, stage.count or 1)
    end
    return true
end

validators.search = function(_, callout)
    if not callout.flags.searched then return false, 'the suspect has not been searched' end
    return true
end

validators.arrest = function(source, callout, stage)
    if callout.suspect and callout.suspect.kind == 'player' then
        -- A real suspect is only detained when the arrest actually happened.
        if not callout.flags.arrested then return false, 'the suspect has not been detained' end
        return true
    end
    -- The NPC suspect exists only on the host's client, so the check that can
    -- be made server-side is that the reporting officer is at the scene.
    if not atScene(source, callout, stage.radius) then return false, 'you are not at the scene' end
    callout.flags.arrested = true
    return true
end

-- Requires the officers to have actually followed leads, which is what makes
-- analysing evidence at the lab worth the trip.
validators.investigate = function(_, callout, stage)
    local worked = Callouts.LeadCount(callout)
    if worked < (stage.count or 1) then
        return false, ('%d of %d leads followed'):format(worked, stage.count or 1)
    end
    return true
end

-- The suspect has to be identified before they can be detained by name. An
-- unidentified subject can still be arrested at the scene; this gate is for
-- templates that want the investigation done first.
validators.identify = function(_, callout)
    if not callout.identified then return false, 'the subject has not been identified yet' end
    return true
end

validators.report = function()
    return true
end

function Callouts.Progress(source, calloutId, stageId)
    local membership = Core.Membership(source)
    if not membership then return fail('not authorized') end

    local callout = active[calloutId]
    if not callout or callout.status == 'closed' then return fail('that callout is no longer active') end
    if not isAssigned(callout, source) then return fail('you are not assigned to that callout') end

    local stage = currentStage(callout)
    if not stage then return fail('that callout has no remaining stages') end
    -- Stages are worked in order; naming a later one does not skip ahead.
    if stageId and stage.id ~= stageId then return fail('that is not the current objective') end

    local validator = validators[stage.kind]
    if not validator then return fail('that objective cannot be completed') end

    local done, message = validator(source, callout, stage)
    if not done then return fail(message or 'that objective is not finished') end

    callout.stage = callout.stage + 1
    Core.SetStatus(source, 'onscene')

    if callout.stage > #callout.stages then
        return Callouts.Complete(source, callout.id)
    end

    notify(callout, 'callout:update', publicView(callout))
    return publicView(callout)
end

-- Applies what a lead unlocks. This is the join between evidence and the
-- shape of the case: a name identifies the suspect, an address puts a second
-- search location on the map, a contact brings a witness to the scene.
function Callouts.Reveal(callout, lead)
    if type(callout) ~= 'table' or type(lead) ~= 'table' then return nil end

    callout.leads = callout.leads or {}
    for _, existing in ipairs(callout.leads) do
        if existing.id == lead.id then return callout end
    end

    local entry = {
        id = lead.id,
        number = lead.number,
        kind = lead.kind,
        summary = lead.summary,
        plate = lead.plate,
        location = lead.location,
        name = lead.name
    }
    callout.leads[#callout.leads + 1] = entry

    if lead.kind == 'name' or lead.kind == 'plate' then
        callout.identified = true

        -- An NPC suspect has no identity of its own. The lead that named
        -- somebody is what gives it one: a print at the scene matched Sam
        -- Cole, so Sam Cole is who the officers are now looking for. Without
        -- this, identifying an NPC reveals the words "Unidentified subject".
        if lead.name and callout.suspect and callout.suspect.kind == 'npc' then
            callout.suspect.name = lead.name
            callout.suspect.identifier = lead.subject or callout.suspect.identifier
        end
    end
    if lead.kind == 'contact' then
        callout.flags.extraWitness = true
    end
    if lead.kind == 'ledger' then
        callout.flags.documented = true
    end

    notify(callout, 'callout:update', publicView(callout))
    return callout
end

-- How many leads have been worked on this case. Used by the optional
-- investigation stage below.
function Callouts.LeadCount(callout)
    return #(callout.leads or {})
end

-- Hooks called by the actions module so a real arrest or search advances the
-- investigation without the client having to claim it did.
function Callouts.OnArrest(identifier)
    for _, callout in pairs(active) do
        if callout.status ~= 'closed' and callout.suspect and callout.suspect.identifier == identifier then
            callout.flags.arrested = true
            notify(callout, 'callout:update', publicView(callout))
        end
    end
end

function Callouts.OnSearch(source, identifier)
    for _, callout in pairs(active) do
        if callout.status ~= 'closed' and isAssigned(callout, source) then
            if not callout.suspect or callout.suspect.kind ~= 'player' or callout.suspect.identifier == identifier then
                callout.flags.searched = true
            end
        end
    end
end

-- Closing ------------------------------------------------------------------------------

-- Closing files a real incident. The case the officers worked becomes a CAD
-- record carrying the evidence numbers, which is the point of the whole loop.
function Callouts.Complete(source, calloutId)
    local callout = active[calloutId]
    if not callout then return fail('that callout is no longer active') end

    local membership = Core.Membership(source)
    if not membership then return fail('not authorized') end

    local incident = CAD.FileIncident(source, {
        title = callout.label,
        type = callout.incident and callout.incident.type or 'Investigation',
        charges = callout.incident and callout.incident.charges or {},
        narrative = ('Closed from callout %s.'):format(callout.number),
        location = callout.location,
        calloutId = callout.id
    })

    if incident then
        for _, record in pairs(CAD.evidence.all()) do
            if record.calloutId == callout.id then CAD.AttachEvidence(source, record.id, incident.id) end
        end
        if callout.suspect and callout.suspect.identifier then
            CAD.AttachSuspect(source, incident.id, {
                identifier = callout.suspect.identifier,
                name = callout.suspect.name,
                charges = callout.incident and callout.incident.charges or {}
            })
        end
        -- Re-read: `incident` above is the copy taken at creation, before the
        -- evidence and suspect were attached to it.
        incident = CAD.incidents.get(incident.id) or incident
    end

    -- An encountered NPC becomes a person on file: identified or arrested
    -- suspects get a citizen record under their synthetic identity, so the
    -- Records tab finds them later like anyone else the agency has met.
    if callout.suspect and callout.suspect.kind == 'npc'
        and (callout.identified or callout.flags.arrested) then
        CAD.Note(('npc:%s'):format(callout.id),
            callout.suspect.name or 'Unidentified subject',
            ('Encountered during %s (%s)%s'):format(callout.label, callout.number,
                callout.flags.arrested and ' - arrested at the scene' or ' - identified, not apprehended'))
    end

    -- An arrested NPC suspect goes all the way: the case is filed with the
    -- court under a synthetic identity, the NPC judge and jury run it (the
    -- defendant never appears, exactly like a no-show player), and a
    -- conviction lands them in custody and on the record.
    if incident and callout.flags.arrested
        and callout.suspect and callout.suspect.kind == 'npc'
        and Federal.Court and Federal.Court.Enabled()
        and #(callout.incident and callout.incident.charges or {}) > 0 then
        local defendant = callout.identified and callout.suspect.name or nil
        local case = Federal.Court.File(source, {
            identifier = ('npc:%s'):format(callout.id),
            name = defendant or callout.suspect.name or 'John Doe',
            charges = callout.incident.charges,
            incidentId = incident.id
        })
        if case then
            Bridge.Notify(source, ('Case %s filed against the suspect.'):format(case.number), 'inform')
        end
    end

    local reward = settings().reward or {}
    local amount = tonumber(reward.amount) or 0
    if amount > 0 then
        for _, assigned in ipairs(callout.assigned) do
            Bridge.AddMoney(assigned, reward.account or 'bank', amount, 'federal-callout')
            Core.SetStatus(assigned, 'available')
        end
    end

    callout.status = 'closed'
    callout.incidentId = incident and incident.id or nil
    notify(callout, 'callout:closed', publicView(callout))
    active[callout.id] = nil

    return { callout = publicView(callout), incident = incident }
end

function Callouts.Cancel(source, calloutId)
    if not Core.Can(source, 'callout.manage') then return fail('not authorized') end

    local callout = active[calloutId]
    if not callout then return fail('that callout is no longer active') end

    callout.status = 'closed'
    notify(callout, 'callout:closed', publicView(callout))
    active[calloutId] = nil
    return publicView(callout)
end

function Callouts.Expire(nowSeconds)
    local limit = math.floor((tonumber(settings().expire) or 1800000) / 1000)
    local removed = 0
    for id, callout in pairs(active) do
        if (nowSeconds - (callout.createdAt or 0)) > limit then
            callout.status = 'closed'
            notify(callout, 'callout:closed', publicView(callout))
            active[id] = nil
            removed = removed + 1
        end
    end
    return removed
end

-- Players online who do NOT work for the agency: the population the
-- director's civilianLimit gate counts. When the city is busy with real
-- players, automatic NPC work stands down and lets real roleplay happen.
function Callouts.CivilianCount(agency)
    local count = 0
    for _, playerId in ipairs(GetPlayers()) do
        local playerSource = tonumber(playerId)
        if playerSource then
            local job = Bridge.GetJob(playerSource)
            if not job or not Util.Contains(agency.jobs or {}, job.name) then
                count = count + 1
            end
        end
    end
    return count
end

-- Whether AUTOMATIC dispatch is allowed for this agency right now, per the
-- director's configuration. Forced callouts never come through here.
local function autoAllowed(agency)
    local gate = agency.npcCallouts or {}
    if gate.enabled == false then return false end
    local limit = tonumber(gate.civilianLimit) or 0
    if limit > 0 and Callouts.CivilianCount(agency) >= limit then return false end
    return true
end

-- One consideration pass: for every agency with enough officers on duty and
-- room for another case, roll the configured chance.
-- How many callouts may run at once for an agency: the director's per-agency
-- cap (or the global one), never more than the street can actually work -
-- one officer alone is never handed three scenes at a time.
function Callouts.ActiveCap(agency, onDuty)
    local gate = agency.npcCallouts or {}
    local cap = tonumber(gate.maxActive) or 0
    if cap <= 0 then cap = tonumber(settings().maxActive) or 3 end
    local perOfficer = tonumber(settings().perOfficer) or 1
    return math.min(cap, math.max(1, onDuty * perOfficer))
end

function Callouts.Tick()
    if settings().enabled == false then return 0 end

    local dispatched = 0
    local minUnits = tonumber(settings().minUnits) or 1
    local chance = tonumber(settings().chance) or 0.5

    for _, agency in ipairs(Core.Agencies()) do
        local onDuty = #Core.OnDutySources(agency.id)
        if agency.callouts ~= false and autoAllowed(agency)
            and onDuty >= minUnits and Callouts.CountFor(agency.id) < Callouts.ActiveCap(agency, onDuty) then
            if math.random() <= chance and Callouts.Dispatch(agency.id) then
                dispatched = dispatched + 1
            end
        end
    end
    return dispatched
end

-- A member pulling their own work: bypasses the civilian gate and the dice,
-- keeps the concurrency cap, and is rate limited per player so "force" never
-- becomes "spam".
local forceCooldowns = {}

function Callouts.Force(source, templateId)
    local membership = Core.Require(source, 'actions.detain')
    if not membership then return fail('not authorized') end
    if membership.agency.callouts == false then return fail('your agency has callouts disabled') end

    local maxActive = tonumber(settings().maxActive) or 3
    if Callouts.CountFor(membership.agency.id) >= maxActive then
        return fail('your agency already has its maximum active callouts')
    end

    local nowSeconds = os.time()
    local last = forceCooldowns[membership.identifier]
    if last and (nowSeconds - last) < 300 then
        return fail(('wait %d more second(s) before requesting another callout'):format(300 - (nowSeconds - last)))
    end

    local callout, message = Callouts.Dispatch(membership.agency.id, templateId)
    if not callout then return fail(message) end

    forceCooldowns[membership.identifier] = nowSeconds
    return callout
end

-- Net wiring --------------------------------------------------------------------------

Bridge.RegisterCallback(Federal.Net('callouts'), function(source, reply)
    reply(Callouts.Active(source))
end)

-- What a member may force: their agency's templates, for the request menu.
Bridge.RegisterCallback(Federal.Net('callout:templates'), function(source, reply)
    local membership = Core.Membership(source)
    if not membership then return reply({}) end
    local list = {}
    for _, template in ipairs(Callouts.TemplatesFor(membership.agency.id)) do
        list[#list + 1] = {
            id = template.id,
            label = template.label,
            description = template.description,
            priority = template.priority
        }
    end
    reply(list)
end)

Bridge.RegisterCallback(Federal.Net('callout:force'), function(source, reply, templateId)
    local callout, message = Callouts.Force(source, type(templateId) == 'string' and templateId or nil)
    if not callout then Bridge.Notify(source, message, 'error') end
    reply(callout, message)
end)

Bridge.RegisterCallback(Federal.Net('callout:attach'), function(source, reply, calloutId)
    local result, message = Callouts.Attach(source, calloutId)
    reply(result, message)
end)

Bridge.RegisterCallback(Federal.Net('callout:progress'), function(source, reply, calloutId, stageId)
    local result, message = Callouts.Progress(source, calloutId, stageId)
    if not result then Bridge.Notify(source, message, 'error') end
    reply(result, message)
end)

RegisterNetEvent(Federal.Net('callout:detach'), function(calloutId)
    local playerSource = source
    if type(calloutId) ~= 'string' then return end
    Callouts.Detach(playerSource, calloutId)
end)

RegisterNetEvent(Federal.Net('callout:cancel'), function(calloutId)
    local playerSource = source
    if type(calloutId) ~= 'string' then return end
    local result, message = Callouts.Cancel(playerSource, calloutId)
    if not result then Bridge.Notify(playerSource, message, 'error') end
end)

AddEventHandler('playerDropped', function()
    local dropped = source
    for _, callout in pairs(active) do
        if isAssigned(callout, dropped) then Callouts.Detach(dropped, callout.id) end
    end
end)

CreateThread(function()
    math.randomseed(os.time())
    while true do
        Wait(math.max(tonumber(settings().interval) or 90000, 15000))
        if Core.Enabled() then
            Callouts.Expire(os.time())
            Callouts.Tick()
        end
    end
end)

return Callouts
