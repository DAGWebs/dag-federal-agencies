-- Suspect behaviour. The first version of this spawned a ped that stood still
-- until somebody pressed E; these tests pin the behaviour that replaced it.
local function loadClient()
    return harness.loadFederalClient()
end

-- A suspect ped standing at `coords`, with a fixed disposition so the test is
-- about the decision logic rather than the dice.
local function suspect(disposition, coords)
    local ped = 9001
    harness.entityCoords[ped] = coords or vector3(0.0, 0.0, 0.0)
    return DAG.Federal.Suspects.Attach(ped, 'cal-1', disposition), ped
end

local function officerAt(coords, playerIndex)
    local player = playerIndex or 1
    harness.activePlayers[#harness.activePlayers + 1] = player
    harness.peds[player] = 7000 + player
    harness.entityCoords[7000 + player] = coords
    return 7000 + player
end

test('a suspect rolls a disposition and keeps it', function()
    loadClient()
    harness.fixRandom(0.1)
    local rolled = DAG.Federal.Suspects.Roll()

    assertTrue(rolled.flees, 'a low roll is under the 0.55 flee chance')
    assertTrue(rolled.fights)
    assertTrue(rolled.armed)
    assertTrue(type(rolled.weapon) == 'string')
end)

test('a high roll produces a suspect who neither runs nor fights', function()
    loadClient()
    harness.fixRandom(0.99)
    local rolled = DAG.Federal.Suspects.Roll()

    assertFalse(rolled.flees)
    assertFalse(rolled.fights)
    assertFalse(rolled.armed)
    assertNil(rolled.weapon)
end)

test('an armed suspect is given the weapon but keeps it holstered', function()
    loadClient()
    local _, ped = suspect({ flees = false, fights = true, armed = true, weapon = 'WEAPON_PISTOL' })

    assertEq(harness.pedWeapons[ped], 'WEAPON_PISTOL', 'they are carrying')
    assertEq(harness.drawnWeapons[ped], 'WEAPON_UNARMED', 'but not aiming when the officers arrive')
end)

test('a suspect ignores officers who are still far away', function()
    loadClient()
    local state = suspect({ flees = true, fights = false }, vector3(0.0, 0.0, 0.0))
    officerAt(vector3(200.0, 0.0, 0.0))

    assertEq(DAG.Federal.Suspects.Tick(state), 'idle')
end)

test('a suspect who runs is tasked to flee, not left standing', function()
    loadClient()
    local state, ped = suspect({ flees = true, fights = false }, vector3(0.0, 0.0, 0.0))
    officerAt(vector3(10.0, 0.0, 0.0))

    assertEq(DAG.Federal.Suspects.Tick(state), 'fleeing')
    assertEq(harness.pedTasks[ped], 'flee')
    assertFalse(state.subdued, 'and cannot be detained yet')
end)

test('a suspect who fights engages once the officer closes in', function()
    loadClient()
    local state, ped = suspect({ flees = false, fights = true, armed = true, weapon = 'WEAPON_PISTOL' },
        vector3(0.0, 0.0, 0.0))
    officerAt(vector3(4.0, 0.0, 0.0))

    assertEq(DAG.Federal.Suspects.Tick(state), 'fighting')
    assertEq(harness.pedTasks[ped], 'combat')
    assertEq(harness.drawnWeapons[ped], 'WEAPON_PISTOL', 'now they draw it')
end)

-- Without a surrender rule every callout ends in a foot chase or a shooting.
test('a suspect surrenders when outnumbered', function()
    loadClient()
    local state, ped = suspect({ flees = true, fights = true }, vector3(0.0, 0.0, 0.0))
    officerAt(vector3(6.0, 0.0, 0.0), 1)
    officerAt(vector3(7.0, 0.0, 0.0), 2)

    assertEq(DAG.Federal.Suspects.Tick(state), 'surrendered')
    assertEq(harness.pedTasks[ped], 'handsUp')
    assertTrue(state.subdued, 'and can now be detained')
end)

test('a suspect surrenders at gunpoint even to a lone officer', function()
    loadClient()
    local state = suspect({ flees = true, fights = true }, vector3(0.0, 0.0, 0.0))
    officerAt(vector3(5.0, 0.0, 0.0))
    harness.playerCoords = vector3(5.0, 0.0, 0.0)
    harness.freeAiming = true

    assertEq(DAG.Federal.Suspects.Tick(state), 'surrendered')
end)

test('a suspect who has run far enough gives up rather than leaving the map', function()
    loadClient()
    local state = suspect({ flees = true, fights = false }, vector3(0.0, 0.0, 0.0))
    officerAt(vector3(10.0, 0.0, 0.0))
    assertEq(DAG.Federal.Suspects.Tick(state), 'fleeing')

    -- They are now well past the configured flee distance from where they started.
    harness.entityCoords[state.ped] = vector3(400.0, 0.0, 0.0)
    harness.entityCoords[harness.peds[1]] = vector3(410.0, 0.0, 0.0)
    assertEq(DAG.Federal.Suspects.Tick(state), 'surrendered')
end)

test('a cornered runner who will not fight gives up', function()
    loadClient()
    local state = suspect({ flees = true, fights = false }, vector3(0.0, 0.0, 0.0))
    officerAt(vector3(10.0, 0.0, 0.0))
    DAG.Federal.Suspects.Tick(state)

    -- Caught: the officer is on top of them and they have stopped moving.
    harness.entityCoords[harness.peds[1]] = vector3(2.0, 0.0, 0.0)
    harness.speeds[state.ped] = 0.0
    assertEq(DAG.Federal.Suspects.Tick(state), 'surrendered')
end)

test('a cornered fighter turns and fights', function()
    loadClient()
    local state, ped = suspect({ flees = true, fights = true }, vector3(0.0, 0.0, 0.0))
    officerAt(vector3(10.0, 0.0, 0.0))
    DAG.Federal.Suspects.Tick(state)

    harness.entityCoords[harness.peds[1]] = vector3(2.0, 0.0, 0.0)
    harness.speeds[state.ped] = 0.0
    assertEq(DAG.Federal.Suspects.Tick(state), 'fighting')
    assertEq(harness.pedTasks[ped], 'combat')
end)

test('a suspect who goes down is subdued', function()
    loadClient()
    local state = suspect({ flees = true, fights = true }, vector3(0.0, 0.0, 0.0))
    officerAt(vector3(5.0, 0.0, 0.0))
    harness.deadPeds[state.ped] = true

    assertEq(DAG.Federal.Suspects.Tick(state), 'down')
    assertTrue(state.subdued)
end)

test('a suspect whose ped is gone is reported so the scene can forget them', function()
    loadClient()
    local state = suspect({ flees = false, fights = false }, vector3(0.0, 0.0, 0.0))
    harness.entityCoords[state.ped] = nil
    state.ped = 0

    assertEq(DAG.Federal.Suspects.Tick(state), 'gone')
end)

test('subduing a suspect puts them on the ground and marks them detainable', function()
    loadClient()
    local state, ped = suspect({ flees = false, fights = false })
    DAG.Federal.Suspects.Subdue(state)

    assertTrue(state.subdued)
    assertEq(state.stage, 'detained')
    assertEq(harness.scenarios[ped], 'WORLD_HUMAN_PRISONER_CROUCH')
end)

test('forgetting a suspect drops them from tracking', function()
    loadClient()
    local _, ped = suspect({ flees = false, fights = false })
    assertTrue(DAG.Federal.Suspects.State(ped) ~= nil)

    DAG.Federal.Suspects.Forget(ped)
    assertNil(DAG.Federal.Suspects.State(ped))
end)
