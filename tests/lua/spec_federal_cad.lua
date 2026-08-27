local function loadCad()
    return harness.loadFederalServer({ federal = { 'core', 'cad' } })
end

-- Puts a player in an agency at a grade, on duty, standing at their duty desk.
local function officer(playerSource, agencyId, grade, name)
    harness.identifiers[playerSource] = 'license:' .. tostring(playerSource)
    harness.names[playerSource] = name or ('Officer ' .. playerSource)
    harness.setJob(playerSource, agencyId or 'fib', grade or 2)

    local agency = DAG.Federal.Core.Agency(agencyId or 'fib')
    local duty = DAG.Federal.Schema.FindById(agency.stations[1].zones, 'duty')
    harness.placePlayer(playerSource, vector3(duty.coords.x, duty.coords.y, duty.coords.z))
    DAG.Federal.Core.SetDuty(playerSource, true)
    return agency
end

local function standAt(playerSource, agencyId, zoneId)
    local agency = DAG.Federal.Core.Agency(agencyId)
    local zone = DAG.Federal.Schema.FindById(agency.stations[1].zones, zoneId)
    harness.placePlayer(playerSource, vector3(zone.coords.x, zone.coords.y, zone.coords.z))
end

test('filing an incident numbers it and records the filing officer', function()
    loadCad()
    officer(1, 'fib', 2, 'Dana Reyes')

    local incident = DAG.Federal.CAD.FileIncident(1, { title = 'Wire transfers to a shell account', type = 'Financial crime' })
    assertEq(incident.number, 'FIB-INC-0001')
    assertEq(incident.status, 'open')
    assertEq(incident.agency, 'fib')
    assertEq(incident.officers[1].name, 'Dana Reyes')
end)

test('an incident requires a title and a rank that may write', function()
    loadCad()
    officer(1, 'fib', 0)
    assertNil(DAG.Federal.CAD.FileIncident(1, { title = 'Anything' }), 'grade 0 has no cad.write')

    officer(1, 'fib', 2)
    local _, message = DAG.Federal.CAD.FileIncident(1, { title = '   ' })
    assertEq(message, 'an incident requires a title')
end)

test('narrative entries accumulate and stop at the cap', function()
    loadCad()
    officer(1, 'fib', 2)
    local incident = DAG.Federal.CAD.FileIncident(1, { title = 'Case', narrative = 'Initial report' })
    assertEq(#incident.narrative, 1)

    for index = 1, 20 do DAG.Federal.CAD.AddNarrative(1, incident.id, 'Entry ' .. index) end
    local stored = DAG.Federal.CAD.Incident(1, incident.id)
    assertEq(#stored.narrative, 12, 'the oldest entries fall off')
    assertEq(stored.narrative[#stored.narrative].text, 'Entry 20')
end)

test('a closed case rejects further narrative', function()
    loadCad()
    officer(1, 'fib', 2)
    local incident = DAG.Federal.CAD.FileIncident(1, { title = 'Case' })
    DAG.Federal.CAD.SetIncidentStatus(1, incident.id, 'closed')

    local _, message = DAG.Federal.CAD.AddNarrative(1, incident.id, 'Late addition')
    assertEq(message, 'that case is closed')
end)

test('the same suspect cannot be attached twice', function()
    loadCad()
    officer(1, 'fib', 2)
    local incident = DAG.Federal.CAD.FileIncident(1, { title = 'Case' })
    assertEq(#DAG.Federal.CAD.AttachSuspect(1, incident.id, { identifier = 'license:x', name = 'Sam' }).suspects, 1)

    local _, message = DAG.Federal.CAD.AttachSuspect(1, incident.id, { identifier = 'license:x' })
    assertEq(message, 'that suspect is already on the case')
end)

-- shareWith is a read grant. This is the test that keeps it one.
test('a shared agency can read another agency case but never write to it', function()
    loadCad()
    officer(1, 'fib', 2)
    local incident = DAG.Federal.CAD.FileIncident(1, { title = 'Joint case' })

    officer(2, 'iaa', 2)
    assertEq(DAG.Federal.CAD.Incident(2, incident.id).number, incident.number, 'the IAA may read it')

    local _, message = DAG.Federal.CAD.AddNarrative(2, incident.id, 'IAA addendum')
    assertEq(message, 'not authorized')
    assertEq(#DAG.Federal.CAD.Incident(1, incident.id).narrative, 0, 'nothing was written')
end)

test('an agency that was never shared with sees nothing', function()
    loadCad()
    officer(1, 'fib', 2)
    DAG.Federal.CAD.FileIncident(1, { title = 'FIB case' })

    officer(2, 'doa', 2)
    assertEq(#DAG.Federal.CAD.Incidents(2), 0, 'the DOA is not on the FIB share list')
    assertEq(#DAG.Federal.CAD.Incidents(1), 1)
end)

test('expunging an incident needs cad.expunge, not cad.write', function()
    loadCad()
    officer(1, 'fib', 2)
    local incident = DAG.Federal.CAD.FileIncident(1, { title = 'Case' })
    assertNil(DAG.Federal.CAD.DeleteIncident(1, incident.id))

    officer(1, 'fib', 4)
    assertEq(DAG.Federal.CAD.DeleteIncident(1, incident.id).id, incident.id)
    assertNil(DAG.Federal.CAD.Incident(1, incident.id))
end)

test('warrants are unique per subject and visible to every agency', function()
    loadCad()
    officer(1, 'fib', 2)
    local warrant = DAG.Federal.CAD.IssueWarrant(1, { identifier = 'license:sam', name = 'Sam Cole', reason = 'Wire fraud' })
    assertEq(warrant.number, 'FIB-WNT-0001')

    local _, message = DAG.Federal.CAD.IssueWarrant(1, { identifier = 'license:sam', reason = 'Again' })
    assertEq(message, 'that subject already has an active warrant')

    -- Lookup is force-wide: a warrant nobody else can see is useless.
    assertEq(DAG.Federal.CAD.ActiveWarrantFor('license:sam').number, warrant.number)

    DAG.Federal.CAD.SetWarrantStatus(1, warrant.id, 'served')
    assertNil(DAG.Federal.CAD.ActiveWarrantFor('license:sam'), 'a served warrant is no longer active')
end)

test('issuing a warrant needs cad.warrant and a stated reason', function()
    loadCad()
    officer(1, 'fib', 1)
    assertNil(DAG.Federal.CAD.IssueWarrant(1, { identifier = 'license:sam', reason = 'x' }), 'grade 1 cannot issue')

    officer(1, 'fib', 2)
    local _, message = DAG.Federal.CAD.IssueWarrant(1, { identifier = 'license:sam' })
    assertEq(message, 'a warrant requires a stated reason')
end)

-- The IAA config switches BOLOs off. The module flag has to actually gate.
test('a disabled CAD module is refused for the agency that disabled it', function()
    loadCad()
    officer(1, 'iaa', 2)
    local _, message = DAG.Federal.CAD.CreateBolo(1, { kind = 'person', subject = 'Sam Cole' })
    assertEq(message, 'not authorized')

    officer(2, 'fib', 2)
    assertEq(DAG.Federal.CAD.CreateBolo(2, { kind = 'person', subject = 'Sam Cole' }).number, 'FIB-BLO-0001')
end)

test('a BOLO must be for a person or a vehicle', function()
    loadCad()
    officer(1, 'fib', 2)
    local _, message = DAG.Federal.CAD.CreateBolo(1, { kind = 'drone', subject = 'Sam' })
    assertEq(message, 'a BOLO is for a person or a vehicle')
end)

test('arrests and fines accumulate on the citizen record', function()
    loadCad()
    officer(1, 'fib', 2)
    DAG.Federal.CAD.LogArrest(1, { identifier = 'license:sam', name = 'Sam Cole', charges = { 'Wire fraud' } })
    DAG.Federal.CAD.LogFine(1, 'license:sam', 'Sam Cole', 500, 'Failure to appear')

    local record = DAG.Federal.CAD.LookupRecord(1, 'license:sam')
    assertEq(#record.arrests, 1)
    assertEq(record.arrests[1].charges[1], 'Wire fraud')
    assertEq(record.fines[1].amount, 500)
end)

test('a record lookup surfaces an active warrant alongside it', function()
    loadCad()
    officer(1, 'fib', 2)
    DAG.Federal.CAD.LogArrest(1, { identifier = 'license:sam', name = 'Sam Cole' })
    DAG.Federal.CAD.IssueWarrant(1, { identifier = 'license:sam', name = 'Sam Cole', reason = 'Failure to appear' })

    assertEq(DAG.Federal.CAD.LookupRecord(1, 'license:sam').warrant.status, 'active')
end)

test('records are searchable by name and by identifier', function()
    loadCad()
    officer(1, 'fib', 2)
    DAG.Federal.CAD.Record('license:sam', 'Sam Cole')
    DAG.Federal.CAD.Record('license:ali', 'Ali Novak')

    assertEq(#DAG.Federal.CAD.SearchRecords(1, 'cole'), 1, 'case-insensitive name match')
    assertEq(DAG.Federal.CAD.SearchRecords(1, 'license:ali')[1].name, 'Ali Novak')
    assertEq(#DAG.Federal.CAD.SearchRecords(1, 'nobody'), 0)
end)

-- Collecting a swab must not tell you whose it is. That is what the lab is for.
test('evidence hides its subject until the lab analyses it', function()
    loadCad()
    officer(1, 'fib', 2)
    DAG.Federal.CAD.Record('license:sam', 'Sam Cole')

    local item = DAG.Federal.CAD.CollectEvidence(1, { kind = 'dna', subject = 'license:sam' })
    assertFalse(item.analysed)
    assertNil(item.result)

    -- Standing at the duty desk is not standing in the lab.
    local _, message = DAG.Federal.CAD.AnalyseEvidence(1, item.id)
    assertEq(message, 'not at an evidence lab')

    standAt(1, 'fib', 'evidence')
    local analysed = DAG.Federal.CAD.AnalyseEvidence(1, item.id)
    assertTrue(analysed.analysed)
    assertEq(analysed.result, 'Match: Sam Cole')
    assertEq(analysed.match, 'license:sam')
    assertEq(#analysed.chain, 2, 'the chain of custody records the analysis')
end)

test('an item is analysed once, and unanalysable kinds are refused', function()
    loadCad()
    officer(1, 'fib', 2)
    standAt(1, 'fib', 'evidence')

    local swab = DAG.Federal.CAD.CollectEvidence(1, { kind = 'dna', subject = 'license:ghost' })
    assertEq(DAG.Federal.CAD.AnalyseEvidence(1, swab.id).result, 'No match on file')

    local _, message = DAG.Federal.CAD.AnalyseEvidence(1, swab.id)
    assertEq(message, 'that item has already been analysed')

    local gun = DAG.Federal.CAD.CollectEvidence(1, { kind = 'weapon' })
    local _, gunMessage = DAG.Federal.CAD.AnalyseEvidence(1, gun.id)
    assertEq(gunMessage, 'that item cannot be analysed')
end)

test('evidence attaches to a case and is listed against it', function()
    loadCad()
    officer(1, 'fib', 2)
    local incident = DAG.Federal.CAD.FileIncident(1, { title = 'Case' })
    local item = DAG.Federal.CAD.CollectEvidence(1, { kind = 'print' })

    DAG.Federal.CAD.AttachEvidence(1, item.id, incident.id)
    local attached = DAG.Federal.CAD.EvidenceFor(1, incident.id)
    assertEq(#attached, 1)
    assertEq(attached[1].number, item.number)
end)

test('the dashboard counts only what the officer may read', function()
    loadCad()
    officer(1, 'fib', 2)
    DAG.Federal.CAD.FileIncident(1, { title = 'Open case' })
    DAG.Federal.CAD.IssueWarrant(1, { identifier = 'license:sam', reason = 'Fraud' })

    officer(2, 'doa', 2)
    local doa = DAG.Federal.CAD.Dashboard(2)
    assertEq(doa.openIncidents, 0, 'the DOA cannot see FIB cases')
    assertEq(doa.activeWarrants, 0)

    local fib = DAG.Federal.CAD.Dashboard(1)
    assertEq(fib.openIncidents, 1)
    assertEq(fib.activeWarrants, 1)
    assertEq(#fib.units, 1)
end)

test('an off-duty officer cannot write to the CAD', function()
    loadCad()
    officer(1, 'fib', 2)
    DAG.Federal.Core.SetDuty(1, false)
    assertNil(DAG.Federal.CAD.FileIncident(1, { title = 'From the couch' }))
end)
