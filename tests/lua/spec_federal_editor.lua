local function loadEditor()
    return harness.loadFederalServer({ federal = { 'core', 'cad', 'uniforms', 'armory', 'editor' } })
end

local function director(playerSource, agencyId, grade)
    harness.identifiers[playerSource] = 'license:' .. tostring(playerSource)
    harness.names[playerSource] = 'Director ' .. playerSource
    harness.setJob(playerSource, agencyId or 'fib', grade or 5)
    harness.placePlayer(playerSource, vector3(500.0, 500.0, 30.0))
    DAG.Federal.Core.SetDuty(playerSource, true)
end

test('a zone is placed at the position the server reads, not one the client sent', function()
    loadEditor()
    director(1)
    harness.placePlayer(1, vector3(123.5, -456.25, 31.5))

    -- The client asks for "here" and also sends a coordinate. The server must
    -- use the position it read for that player and ignore the claim.
    local zone = DAG.Federal.Editor.SaveZone(1, 'fib', 'fib-tower', {
        kind = 'locker', label = 'North lockers', here = true, coords = { x = 9999.0, y = 9999.0, z = 9999.0 }
    })

    assertEq(zone.coords.x, 123.5)
    assertEq(zone.coords.y, -456.25)
    assertEq(zone.id, 'north-lockers')
end)

test('a placed zone is persisted on the agency and survives a registry rebuild', function()
    loadEditor()
    director(1)
    DAG.Federal.Editor.SaveZone(1, 'fib', 'fib-tower', { kind = 'cells', label = 'Sub-level cells', here = true })

    DAG.Federal.Core.Invalidate()
    local station = DAG.Federal.Schema.FindById(DAG.Federal.Core.Agency('fib').stations, 'fib-tower')
    assertEq(DAG.Federal.Schema.FindById(station.zones, 'sub-level-cells').kind, 'cells')
end)

test('an unknown zone kind is refused', function()
    loadEditor()
    director(1)
    local _, message = DAG.Federal.Editor.SaveZone(1, 'fib', 'fib-tower', { kind = 'helipad', here = true })
    assertEq(message, 'unknown zone kind')
end)

test('editing is confined to your own agency', function()
    loadEditor()
    director(1, 'fib', 5)
    local _, message = DAG.Federal.Editor.SaveZone(1, 'iaa', 'iaa-annex', { kind = 'locker', here = true })
    assertEq(message, 'you may only edit your own agency')

    -- and the IAA station is untouched
    local station = DAG.Federal.Schema.FindById(DAG.Federal.Core.Agency('iaa').stations, 'iaa-annex')
    assertEq(#station.zones, 8)
end)

test('a rank without editor.manage cannot edit anything', function()
    loadEditor()
    director(1, 'fib', 3)
    local _, message = DAG.Federal.Editor.SaveZone(1, 'fib', 'fib-tower', { kind = 'locker', here = true })
    assertEq(message, 'not authorized')
end)

test('an admin may edit any agency', function()
    loadEditor()
    harness.setJob(1, 'mechanic', 0)
    harness.aceAllowed[1] = { ['federal.admin'] = true }
    harness.placePlayer(1, vector3(10.0, 20.0, 30.0))

    assertEq(DAG.Federal.Editor.SaveZone(1, 'usss', 'usss-depot', { kind = 'garage', label = 'Rear yard', here = true }).id, 'rear-yard')
end)

test('deleting a zone removes only that zone', function()
    loadEditor()
    director(1)
    local before = #DAG.Federal.Schema.FindById(DAG.Federal.Core.Agency('fib').stations, 'fib-tower').zones

    assertEq(DAG.Federal.Editor.DeleteZone(1, 'fib', 'fib-tower', 'cells').id, 'cells')
    local station = DAG.Federal.Schema.FindById(DAG.Federal.Core.Agency('fib').stations, 'fib-tower')
    assertEq(#station.zones, before - 1)
    assertNil(DAG.Federal.Schema.FindById(station.zones, 'cells'))
    assertEq(DAG.Federal.Schema.FindById(station.zones, 'armory').kind, 'armory', 'the others are intact')

    local _, message = DAG.Federal.Editor.DeleteZone(1, 'fib', 'fib-tower', 'cells')
    assertEq(message, 'no such zone')
end)

test('a new station is created at the placing player and starts with no rooms', function()
    loadEditor()
    director(1)
    harness.placePlayer(1, vector3(-750.0, 300.5, 85.0))

    local station = DAG.Federal.Editor.SaveStation(1, 'fib', { label = 'Vinewood Resident Office', here = true })
    assertEq(station.id, 'vinewood-resident-office')
    assertEq(station.coords.x, -750.0)
    assertEq(#station.zones, 0, 'rooms are placed individually')
    assertEq(#DAG.Federal.Core.Agency('fib').stations, 3)
end)

-- Moving a station must not silently discard the rooms already placed in it.
test('moving an existing station keeps its zones', function()
    loadEditor()
    director(1)
    harness.placePlayer(1, vector3(1000.0, 1000.0, 50.0))

    local moved = DAG.Federal.Editor.SaveStation(1, 'fib', { id = 'fib-tower', label = 'FIB Tower', here = true })
    assertEq(moved.coords.x, 1000.0)
    assertEq(#moved.zones, 8, 'the rooms came with it')
end)

test('deleting a station removes it from the agency', function()
    loadEditor()
    director(1)
    assertEq(DAG.Federal.Editor.DeleteStation(1, 'fib', 'fib-sandy').id, 'fib-sandy')
    assertEq(#DAG.Federal.Core.Agency('fib').stations, 1)

    local _, message = DAG.Federal.Editor.DeleteStation(1, 'fib', 'fib-sandy')
    assertEq(message, 'no such station')
end)

test('agency fields are updated without disturbing its lists', function()
    loadEditor()
    director(1)
    local agency = DAG.Federal.Editor.UpdateAgency(1, 'fib', { label = 'Bureau of Investigation', bossGrade = 3 })

    assertEq(agency.label, 'Bureau of Investigation')
    assertEq(agency.bossGrade, 3)
    assertEq(#agency.stations, 2, 'stations untouched')
    assertEq(#agency.uniforms, 2, 'uniforms untouched')
    assertEq(#agency.ranks, 6, 'ranks untouched')
end)

test('creating and deleting an agency is admin only', function()
    loadEditor()
    director(1, 'fib', 5)
    local _, message = DAG.Federal.Editor.CreateAgency(1, { label = 'Department of Everything' })
    assertEq(message, 'creating an agency is an admin action')

    local _, deleteMessage = DAG.Federal.Editor.DeleteAgency(1, 'fib')
    assertEq(deleteMessage, 'deleting an agency is an admin action')
    assertEq(#DAG.Federal.Core.Agencies(), 4)
end)

-- A new agency with no ranks could never authorize anyone to give it ranks.
test('a created agency gets a working rank ladder and its own job name', function()
    loadEditor()
    harness.aceAllowed[1] = { ['federal.admin'] = true }
    harness.placePlayer(1, vector3(0.0, 0.0, 0.0))

    -- The id follows the short code when one is given, which is why the seeded
    -- agencies are 'fib' and 'iaa' rather than their full names.
    local agency = DAG.Federal.Editor.CreateAgency(1, { label = 'Federal Air Marshals', short = 'FAM' })
    assertEq(agency.id, 'fam')
    assertEq(#agency.ranks, 2)
    assertEq(agency.jobs[1], 'fam', 'the job name defaults to the id')
    assertTrue(agency.ranks[2].permissions['editor.manage'], 'the director can administer it')
    assertEq(#DAG.Federal.Core.Agencies(), 5)

    local _, message = DAG.Federal.Editor.CreateAgency(1, { label = 'Federal Air Marshals', short = 'FAM' })
    assertEq(message, 'an agency with that id already exists')
end)

test('a deleted agency stays deleted across a registry rebuild', function()
    loadEditor()
    harness.aceAllowed[1] = { ['federal.admin'] = true }
    DAG.Federal.Editor.DeleteAgency(1, 'doa')

    DAG.Federal.Core.Invalidate()
    assertNil(DAG.Federal.Core.Agency('doa'), 'the config must not resurrect it')
    assertEq(#DAG.Federal.Core.Agencies(), 3)
end)

test('ranks are edited and the last one cannot be removed', function()
    loadEditor()
    director(1)
    assertEq(DAG.Federal.Editor.SaveRank(1, 'fib', { grade = 2, label = 'Field Supervisor' }).label, 'Field Supervisor')
    assertEq(DAG.Federal.Core.Rank(DAG.Federal.Core.Agency('fib'), 2).label, 'Field Supervisor')

    for _, grade in ipairs({ 0, 1, 2, 3, 4 }) do DAG.Federal.Editor.DeleteRank(1, 'fib', grade) end
    local _, message = DAG.Federal.Editor.DeleteRank(1, 'fib', 5)
    assertEq(message, 'an agency must keep at least one rank')
end)

test('a rank granting an unknown permission is refused whole', function()
    loadEditor()
    director(1)
    local _, message = DAG.Federal.Editor.SaveRank(1, 'fib', {
        grade = 2, label = 'Typo', permissions = { ['cad.write'] = true, ['cad.destroy'] = true }
    })
    assertEq(message, 'unknown permission "cad.destroy"')
    assertEq(DAG.Federal.Core.Rank(DAG.Federal.Core.Agency('fib'), 2).label, 'Senior Special Agent', 'unchanged')
end)

test('an editor write pushes the new registry to connected clients', function()
    loadEditor()
    director(1)
    harness.clientEvents = {}
    DAG.Federal.Editor.SaveZone(1, 'fib', 'fib-tower', { kind = 'locker', label = 'Annex lockers', here = true })

    local pushed = false
    for _, event in ipairs(harness.clientEvents) do
        if event.event:find('federal:context', 1, true) then pushed = true end
    end
    assertTrue(pushed, 'clients are resynced after an edit')
end)
