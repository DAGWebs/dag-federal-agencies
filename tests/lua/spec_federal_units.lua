-- Unit tracking and the panic button. The roster used to be a list in a menu,
-- and panic was a word in the constants table that did nothing.
local function loadServer()
    return harness.loadFederalServer({ federal = { 'core', 'cad' } })
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

test('unit positions carry the coordinates the server read', function()
    loadServer()
    officer(1)
    harness.placePlayer(1, vector3(123.0, 456.0, 30.0))

    local units = DAG.Federal.Core.UnitPositions('fib')
    assertEq(#units, 1)
    assertEq(units[1].coords.x, 123.0)
    assertEq(units[1].callsign, DAG.Federal.Core.Unit(1).callsign)
end)

test('you see your own agency and the ones that share with you', function()
    loadServer()
    officer(1, 'iaa', 2)

    local visible = DAG.Federal.Core.VisibleUnitAgencies(1)
    assertTrue(visible.iaa)
    assertTrue(visible.fib, 'the FIB shares its records with the IAA')
    assertNil(visible.doa)
end)

test('unit sharing can be switched off', function()
    loadServer()
    Config.Federal.units.shared = false
    officer(1, 'iaa', 2)

    local visible = DAG.Federal.Core.VisibleUnitAgencies(1)
    assertTrue(visible.iaa)
    assertNil(visible.fib)
end)

-- Gathers the per-officer payloads from one broadcast.
local function broadcast()
    harness.clientEvents = {}
    DAG.Federal.Core.BroadcastPositions()

    local payloads = {}
    for _, event in ipairs(harness.clientEvents) do
        if event.event:find('federal:units', 1, true) then payloads[event.target] = event.args[1] end
    end
    return payloads
end

test('an officer is never in their own unit push', function()
    loadServer()
    officer(1)
    officer(2)

    local payloads = broadcast()
    assertEq(#payloads[1], 1)
    assertEq(payloads[1][1].source, 2, 'their colleague, not themselves')
end)

-- Unit visibility follows the same grant as records: if you may read an
-- agency's cases, you may see its units.
test('who else you see follows the record-sharing grant', function()
    loadServer()
    officer(1, 'fib', 2)
    officer(3, 'doa', 2)

    local payloads = broadcast()
    -- The DOA shares its records with the FIB, so the FIB sees its units.
    assertEq(#payloads[1], 1)
    assertEq(payloads[1][1].agency, 'doa')

    -- The FIB never shared with the DOA, so it is not reciprocal.
    assertEq(#payloads[3], 0)
end)

test('with sharing off you only ever see your own agency', function()
    loadServer()
    Config.Federal.units.shared = false
    officer(1, 'fib', 2)
    officer(3, 'doa', 2)

    local payloads = broadcast()
    assertEq(#payloads[1], 0, 'nobody else in the FIB is on duty')
    assertEq(#payloads[3], 0)
end)

test('a unit push can be switched off entirely', function()
    loadServer()
    Config.Federal.units.enabled = false
    officer(1)
    harness.clientEvents = {}

    assertEq(DAG.Federal.Core.BroadcastPositions(), 0)
    assertEq(#harness.clientEvents, 0)
end)

-- Panic is the one status that has to do something.
test('panic alerts every unit in the agency with a position', function()
    loadServer()
    officer(1)
    officer(2)
    harness.placePlayer(1, vector3(700.0, -1200.0, 25.0))
    harness.clientEvents = {}

    assertTrue(DAG.Federal.Core.SetPanic(1, true))

    local alerted = {}
    for _, event in ipairs(harness.clientEvents) do
        if event.event:find('federal:panic', 1, true) and not event.event:find('clear', 1, true) then
            alerted[event.target] = event.args[1]
        end
    end

    assertTrue(alerted[2] ~= nil, 'the colleague was told')
    assertEq(alerted[2].source, 1)
    assertEq(alerted[2].coords.x, 700.0)
    assertEq(DAG.Federal.Core.Unit(1).status, 'panic')
end)

-- Panic is not a status you drift out of by pressing something else.
test('an ordinary status change cannot clear a panic', function()
    loadServer()
    officer(1)
    DAG.Federal.Core.SetPanic(1, true)

    assertFalse(DAG.Federal.Core.SetStatus(1, 'busy'))
    assertEq(DAG.Federal.Core.Unit(1).status, 'panic', 'still panicking')

    assertTrue(DAG.Federal.Core.SetStatus(1, 'available'))
    assertEq(DAG.Federal.Core.Unit(1).status, 'available')
    assertFalse(DAG.Federal.Core.Unit(1).panic)
end)

test('setting the panic status routes through the panic path', function()
    loadServer()
    officer(1)
    DAG.Federal.Core.SetStatus(1, 'panic')

    assertTrue(DAG.Federal.Core.Unit(1).panic)
    assertTrue(DAG.Federal.Core.Unit(1).panicAt ~= nil)
end)

test('clearing a panic tells everyone to drop the beacon', function()
    loadServer()
    officer(1)
    officer(2)
    DAG.Federal.Core.SetPanic(1, true)
    harness.clientEvents = {}

    DAG.Federal.Core.SetPanic(1, false)
    local cleared = false
    for _, event in ipairs(harness.clientEvents) do
        if event.event:find('panic:clear', 1, true) then
            cleared = true
            assertEq(event.args[1], 1)
        end
    end
    assertTrue(cleared)
end)

-- Otherwise a disconnect leaves a beacon nobody can turn off.
test('a panicking officer who disconnects clears their own beacon', function()
    loadServer()
    officer(1)
    officer(2)
    DAG.Federal.Core.SetPanic(1, true)
    harness.clientEvents = {}

    _G.source = 1
    TriggerEvent('playerDropped')
    _G.source = nil

    local cleared = false
    for _, event in ipairs(harness.clientEvents) do
        if event.event:find('panic:clear', 1, true) then cleared = true end
    end
    assertTrue(cleared, 'the beacon did not outlive them')
end)

test('somebody off duty cannot panic', function()
    loadServer()
    officer(1)
    DAG.Federal.Core.SetDuty(1, false)
    assertFalse(DAG.Federal.Core.SetPanic(1, true))
end)
