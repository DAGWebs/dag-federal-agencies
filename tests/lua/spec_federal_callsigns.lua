-- Callsigns: a member's callsign is theirs, the prefix is forced from the
-- agency (or division) config, and who may change what is a permission.

local function loadAll()
    return harness.loadFederalServer({ federal = { 'core', 'uniforms', 'editor' } })
end

local function agent(playerSource, grade, agencyId)
    harness.identifiers[playerSource] = 'license:cs' .. playerSource
    harness.names[playerSource] = 'Agent ' .. playerSource
    harness.setJob(playerSource, agencyId or 'fib', grade or 2)

    local agency = DAG.Federal.Core.Agency(agencyId or 'fib')
    local duty = DAG.Federal.Schema.FindById(agency.stations[1].zones, 'duty')
    harness.placePlayer(playerSource, vector3(duty.coords.x, duty.coords.y, duty.coords.z))
end

test('a callsign belongs to the member, not the clock-in', function()
    loadAll()
    agent(1)
    agent(2)

    DAG.Federal.Core.SetDuty(1, true)
    DAG.Federal.Core.SetDuty(2, true)
    assertEq(DAG.Federal.Core.Unit(1).callsign, 'FIB-1')
    assertEq(DAG.Federal.Core.Unit(2).callsign, 'FIB-2')

    -- Clocking off and back on renumbers nobody.
    DAG.Federal.Core.SetDuty(1, false)
    DAG.Federal.Core.SetDuty(1, true)
    assertEq(DAG.Federal.Core.Unit(1).callsign, 'FIB-1')
end)

test('the configured agency prefix is forced onto every callsign', function()
    loadAll()
    harness.aceAllowed[9] = { ['federal.admin'] = true }
    agent(9, 5)
    assertTrue(DAG.Federal.Editor.UpdateAgency(9, 'fib', { callsignPrefix = '1f-' }) ~= nil)

    agent(1)
    DAG.Federal.Core.SetDuty(1, true)
    assertEq(DAG.Federal.Core.Unit(1).callsign, '1F-1')

    -- Typing the prefix along with the suffix does not double it.
    assertEq(DAG.Federal.Core.SetCallsign(9, 1, '1f-12'), '1F-12')
    assertEq(DAG.Federal.Core.Unit(1).callsign, '1F-12', 'a unit on the air re-brands live')
end)

test('choosing your own callsign is a permission; managers set anyone', function()
    loadAll()
    agent(1, 2)
    local _, message = DAG.Federal.Core.SetCallsign(1, nil, '55')
    assertEq(message, 'your rank does not choose its own callsign')

    -- The boss grade carries roster.manage, which covers both paths.
    agent(5, 5)
    assertEq(DAG.Federal.Core.SetCallsign(5, 1, 'adam 1'), 'FIB-ADAM1')
    assertEq(DAG.Federal.Core.SetCallsign(5, nil, '100'), 'FIB-100')

    -- Two units answering one callsign is a radio disaster: refused.
    agent(2, 2)
    local _, dupe = DAG.Federal.Core.SetCallsign(5, 2, 'ADAM1')
    assertEq(dupe, 'FIB-ADAM1 is already assigned')

    -- Another agency's roster is not yours to brand.
    agent(3, 2, 'iaa')
    local _, foreign = DAG.Federal.Core.SetCallsign(5, 3, '9')
    assertEq(foreign, 'they serve a different agency')
end)

test('certifications are a director catalog with licence prerequisites', function()
    loadAll()
    harness.aceAllowed[9] = { ['federal.admin'] = true }
    agent(9, 5)

    local cert = DAG.Federal.Editor.SaveCertification(9, 'fib', {
        label = 'Aviation', licences = { 'Practical_Plane', 'practical_heli' }
    })
    assertEq(cert.id, 'aviation')
    -- Licence names normalize (lowercased, sorted) so the award gate
    -- compares apples to apples.
    assertEq(cert.licences[1], 'practical_heli')
    assertEq(cert.licences[2], 'practical_plane')
    assertEq(#DAG.Federal.Core.Agency('fib').certifications, 1)

    assertTrue(DAG.Federal.Editor.DeleteCertification(9, 'fib', 'aviation') ~= nil)
    assertEq(#DAG.Federal.Core.Agency('fib').certifications, 0)
end)

test('a division prefix overrides the agency prefix', function()
    loadAll()
    harness.aceAllowed[9] = { ['federal.admin'] = true }
    agent(9, 5)
    DAG.Federal.Editor.UpdateAgency(9, 'fib', { callsignPrefix = '1F-' })
    assertTrue(DAG.Federal.Editor.SaveDivision(9, 'fib', { label = 'SWAT', callsignPrefix = 'x-' }) ~= nil)

    agent(1)
    DAG.Federal.Core.AssignDivision('license:cs1', 'fib', 'swat')
    DAG.Federal.Core.SetDuty(1, true)
    assertEq(DAG.Federal.Core.Unit(1).callsign, 'X-1')

    -- Leaving the division falls back to the agency prefix, same suffix.
    DAG.Federal.Core.AssignDivision('license:cs1', 'fib', nil)
    DAG.Federal.Core.SetDuty(1, false)
    DAG.Federal.Core.SetDuty(1, true)
    assertEq(DAG.Federal.Core.Unit(1).callsign, '1F-1')
end)
