local function loadCore()
    return harness.loadFederalServer({ federal = { 'core' } })
end

-- Puts player 1 in the FIB at `grade`, standing on the FIB Tower duty point.
local function agent(grade, jobName)
    harness.identifiers[1] = 'license:agent'
    harness.names[1] = 'Dana Reyes'
    harness.setJob(1, jobName or 'fib', grade or 0)
    local fib = DAG.Federal.Core.Agency('fib')
    local duty = DAG.Federal.Schema.FindById(fib.stations[1].zones, 'duty')
    harness.placePlayer(1, vector3(duty.coords.x, duty.coords.y, duty.coords.z))
    return fib
end

test('the registry loads the four configured agencies', function()
    loadCore()
    local list = DAG.Federal.Core.Agencies()
    assertEq(#list, 4)

    local ids = {}
    for _, agency in ipairs(list) do ids[agency.id] = agency end
    assertEq(ids.fib.short, 'FIB')
    assertEq(ids.iaa.label, 'International Affairs Agency')
    assertEq(ids.doa.short, 'DOA')
    assertEq(ids.usss.short, 'USSS')
end)

test('an agency is resolved from any of its configured job names', function()
    loadCore()
    assertEq(DAG.Federal.Core.AgencyForJob('fbi').id, 'fib', 'the alternate job name maps to the same agency')
    assertEq(DAG.Federal.Core.AgencyForJob('secretservice').id, 'usss')
    assertNil(DAG.Federal.Core.AgencyForJob('mechanic'))
    assertNil(DAG.Federal.Core.AgencyForJob(nil))
end)

test('rank resolution takes the highest rank the grade has reached', function()
    loadCore()
    local fib = DAG.Federal.Core.Agency('fib')
    assertEq(DAG.Federal.Core.Rank(fib, 0).label, 'Probationary Agent')
    assertEq(DAG.Federal.Core.Rank(fib, 2).label, 'Senior Special Agent')
    -- A grade above the top rank keeps the top rank rather than falling through.
    assertEq(DAG.Federal.Core.Rank(fib, 99).label, 'Director')
end)

test('membership is nil for a job that belongs to no agency', function()
    loadCore()
    harness.setJob(1, 'mechanic', 3)
    assertNil(DAG.Federal.Core.Membership(1))
end)

test('permissions come from the rank ladder', function()
    loadCore()
    agent(0)
    assertTrue(DAG.Federal.Core.Can(1, 'actions.detain'), 'a probationary agent may detain')
    assertFalse(DAG.Federal.Core.Can(1, 'cad.write'), 'but may not file incidents')

    agent(1)
    assertTrue(DAG.Federal.Core.Can(1, 'cad.write'))
    assertFalse(DAG.Federal.Core.Can(1, 'cad.warrant'))
end)

-- Without this a server that rewrites the rank ladder can end up with an
-- agency that nobody is able to administer.
test('reaching bossGrade grants the boss permissions whatever the rank lists', function()
    loadCore()
    agent(4)
    assertTrue(DAG.Federal.Core.Can(1, 'uniform.manage'))
    assertTrue(DAG.Federal.Core.Can(1, 'armory.manage'))
    assertTrue(DAG.Federal.Core.Membership(1).isBoss)

    agent(3)
    assertFalse(DAG.Federal.Core.Membership(1).isBoss)
    assertFalse(DAG.Federal.Core.Can(1, 'uniform.manage'))
end)

test('an unknown permission name is denied rather than matched', function()
    loadCore()
    agent(5)
    assertTrue(DAG.Federal.Core.Can(1, 'editor.manage'))
    assertFalse(DAG.Federal.Core.Can(1, 'cad.wrtie'), 'a typo must never pass the gate')
    assertFalse(DAG.Federal.Core.Can(1, ''))
end)

test('the admin ACE overrides rank for every permission', function()
    loadCore()
    harness.setJob(1, 'mechanic', 0)
    harness.aceAllowed[1] = { ['federal.admin'] = true }
    assertTrue(DAG.Federal.Core.Can(1, 'editor.manage'))
    assertTrue(DAG.Federal.Core.IsAdmin(1))
end)

test('zone detection uses the position the server reads, not a client claim', function()
    loadCore()
    local fib = agent(2)
    assertEq(DAG.Federal.Core.ZoneAt(1, fib, 'duty').id, 'duty')
    -- The armory is a few metres away from the duty point.
    assertNil(DAG.Federal.Core.ZoneAt(1, fib, 'boss'), 'standing at the desk is not standing in the office')

    local armory = DAG.Federal.Schema.FindById(fib.stations[1].zones, 'armory')
    harness.placePlayer(1, vector3(armory.coords.x, armory.coords.y, armory.coords.z))
    assertEq(DAG.Federal.Core.ZoneAt(1, fib, 'armory').id, 'armory')

    harness.placePlayer(1, vector3(5000.0, 5000.0, 0.0))
    assertNil(DAG.Federal.Core.ZoneAt(1, fib, 'duty'))
end)

test('Require enforces membership, permission and duty together', function()
    loadCore()
    agent(1)
    assertNil(DAG.Federal.Core.Require(1, 'cad.write'), 'off duty is refused while requireDuty is on')

    DAG.Federal.Core.SetDuty(1, true)
    assertEq(DAG.Federal.Core.Require(1, 'cad.write').agency.id, 'fib')
    assertNil(DAG.Federal.Core.Require(1, 'cad.expunge'), 'rank still gates the action while on duty')
end)

test('clocking on records a unit and clocking off removes it', function()
    loadCore()
    agent(2)
    assertTrue(DAG.Federal.Core.SetDuty(1, true, 'fib-tower', 'ALPHA-1'))

    local unit = DAG.Federal.Core.Unit(1)
    assertEq(unit.callsign, 'ALPHA-1')
    assertEq(unit.station, 'fib-tower')
    assertEq(unit.status, 'available')
    assertEq(#DAG.Federal.Core.Units('fib'), 1)
    assertEq(#DAG.Federal.Core.Units('iaa'), 0, 'the roster is per agency')

    DAG.Federal.Core.SetDuty(1, false)
    assertNil(DAG.Federal.Core.Unit(1))
    assertEq(#DAG.Federal.Core.Units('fib'), 0)
end)

test('a dropped player leaves the duty roster', function()
    loadCore()
    agent(2)
    DAG.Federal.Core.SetDuty(1, true)
    _G.source = 1
    TriggerEvent('playerDropped')
    _G.source = nil
    assertEq(#DAG.Federal.Core.Units('fib'), 0)
end)

test('record numbers climb per agency and per series', function()
    loadCore()
    assertEq(DAG.Federal.Core.NextNumber('fib', 'incident'), 'FIB-INC-0001')
    assertEq(DAG.Federal.Core.NextNumber('fib', 'incident'), 'FIB-INC-0002')
    assertEq(DAG.Federal.Core.NextNumber('fib', 'warrant'), 'FIB-WNT-0001', 'series are counted separately')
    assertEq(DAG.Federal.Core.NextNumber('iaa', 'incident'), 'IAA-INC-0001', 'agencies are counted separately')
end)

test('shareWith grants read access one way only', function()
    loadCore()
    agent(1, 'iaa')
    local readable = DAG.Federal.Core.ReadableAgencies(1)
    assertTrue(readable.iaa)
    assertTrue(readable.fib, 'FIB shares its records with the IAA')

    agent(1, 'doa')
    local doaReadable = DAG.Federal.Core.ReadableAgencies(1)
    assertTrue(doaReadable.doa)
    assertNil(doaReadable.iaa, 'the IAA never shared with the DOA')
end)

test('a stored agency replaces the configured one', function()
    loadCore()
    local fib = DAG.Federal.Core.Agency('fib')
    fib.label = 'Bureau of Federal Investigation'
    fib.bossGrade = 2
    DAG.Federal.Core.agencies.save('fib', fib)
    DAG.Federal.Core.Invalidate()

    assertEq(DAG.Federal.Core.Agency('fib').label, 'Bureau of Federal Investigation')
    assertEq(#DAG.Federal.Core.Agencies(), 4, 'replacing does not duplicate the agency')
end)

test('a tombstone removes a configured agency', function()
    loadCore()
    DAG.Federal.Core.agencies.save('doa', { deleted = true })
    DAG.Federal.Core.Invalidate()

    assertNil(DAG.Federal.Core.Agency('doa'))
    assertEq(#DAG.Federal.Core.Agencies(), 3)
end)

test('an agency stored in an invalid shape is skipped, not fatal', function()
    loadCore()
    -- Written straight to storage so it bypasses the repository validator, the
    -- way a hand-edited store file would.
    DAG.Storage.Set('federal_agencies', 'broken', { id = 'broken', label = 42 })
    DAG.Federal.Core.Invalidate()

    assertEq(#DAG.Federal.Core.Agencies(), 4, 'the other agencies still load')
    assertTrue(harness.outputContains('ignoring stored agency'))
end)

test('the client context ships permissions and membership together', function()
    loadCore()
    agent(4)
    DAG.Federal.Core.SetDuty(1, true)

    local context = DAG.Federal.Core.Context(1)
    assertEq(context.membership.agencyId, 'fib')
    assertEq(context.membership.rank, 'Assistant Director')
    assertTrue(context.membership.isBoss)
    assertTrue(context.membership.onDuty)
    assertTrue(context.permissions['uniform.manage'])
    assertEq(#context.agencies, 4)
end)

-- Two zones closer together than Config.Federal.zoneDistance would let one
-- marker satisfy the server check for a different room: standing at the
-- sign-in desk would also count as standing in the evidence lab.
test('no two zones of a configured station overlap at the configured distance', function()
    loadCore()
    local limit = Config.Federal.zoneDistance
    for _, agency in ipairs(DAG.Federal.Core.Agencies()) do
        for _, station in ipairs(agency.stations) do
            for outer = 1, #station.zones do
                for inner = outer + 1, #station.zones do
                    local a, b = station.zones[outer], station.zones[inner]
                    local gap = DAG.Federal.Util.Distance(a.coords, b.coords)
                    assertTrue(gap > limit,
                        ('%s/%s: %s and %s are %.1fm apart'):format(agency.id, station.id, a.id, b.id, gap))
                end
            end
        end
    end
end)

-- Any resource can change a job out from under us, and a dismissal changes it
-- before duty is cleared. Someone who is no longer in the agency must still be
-- able to leave its roster, or they keep receiving its callouts.
test('clocking off works even after the player has lost the job', function()
    loadCore()
    agent(2)
    DAG.Federal.Core.SetDuty(1, true)
    assertEq(#DAG.Federal.Core.Units('fib'), 1)

    harness.setJob(1, 'unemployed', 0)
    assertNil(DAG.Federal.Core.Membership(1))

    assertTrue(DAG.Federal.Core.SetDuty(1, false))
    assertEq(#DAG.Federal.Core.Units('fib'), 0)
    assertNil(DAG.Federal.Core.Unit(1))
end)
