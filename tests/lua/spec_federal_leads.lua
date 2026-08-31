-- Investigation leads: what analysing evidence actually tells you, and how
-- that changes the case. Before leads existed, analysis wrote a string and the
-- callout ran the same stages regardless of what was found.
local function loadLeads()
    return harness.loadFederalServer({
        federal = { 'core', 'cad', 'uniforms', 'armory', 'actions', 'leads', 'callouts' }
    })
end

local function zoneCoords(agencyId, zoneId)
    local agency = DAG.Federal.Core.Agency(agencyId)
    local zone = DAG.Federal.Schema.FindById(agency.stations[1].zones, zoneId)
    return vector3(zone.coords.x, zone.coords.y, zone.coords.z)
end

local function officer(playerSource, grade)
    harness.identifiers[playerSource] = 'license:' .. tostring(playerSource)
    harness.names[playerSource] = 'Agent ' .. playerSource
    harness.setJob(playerSource, 'fib', grade or 2)
    harness.placePlayer(playerSource, zoneCoords('fib', 'duty'))
    DAG.Federal.Core.SetDuty(playerSource, true)
end

local function atLab(playerSource)
    harness.placePlayer(playerSource, zoneCoords('fib', 'evidence'))
end

-- Collects an item against a callout and runs it at the lab.
local function analyse(calloutId, kind, subject)
    local item = DAG.Federal.CAD.CollectEvidence(1, { kind = kind, calloutId = calloutId, subject = subject })
    atLab(1)
    return DAG.Federal.CAD.AnalyseEvidence(1, item.id)
end

local function dispatch()
    return DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)
end

test('analysing a matched print produces a lead that names the subject', function()
    loadLeads()
    officer(1)
    DAG.Federal.CAD.Record('license:sam', 'Sam Cole')
    local callout = dispatch()

    local analysed = analyse(callout.id, 'print', 'license:sam')
    local lead = DAG.Federal.Leads.Get(analysed.lead)

    assertEq(lead.kind, 'name')
    assertEq(lead.name, 'Sam Cole')
    assertEq(lead.status, 'open')
    assertEq(lead.number, 'FIB-LED-0001')
end)

-- Rolling for the lead kind when the item already matched would throw the
-- result away.
test('a matched item always names, whatever the kind could otherwise yield', function()
    loadLeads()
    officer(1)
    DAG.Federal.CAD.Record('license:sam', 'Sam Cole')
    local callout = dispatch()

    harness.fixRandom(0.99)
    local analysed = analyse(callout.id, 'dna', 'license:sam')
    assertEq(DAG.Federal.Leads.Get(analysed.lead).kind, 'name')
end)

test('a document yields a workable lead of its own kinds', function()
    loadLeads()
    officer(1)
    local callout = dispatch()
    harness.fixRandom(0.5)

    local analysed = analyse(callout.id, 'document')
    local lead = DAG.Federal.Leads.Get(analysed.lead)
    assertTrue(lead.kind == 'plate' or lead.kind == 'address' or lead.kind == 'ledger')
    assertTrue(type(lead.summary) == 'string' and lead.summary ~= '')
end)

-- Some evidence is worth having in court without moving the investigation on.
test('an item whose kind yields nothing produces no lead', function()
    loadLeads()
    officer(1)
    local callout = dispatch()

    local item = DAG.Federal.CAD.CollectEvidence(1, { kind = 'weapon', calloutId = callout.id })
    atLab(1)
    -- Weapons are not analysable at all, so there is nothing to yield from.
    local _, message = DAG.Federal.CAD.AnalyseEvidence(1, item.id)
    assertEq(message, 'that item cannot be analysed')
    assertEq(#DAG.Federal.Leads.For(1), 0)
end)

test('evidence collected outside a callout produces no lead', function()
    loadLeads()
    officer(1)
    DAG.Federal.CAD.Record('license:sam', 'Sam Cole')

    local item = DAG.Federal.CAD.CollectEvidence(1, { kind = 'print', subject = 'license:sam' })
    atLab(1)
    local analysed = DAG.Federal.CAD.AnalyseEvidence(1, item.id)

    assertEq(analysed.result, 'AFIS hit: Sam Cole', 'the analysis still works')
    assertNil(analysed.lead, 'it just has no investigation to feed')
end)

-- Following a lead is what changes the case, not producing it.
test('a lead only reveals anything once it is followed', function()
    loadLeads()
    officer(1)
    DAG.Federal.CAD.Record('license:sam', 'Sam Cole')
    local callout = dispatch()

    local analysed = analyse(callout.id, 'print', 'license:sam')
    assertFalse(DAG.Federal.Callouts.Get(callout.id).identified, 'not yet')
    assertEq(DAG.Federal.Callouts.LeadCount(DAG.Federal.Callouts.Get(callout.id)), 0)

    DAG.Federal.Leads.Follow(1, analysed.lead)
    local worked = DAG.Federal.Callouts.Get(callout.id)
    assertTrue(worked.identified, 'the subject is now named')
    assertEq(DAG.Federal.Callouts.LeadCount(worked), 1)
end)

test('a lead cannot be worked twice', function()
    loadLeads()
    officer(1)
    DAG.Federal.CAD.Record('license:sam', 'Sam Cole')
    local callout = dispatch()
    local analysed = analyse(callout.id, 'print', 'license:sam')

    DAG.Federal.Leads.Follow(1, analysed.lead)
    local _, message = DAG.Federal.Leads.Follow(1, analysed.lead)
    assertEq(message, 'that lead has already been worked')
    assertEq(DAG.Federal.Callouts.LeadCount(DAG.Federal.Callouts.Get(callout.id)), 1, 'and is not double counted')
end)

-- An NPC suspect has no identity until a lead gives it one; otherwise
-- "identifying" it reveals the words "Unidentified subject".
test('identifying the subject reveals their name on the dispatch view', function()
    loadLeads()
    officer(1)
    DAG.Federal.CAD.Record('license:sam', 'Sam Cole')
    local callout = dispatch()
    local analysed = analyse(callout.id, 'print', 'license:sam')

    local before = DAG.Federal.Callouts.Active(1)[1]
    assertEq(before.suspect.name, 'Unidentified subject')

    DAG.Federal.Leads.Follow(1, analysed.lead)
    local after = DAG.Federal.Callouts.Active(1)[1]
    assertEq(after.suspect.name, 'Sam Cole')
    assertTrue(after.suspect.identified)
end)

-- A plate is the one lead worked at a terminal rather than in the world.
test('running a plate names the keeper and identifies the suspect', function()
    loadLeads()
    officer(1)
    local callout = dispatch()

    -- Force a document lead to be a plate.
    local membership = DAG.Federal.Core.Membership(1)
    local lead = DAG.Federal.Leads.Create(membership, { calloutId = callout.id, kind = 'plate' })
    assertEq(#lead.plate, 8)

    local run = DAG.Federal.Leads.RunPlate(1, lead.plate)
    assertEq(run.status, 'followed')
    assertTrue(type(run.keeper) == 'string')
    assertTrue(DAG.Federal.Callouts.Get(callout.id).identified)
end)

test('a plate that matches nothing is a cold result, not an error', function()
    loadLeads()
    officer(1)
    local run = DAG.Federal.Leads.RunPlate(1, 'ZZ99ZZZZ')
    assertEq(run.status, 'cold')
    assertEq(run.summary, 'No registered keeper on file.')
end)

test('running a plate is case and whitespace insensitive', function()
    loadLeads()
    officer(1)
    local callout = dispatch()
    local membership = DAG.Federal.Core.Membership(1)
    local lead = DAG.Federal.Leads.Create(membership, { calloutId = callout.id, kind = 'plate' })

    local messy = (' ' .. lead.plate:lower() .. ' ')
    assertEq(DAG.Federal.Leads.RunPlate(1, messy).status, 'followed')
end)

test('an address lead puts a second location away from the scene', function()
    loadLeads()
    officer(1)
    local callout = dispatch()
    local membership = DAG.Federal.Core.Membership(1)

    local lead = DAG.Federal.Leads.Create(membership, { calloutId = callout.id, kind = 'address' })
    assertTrue(lead.location ~= nil)

    local distance = DAG.Federal.Util.Distance(lead.location, callout.location)
    assertTrue(distance >= 120.0, 'a genuinely different place, not the same scene')
    assertTrue(distance <= 320.0)
end)

test('a contact lead brings a witness to the scene', function()
    loadLeads()
    officer(1)
    local callout = dispatch()
    local membership = DAG.Federal.Core.Membership(1)

    local lead = DAG.Federal.Leads.Create(membership, { calloutId = callout.id, kind = 'contact' })
    DAG.Federal.Leads.Follow(1, lead.id)
    assertTrue(DAG.Federal.Callouts.Get(callout.id).flags.extraWitness)
end)

test('an unknown lead kind is refused', function()
    loadLeads()
    officer(1)
    local membership = DAG.Federal.Core.Membership(1)
    local _, message = DAG.Federal.Leads.Create(membership, { kind = 'psychic' })
    assertEq(message, 'unknown lead kind')
end)

test('leads are readable only by agencies that may read the case', function()
    loadLeads()
    officer(1)
    DAG.Federal.CAD.Record('license:sam', 'Sam Cole')
    local callout = dispatch()
    analyse(callout.id, 'print', 'license:sam')

    assertEq(#DAG.Federal.Leads.For(1), 1)

    -- The DOA is not on the FIB share list.
    harness.identifiers[2] = 'license:2'
    harness.names[2] = 'Inspector'
    harness.setJob(2, 'doa', 2)
    harness.placePlayer(2, zoneCoords('doa', 'duty'))
    DAG.Federal.Core.SetDuty(2, true)
    assertEq(#DAG.Federal.Leads.For(2), 0)
end)

test('the investigate stage counts followed leads, not collected evidence', function()
    loadLeads()
    officer(1)
    DAG.Federal.CAD.Record('license:sam', 'Sam Cole')
    local callout = dispatch()
    DAG.Federal.Callouts.Attach(1, callout.id)

    harness.placePlayer(1, vector3(callout.location.x, callout.location.y, callout.location.z))
    DAG.Federal.Callouts.Progress(1, callout.id, 'arrive')
    DAG.Federal.Callouts.Progress(1, callout.id, 'interview')

    local first = DAG.Federal.CAD.CollectEvidence(1, {
        kind = 'print', calloutId = callout.id, subject = 'license:sam'
    })
    DAG.Federal.CAD.CollectEvidence(1, { kind = 'document', calloutId = callout.id })
    DAG.Federal.Callouts.Progress(1, callout.id, 'evidence')

    local _, message = DAG.Federal.Callouts.Progress(1, callout.id, 'investigate')
    assertEq(message, '0 of 1 leads followed', 'two items collected is not a lead followed')

    atLab(1)
    local analysed = DAG.Federal.CAD.AnalyseEvidence(1, first.id)
    DAG.Federal.Leads.Follow(1, analysed.lead)
    harness.placePlayer(1, vector3(callout.location.x, callout.location.y, callout.location.z))

    assertEq(DAG.Federal.Callouts.Progress(1, callout.id, 'investigate').stage, 5)
end)

test('the identify stage refuses until a lead has named the subject', function()
    loadLeads()
    officer(1)
    local callout = dispatch()
    DAG.Federal.Callouts.Attach(1, callout.id)

    local stored = DAG.Federal.Callouts.Get(callout.id)
    stored.stage = 5
    local _, message = DAG.Federal.Callouts.Progress(1, callout.id, 'identify')
    assertEq(message, 'the subject has not been identified yet')
end)
