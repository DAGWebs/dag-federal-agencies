-- Dispatch routing and deployable field equipment.
local function loadServer()
    return harness.loadFederalServer({
        federal = { 'core', 'cad', 'dispatch', 'equipment', 'reports', 'leads', 'callouts' }
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

-- Dispatch -------------------------------------------------------------------

test('with no dispatch resource running the built-in alert is used', function()
    loadServer()
    officer(1)
    assertNil(DAG.Federal.Dispatch.Provider())

    harness.clientEvents = {}
    DAG.Federal.Dispatch.Alert({
        agency = 'fib', title = 'Test', message = 'Something', coords = { x = 1.0, y = 2.0, z = 3.0 }
    })

    local alerted = false
    for _, event in ipairs(harness.clientEvents) do
        if event.event:find('federal:dispatch', 1, true) then
            alerted = true
            assertEq(event.target, 1)
        end
    end
    assertTrue(alerted)
end)

test('a started dispatch resource is picked up automatically', function()
    loadServer()
    officer(1)
    harness.resourceStates['ps-dispatch'] = 'started'

    local provider = DAG.Federal.Dispatch.Provider()
    assertTrue(provider ~= nil)
    assertEq(provider.name, 'ps-dispatch')
end)

test('a named provider that is not running says so and falls back once', function()
    loadServer()
    officer(1)
    Config.Federal.dispatch.provider = 'cd_dispatch'

    assertNil(DAG.Federal.Dispatch.Provider())
    assertTrue(harness.outputContains('is configured but not started'))

    -- Warned once, not on every alert for the rest of the shift.
    harness.output = {}
    DAG.Federal.Dispatch.Provider()
    assertFalse(harness.outputContains('is configured but not started'))
end)

test('internal can be forced even with a provider running', function()
    loadServer()
    officer(1)
    harness.resourceStates['ps-dispatch'] = 'started'
    Config.Federal.dispatch.provider = 'internal'

    assertNil(DAG.Federal.Dispatch.Provider())
end)

-- Two alert systems shouting over each other is worse than either alone.
test('an external provider suppresses the built-in alert by default', function()
    loadServer()
    officer(1)
    harness.resourceStates['ps-dispatch'] = 'started'
    harness.exportTargets['ps-dispatch'] = { CustomAlert = function() end }

    harness.clientEvents = {}
    DAG.Federal.Dispatch.Alert({
        agency = 'fib', title = 'Test', message = 'Something', coords = { x = 1.0, y = 2.0, z = 3.0 }
    })

    for _, event in ipairs(harness.clientEvents) do
        assertFalse(event.event:find('federal:dispatch', 1, true) ~= nil, 'no double alert')
    end
end)

test('both can be sent when the server asks for it', function()
    loadServer()
    officer(1)
    harness.resourceStates['ps-dispatch'] = 'started'
    harness.exportTargets['ps-dispatch'] = { CustomAlert = function() end }
    Config.Federal.dispatch.alsoInternal = true

    harness.clientEvents = {}
    DAG.Federal.Dispatch.Alert({
        agency = 'fib', title = 'Test', message = 'Something', coords = { x = 1.0, y = 2.0, z = 3.0 }
    })

    local internal = false
    for _, event in ipairs(harness.clientEvents) do
        if event.event:find('federal:dispatch', 1, true) then internal = true end
    end
    assertTrue(internal)
end)

-- A broken provider must not take the alert with it.
test('a provider that errors falls back to the built-in alert', function()
    loadServer()
    officer(1)
    harness.resourceStates['ps-dispatch'] = 'started'
    harness.exportTargets['ps-dispatch'] = {
        CustomAlert = function() error('dispatch resource is broken') end
    }

    harness.clientEvents = {}
    DAG.Federal.Dispatch.Alert({
        agency = 'fib', title = 'Test', message = 'Something', coords = { x = 1.0, y = 2.0, z = 3.0 }
    })

    local internal = false
    for _, event in ipairs(harness.clientEvents) do
        if event.event:find('federal:dispatch', 1, true) then internal = true end
    end
    assertTrue(internal, 'the officers still heard about it')
    assertTrue(harness.outputContains('errored'))
end)

test('an alert carries the agency job names an external provider filters on', function()
    loadServer()
    local jobs = DAG.Federal.Dispatch.JobsFor('fib')
    assertEq(#jobs, 2)
    assertEq(jobs[1], 'fib')
    assertEq(#DAG.Federal.Dispatch.JobsFor('nope'), 0)
end)

test('a dispatched callout alerts through the dispatch layer', function()
    loadServer()
    officer(1)
    harness.clientEvents = {}

    DAG.Federal.Callouts.Dispatch('fib', 'wire-fraud', 1)
    local alerted = false
    for _, event in ipairs(harness.clientEvents) do
        if event.event:find('federal:dispatch', 1, true) then alerted = true end
    end
    assertTrue(alerted)
end)

-- Field equipment -----------------------------------------------------------

test('the available list marks what a rank cannot carry', function()
    loadServer()
    officer(1, 0)
    local list = DAG.Federal.Equipment.Available(1)

    local byId = {}
    for _, entry in ipairs(list) do byId[entry.id] = entry end
    assertFalse(byId.cone.locked, 'a probationary agent may put out cones')
    assertTrue(byId.spikes.locked, 'but has no spike strip item')
    assertEq(byId.spikes.lockedReason, 'Requires spikestrip')
end)

test('deploying consumes the item and registers the object', function()
    loadServer()
    officer(1)
    DAG.Framework.AddItem(1, 'spikestrip', 1)

    local record = DAG.Federal.Equipment.Deploy(1, 'spikes', 4242)
    assertEq(record.label, 'Spike strip')
    assertEq(record.netId, 4242)
    assertEq(DAG.Framework.GetItemCount(1, 'spikestrip'), 0, 'the item was used')
    assertEq(#DAG.Federal.Equipment.List(1), 1)
end)

test('deploying something you do not have is refused', function()
    loadServer()
    officer(1)
    local _, message = DAG.Federal.Equipment.Deploy(1, 'spikes', 1)
    assertEq(message, 'you do not have a spikestrip')
end)

test('equipment with no item requirement needs only the rank', function()
    loadServer()
    officer(1, 0)
    assertEq(DAG.Federal.Equipment.Deploy(1, 'cone', 1).label, 'Traffic cone')
end)

test('a rank without the permission cannot deploy that item', function()
    loadServer()
    -- A piece of kit gated on a permission only senior ranks carry.
    Config.Federal.equipment.items[#Config.Federal.equipment.items + 1] = {
        id = 'shredder', label = 'Document shredder', model = 'prop_cs_shredder',
        permission = 'cad.expunge'
    }

    officer(1, 2)
    local _, message = DAG.Federal.Equipment.Deploy(1, 'shredder', 1)
    assertEq(message, 'your rank does not carry that')

    local locked = {}
    for _, entry in ipairs(DAG.Federal.Equipment.Available(1)) do locked[entry.id] = entry end
    assertTrue(locked.shredder.locked)
    assertEq(locked.shredder.lockedReason, 'Your rank does not carry this')

    -- An Assistant Director does carry it.
    officer(1, 4)
    assertEq(DAG.Federal.Equipment.Deploy(1, 'shredder', 1).label, 'Document shredder')
end)

test('an unknown item is refused', function()
    loadServer()
    officer(1)
    local _, message = DAG.Federal.Equipment.Deploy(1, 'tank', 1)
    assertEq(message, 'no such equipment')
end)

-- Otherwise one player leaves two hundred barriers on a motorway.
test('one officer cannot exceed the deployment limit', function()
    loadServer()
    officer(1)
    Config.Federal.equipment.limit = 3

    for index = 1, 3 do
        assertTrue(DAG.Federal.Equipment.Deploy(1, 'cone', index) ~= nil)
    end
    local _, message = DAG.Federal.Equipment.Deploy(1, 'cone', 4)
    assertEq(message, 'you already have 3 out; pick some up first')
end)

-- Otherwise a road stays full of cones because the officer who put them there
-- logged off.
test('anybody in the agency can pick up anybody else’s equipment', function()
    loadServer()
    officer(1)
    officer(2)
    local record = DAG.Federal.Equipment.Deploy(1, 'cone', 1)

    assertEq(DAG.Federal.Equipment.Retrieve(2, record.id).id, record.id)
    assertEq(#DAG.Federal.Equipment.List(1), 0)
end)

test('picking up returns the item that was consumed', function()
    loadServer()
    officer(1)
    DAG.Framework.AddItem(1, 'spikestrip', 1)
    local record = DAG.Federal.Equipment.Deploy(1, 'spikes', 1)

    DAG.Federal.Equipment.Retrieve(1, record.id)
    assertEq(DAG.Framework.GetItemCount(1, 'spikestrip'), 1)
end)

test('another agency cannot pick up your equipment', function()
    loadServer()
    officer(1)
    harness.identifiers[3] = 'license:3'
    harness.names[3] = 'Inspector'
    harness.setJob(3, 'doa', 2)
    harness.placePlayer(3, zoneCoords('doa', 'duty'))
    DAG.Federal.Core.SetDuty(3, true)

    local record = DAG.Federal.Equipment.Deploy(1, 'cone', 1)
    local _, message = DAG.Federal.Equipment.Retrieve(3, record.id)
    assertEq(message, 'that belongs to another agency')
end)

test('a supervisor can clear everything the agency has out', function()
    loadServer()
    officer(1, 3)
    for index = 1, 3 do DAG.Federal.Equipment.Deploy(1, 'cone', index) end

    assertEq(DAG.Federal.Equipment.ClearAll(1).cleared, 3)
    assertEq(#DAG.Federal.Equipment.List(1), 0)
end)

test('clearing everything needs callout.manage', function()
    loadServer()
    officer(1, 2)
    DAG.Federal.Equipment.Deploy(1, 'cone', 1)
    assertNil(DAG.Federal.Equipment.ClearAll(1))
    assertEq(#DAG.Federal.Equipment.List(1), 1)
end)

test('field equipment can be switched off', function()
    loadServer()
    Config.Federal.equipment.enabled = false
    officer(1)

    assertEq(#DAG.Federal.Equipment.Available(1), 0)
    local _, message = DAG.Federal.Equipment.Deploy(1, 'cone', 1)
    assertEq(message, 'field equipment is disabled')
end)
