local function loadCallouts()
    return harness.loadFederalServer({
        federal = { 'core', 'cad', 'uniforms', 'armory', 'actions', 'leads', 'callouts' }
    })
end

local function zoneCoords(agencyId, zoneId)
    local agency = DAG.Federal.Core.Agency(agencyId)
    local zone = DAG.Federal.Schema.FindById(agency.stations[1].zones, zoneId)
    return vector3(zone.coords.x, zone.coords.y, zone.coords.z)
end

local function officer(playerSource, agencyId, grade)
    harness.identifiers[playerSource] = 'license:' .. tostring(playerSource)
    harness.names[playerSource] = 'Agent ' .. playerSource
    harness.setJob(playerSource, agencyId or 'fib', grade or 2)
    harness.placePlayer(playerSource, zoneCoords(agencyId or 'fib', 'duty'))
    DAG.Federal.Core.SetDuty(playerSource, true)
end

local function civilian(playerSource, name)
    harness.identifiers[playerSource] = 'license:civ' .. tostring(playerSource)
    harness.names[playerSource] = name or ('Civilian ' .. playerSource)
    harness.setJob(playerSource, 'unemployed', 0)
    harness.placePlayer(playerSource, vector3(2000.0, 2000.0, 20.0))
end

-- Sends a player to the scene of a callout.
local function goToScene(playerSource, callout)
    harness.placePlayer(playerSource, vector3(callout.location.x, callout.location.y, callout.location.z))
end

test('every configured callout template is valid', function()
    loadCallouts()
    assertEq(#DAG.Federal.Callouts.Templates(), 7)
    assertFalse(harness.outputContains('ignoring callout template'))
end)

-- A template with an unknown objective kind has no validator, so an officer
-- who attached to it could never finish it.
test('a template with an unknown objective kind is rejected, not dispatched', function()
    loadCallouts()
    Config.Federal.Callouts = {
        {
            id = 'broken', label = 'Broken', agencies = { 'fib' },
            locations = { { x = 1.0, y = 2.0, z = 3.0 } },
            stages = { { id = 'x', kind = 'teleport', label = 'Impossible' } }
        }
    }
    DAG.Federal.Callouts.Invalidate()

    assertEq(#DAG.Federal.Callouts.Templates(), 0)
    assertTrue(harness.outputContains('unknown objective kind'))
end)

test('templates are filtered to the agencies they name', function()
    loadCallouts()
    local fib = {}
    for _, template in ipairs(DAG.Federal.Callouts.TemplatesFor('fib')) do fib[template.id] = true end
    assertTrue(fib['wire-fraud'])
    assertTrue(fib['stolen-federal-property'], 'a multi-agency template applies')

    local usss = {}
    for _, template in ipairs(DAG.Federal.Callouts.TemplatesFor('usss')) do usss[template.id] = true end
    assertNil(usss['wire-fraud'], 'a FIB-only template does not reach the USSS')
    assertTrue(usss['counterfeit-passing'])
end)

test('a dispatch numbers the callout and notifies on-duty units only', function()
    loadCallouts()
    officer(1, 'fib', 2)
    officer(2, 'fib', 2)
    DAG.Federal.Core.SetDuty(2, false)
    harness.clientEvents = {}

    local callout = DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)
    assertEq(callout.number, 'FIB-CAD-0001')
    assertEq(callout.status, 'dispatched')

    local targets = {}
    for _, event in ipairs(harness.clientEvents) do
        if event.event:find('callout:dispatch', 1, true) then targets[event.target] = true end
    end
    assertTrue(targets[1], 'the on-duty agent was dispatched to')
    assertNil(targets[2], 'the off-duty agent was not')
end)

test('the first officer to attach hosts the scene and hosting passes on detach', function()
    loadCallouts()
    officer(1, 'fib', 2)
    officer(2, 'fib', 2)
    local callout = DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)

    assertEq(DAG.Federal.Callouts.Attach(1, callout.id).host, 1)
    assertEq(DAG.Federal.Callouts.Attach(2, callout.id).host, 1, 'the second officer does not take over')

    local _, message = DAG.Federal.Callouts.Attach(1, callout.id)
    assertEq(message, 'you are already assigned')

    assertEq(DAG.Federal.Callouts.Detach(1, callout.id).host, 2, 'hosting passes to whoever is left')
end)

test('a callout cannot be worked by another agency', function()
    loadCallouts()
    officer(1, 'fib', 2)
    officer(2, 'iaa', 2)
    local callout = DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)

    local _, message = DAG.Federal.Callouts.Attach(2, callout.id)
    assertEq(message, 'that callout belongs to another agency')
end)

test('progress requires being assigned', function()
    loadCallouts()
    officer(1, 'fib', 2)
    officer(2, 'fib', 2)
    local callout = DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)
    DAG.Federal.Callouts.Attach(1, callout.id)

    local _, message = DAG.Federal.Callouts.Progress(2, callout.id, 'arrive')
    assertEq(message, 'you are not assigned to that callout')
end)

test('the arrive stage checks the position the server reads', function()
    loadCallouts()
    officer(1, 'fib', 2)
    local callout = DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)
    DAG.Federal.Callouts.Attach(1, callout.id)

    local _, message = DAG.Federal.Callouts.Progress(1, callout.id, 'arrive')
    assertEq(message, 'you are not at the scene yet')

    goToScene(1, callout)
    assertEq(DAG.Federal.Callouts.Progress(1, callout.id, 'arrive').stage, 2)
end)

-- Stages are worked in order. Naming a later objective must not skip ahead.
test('a later objective cannot be claimed out of order', function()
    loadCallouts()
    officer(1, 'fib', 2)
    local callout = DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)
    DAG.Federal.Callouts.Attach(1, callout.id)
    goToScene(1, callout)

    local _, message = DAG.Federal.Callouts.Progress(1, callout.id, 'arrest')
    assertEq(message, 'that is not the current objective')
    assertEq(DAG.Federal.Callouts.Get(callout.id).stage, 1, 'still on the first objective')
end)

-- The evidence stage counts what was actually filed, so reporting it is not
-- enough to close it.
test('the evidence stage counts filed evidence, not client claims', function()
    loadCallouts()
    officer(1, 'fib', 2)
    local callout = DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)
    DAG.Federal.Callouts.Attach(1, callout.id)
    goToScene(1, callout)
    DAG.Federal.Callouts.Progress(1, callout.id, 'arrive')
    DAG.Federal.Callouts.Progress(1, callout.id, 'interview')

    local _, message = DAG.Federal.Callouts.Progress(1, callout.id, 'evidence')
    assertEq(message, '0 of 2 items collected')

    DAG.Federal.CAD.CollectEvidence(1, { kind = 'document', calloutId = callout.id })
    local _, partial = DAG.Federal.Callouts.Progress(1, callout.id, 'evidence')
    assertEq(partial, '1 of 2 items collected')

    DAG.Federal.CAD.CollectEvidence(1, { kind = 'print', calloutId = callout.id })
    assertEq(DAG.Federal.Callouts.Progress(1, callout.id, 'evidence').stage, 4)
end)

-- A warranted player becoming the suspect is what stops player-written
-- warrants from being a dead end.
test('a player carrying an active warrant becomes the suspect', function()
    loadCallouts()
    officer(1, 'fib', 2)
    civilian(2, 'Sam Cole')
    DAG.Federal.CAD.IssueWarrant(1, { identifier = 'license:civ2', name = 'Sam Cole', reason = 'Wire fraud' })

    local callout = DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)
    assertEq(callout.suspect.kind, 'player')

    -- The dispatch does not name them: shipping the suspect's identity with
    -- the callout would make every lead pointless.
    assertEq(callout.suspect.name, 'Unidentified subject')
    assertFalse(callout.suspect.identified)
    assertNil(callout.suspect.source)

    -- The server knows who it is; the officers have to work it out.
    assertEq(DAG.Federal.Callouts.Get(callout.id).suspect.name, 'Sam Cole')
end)

test('an on-duty officer is never selected as the suspect', function()
    loadCallouts()
    officer(1, 'fib', 2)
    officer(2, 'fib', 1)
    -- Even carrying a warrant, an officer on the roster is not investigated.
    DAG.Federal.CAD.IssueWarrant(1, { identifier = 'license:2', name = 'Agent 2', reason = 'Internal' })

    local callout = DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)
    assertEq(callout.suspect.kind, 'npc')
end)

test('with nobody warranted the suspect falls back to an NPC', function()
    loadCallouts()
    officer(1, 'fib', 2)
    civilian(2)

    local callout = DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)
    assertEq(callout.suspect.kind, 'npc')
    assertTrue(type(callout.suspect.model) == 'string')
end)

test('a player-only template does not dispatch when nobody is warranted', function()
    loadCallouts()
    officer(1, 'fib', 2)
    Config.Federal.Callouts = {
        {
            id = 'player-only', label = 'Player only', agencies = { 'fib' },
            suspect = { source = 'player' },
            locations = { { x = 1.0, y = 2.0, z = 3.0 } },
            stages = { { id = 'arrive', kind = 'arrive', label = 'Arrive' } }
        }
    }
    DAG.Federal.Callouts.Invalidate()

    local _, message = DAG.Federal.Callouts.Dispatch('fib', 'player-only', 1)
    assertEq(message, 'no eligible suspect for that template')
end)

-- Walks a wire-fraud case the whole way: scene, witness, evidence, the lab,
-- the lead it produced, the identification that lead gave, then the arrest.
local function workToArrest(callout)
    goToScene(1, callout)
    DAG.Federal.Callouts.Progress(1, callout.id, 'arrive')
    DAG.Federal.Callouts.Progress(1, callout.id, 'interview')

    -- A print lifted from the suspect, and a document from the scene.
    local print_ = DAG.Federal.CAD.CollectEvidence(1, {
        kind = 'print', calloutId = callout.id, subject = 'license:civ2'
    })
    DAG.Federal.CAD.CollectEvidence(1, { kind = 'document', calloutId = callout.id })
    DAG.Federal.Callouts.Progress(1, callout.id, 'evidence')

    -- The lab is a place; the lead only exists once the print is run.
    harness.placePlayer(1, zoneCoords('fib', 'evidence'))
    local analysed = DAG.Federal.CAD.AnalyseEvidence(1, print_.id)
    goToScene(1, callout)
    return analysed
end

test('an unanalysed case cannot reach the arrest stage', function()
    loadCallouts()
    officer(1, 'fib', 2)
    civilian(2, 'Sam Cole')
    DAG.Federal.CAD.Record('license:civ2', 'Sam Cole')

    local callout = DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)
    DAG.Federal.Callouts.Attach(1, callout.id)
    goToScene(1, callout)
    DAG.Federal.Callouts.Progress(1, callout.id, 'arrive')
    DAG.Federal.Callouts.Progress(1, callout.id, 'interview')
    DAG.Federal.CAD.CollectEvidence(1, { kind = 'document', calloutId = callout.id })
    DAG.Federal.CAD.CollectEvidence(1, { kind = 'print', calloutId = callout.id })
    DAG.Federal.Callouts.Progress(1, callout.id, 'evidence')

    local _, message = DAG.Federal.Callouts.Progress(1, callout.id, 'investigate')
    assertEq(message, '0 of 1 leads followed', 'the evidence has not been run yet')
end)

-- The arrest stage for a real suspect must close on the arrest that happened.
test('arresting the real suspect advances the arrest stage', function()
    loadCallouts()
    officer(1, 'fib', 2)
    civilian(2, 'Sam Cole')
    DAG.Federal.CAD.Record('license:civ2', 'Sam Cole')
    DAG.Federal.CAD.IssueWarrant(1, { identifier = 'license:civ2', name = 'Sam Cole', reason = 'Wire fraud' })

    local callout = DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)
    DAG.Federal.Callouts.Attach(1, callout.id)

    local analysed = workToArrest(callout)
    local lead = DAG.Federal.Leads.Get(analysed.lead)
    assertEq(lead.kind, 'name', 'a matched print names the subject')

    DAG.Federal.Leads.Follow(1, lead.id)
    DAG.Federal.Callouts.Progress(1, callout.id, 'investigate')
    DAG.Federal.Callouts.Progress(1, callout.id, 'identify')

    local _, message = DAG.Federal.Callouts.Progress(1, callout.id, 'arrest')
    assertEq(message, 'the suspect has not been detained')

    -- Actually arrest them.
    goToScene(2, callout)
    DAG.Federal.Actions.Cuff(1, 2)
    DAG.Federal.Actions.Arrest(1, 2, {})
    assertTrue(DAG.Federal.Callouts.Get(callout.id).flags.arrested)
    assertEq(DAG.Federal.Callouts.Progress(1, callout.id, 'arrest').stage, 7)
end)

-- Closing a callout has to leave a real case behind, or the whole loop is
-- busywork.
test('closing a callout files an incident carrying its evidence and suspect', function()
    loadCallouts()
    officer(1, 'fib', 2)
    civilian(2, 'Sam Cole')
    DAG.Federal.CAD.IssueWarrant(1, { identifier = 'license:civ2', name = 'Sam Cole', reason = 'Wire fraud' })
    DAG.Framework.AddMoney(1, 'bank', 0, 'seed')

    DAG.Federal.CAD.Record('license:civ2', 'Sam Cole')
    local callout = DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)
    DAG.Federal.Callouts.Attach(1, callout.id)

    local analysed = workToArrest(callout)
    DAG.Federal.Leads.Follow(1, DAG.Federal.Leads.Get(analysed.lead).id)
    DAG.Federal.Callouts.Progress(1, callout.id, 'investigate')
    DAG.Federal.Callouts.Progress(1, callout.id, 'identify')

    goToScene(2, callout)
    DAG.Federal.Actions.Cuff(1, 2)
    DAG.Federal.Actions.Arrest(1, 2, {})
    DAG.Federal.Callouts.Progress(1, callout.id, 'arrest')

    local result = DAG.Federal.Callouts.Progress(1, callout.id, 'report')
    assertEq(result.incident.title, 'Suspected wire fraud')
    assertEq(result.incident.type, 'Financial crime')
    assertEq(result.incident.suspects[1].name, 'Sam Cole')

    local attached = DAG.Federal.CAD.EvidenceFor(1, result.incident.id)
    assertEq(#attached, 2, 'the collected evidence came with it')

    assertNil(DAG.Federal.Callouts.Get(callout.id), 'the callout is cleared')
    assertEq(DAG.Framework.GetMoney(1, 'bank'), 750, 'the assigned officer was paid')
end)

test('cancelling a callout needs callout.manage', function()
    loadCallouts()
    officer(1, 'fib', 2)
    local callout = DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)

    local _, message = DAG.Federal.Callouts.Cancel(1, callout.id)
    assertEq(message, 'not authorized')

    officer(1, 'fib', 3)
    assertEq(DAG.Federal.Callouts.Cancel(1, callout.id).id, callout.id)
    assertNil(DAG.Federal.Callouts.Get(callout.id))
end)

test('unattended callouts expire', function()
    loadCallouts()
    officer(1, 'fib', 2)
    local callout = DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)

    assertEq(DAG.Federal.Callouts.Expire(os.time()), 0, 'a fresh callout stays')
    assertEq(DAG.Federal.Callouts.Expire(os.time() + 3600), 1)
    assertNil(DAG.Federal.Callouts.Get(callout.id))
end)

test('the engine will not exceed maxActive per agency', function()
    loadCallouts()
    officer(1, 'fib', 2)
    Config.Federal.callouts.chance = 1.0
    Config.Federal.callouts.maxActive = 2

    for _ = 1, 6 do DAG.Federal.Callouts.Tick() end
    assertEq(DAG.Federal.Callouts.CountFor('fib'), 2)
end)

test('no callouts are dispatched to an agency with nobody on duty', function()
    loadCallouts()
    officer(1, 'fib', 2)
    Config.Federal.callouts.chance = 1.0

    DAG.Federal.Callouts.Tick()
    assertEq(DAG.Federal.Callouts.CountFor('fib'), 1)
    assertEq(DAG.Federal.Callouts.CountFor('iaa'), 0, 'the IAA has nobody on duty')
end)

test('an agency with callouts disabled is skipped', function()
    loadCallouts()
    officer(1, 'fib', 2)
    harness.aceAllowed[1] = { ['federal.admin'] = true }

    local agency = DAG.Federal.Core.Agency('fib')
    agency.callouts = false
    DAG.Federal.Uniforms.PersistAgency(agency)

    local _, message = DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)
    assertEq(message, 'that agency has callouts disabled')
end)

test('a dropped officer is detached from the callouts they were on', function()
    loadCallouts()
    officer(1, 'fib', 2)
    officer(2, 'fib', 2)
    local callout = DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)
    DAG.Federal.Callouts.Attach(1, callout.id)
    DAG.Federal.Callouts.Attach(2, callout.id)

    _G.source = 1
    TriggerEvent('playerDropped')
    _G.source = nil

    local remaining = DAG.Federal.Callouts.Get(callout.id)
    assertEq(#remaining.assigned, 1)
    assertEq(remaining.host, 2)
end)
