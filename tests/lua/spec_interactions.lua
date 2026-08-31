local function loadInteractions()
    local dag = harness.loadClient({ adapters = { 'standalone' }, modules = { 'menu', 'interactions' } })
    return dag, harness.threads[#harness.threads]
end

local function at(x, y, z) return { x = x, y = y, z = z } end

test('coords accept a table, an array, or a vector3', function()
    loadInteractions()
    DAG.Interactions.Register({ id = 'a', coords = at(1, 2, 3) })
    DAG.Interactions.Register({ id = 'b', coords = { 4, 5, 6 } })
    DAG.Interactions.Register({ id = 'c', coords = vector3(7, 8, 9) })

    assertEq(DAG.Interactions.Get('a').coords.x, 1)
    assertEq(DAG.Interactions.Get('b').coords.y, 5)
    assertEq(DAG.Interactions.Get('c').coords.z, 9)
end)

test('registration rejects malformed input', function()
    loadInteractions()
    assertThrows(function() DAG.Interactions.Register({ coords = at(1, 2, 3) }) end)
    assertThrows(function() DAG.Interactions.Register({ id = 'a' }) end)
    assertThrows(function() DAG.Interactions.Register({ id = 'a', coords = { x = 1 } }) end)
end)

test('a marker is drawn only within the draw distance', function()
    local _, thread = loadInteractions()
    DAG.Interactions.Register({ id = 'near', coords = at(0, 0, 0) })
    DAG.Interactions.Register({ id = 'far', coords = at(500, 0, 0) })

    harness.playerCoords = vector3(0, 0, 0)
    harness.runThread(thread)
    assertEq(#harness.drawnMarkers, 1)
end)

-- Regression: every in-range entry used to draw its own help prompt, so the
-- keypress went to whichever entry pairs() happened to yield last.
test('only the closest eligible entry gets the prompt', function()
    local _, thread = loadInteractions()
    DAG.Interactions.Register({ id = 'far', coords = at(1.5, 0, 0), label = 'Far target' })
    DAG.Interactions.Register({ id = 'near', coords = at(0.2, 0, 0), label = 'Near target' })

    harness.playerCoords = vector3(0, 0, 0)
    harness.runThread(thread)

    assertEq(#harness.helpText, 1)
    assertEq(harness.helpText[1], 'Near target')
end)

test('the keypress activates the closest entry', function()
    local _, thread = loadInteractions()
    local activated
    DAG.Interactions.Register({ id = 'far', coords = at(1.5, 0, 0), onSelect = function() activated = 'far' end })
    DAG.Interactions.Register({ id = 'near', coords = at(0.2, 0, 0), onSelect = function() activated = 'near' end })

    harness.playerCoords = vector3(0, 0, 0)
    harness.controlsReleased[Config.InteractionKey] = true
    harness.runThread(thread)

    assertEq(activated, 'near')
end)

test('canInteract gates the prompt AND the marker', function()
    local _, thread = loadInteractions()
    DAG.Interactions.Register({
        id = 'gated',
        coords = at(0.2, 0, 0),
        label = 'Gated',
        canInteract = function() return false end
    })

    harness.playerCoords = vector3(0, 0, 0)
    harness.runThread(thread)
    assertEq(#harness.helpText, 0)
    -- An entry the player cannot use draws nothing: an off-duty officer's
    -- armory shows no arrow, not an arrow that refuses.
    assertEq(#harness.drawnMarkers, 0, 'a gated entry is invisible')
end)

test('a blocked closest entry does not mask an eligible one behind it', function()
    local _, thread = loadInteractions()
    DAG.Interactions.Register({
        id = 'blocked', coords = at(0.2, 0, 0), label = 'Blocked',
        canInteract = function() return false end
    })
    DAG.Interactions.Register({ id = 'open', coords = at(1.5, 0, 0), label = 'Open' })

    harness.playerCoords = vector3(0, 0, 0)
    harness.runThread(thread)

    assertEq(#harness.helpText, 1)
    assertEq(harness.helpText[1], 'Open')
end)

test('no prompt appears outside the interaction distance', function()
    local _, thread = loadInteractions()
    DAG.Interactions.Register({ id = 'a', coords = at(10, 0, 0), label = 'Too far' })

    harness.playerCoords = vector3(0, 0, 0)
    harness.runThread(thread)
    assertEq(#harness.helpText, 0)
    assertEq(#harness.drawnMarkers, 1)
end)

test('per-entry distances override the config defaults', function()
    local _, thread = loadInteractions()
    DAG.Interactions.Register({ id = 'a', coords = at(6, 0, 0), label = 'Wide', distance = 8.0 })

    harness.playerCoords = vector3(0, 0, 0)
    harness.runThread(thread)
    assertEq(#harness.helpText, 1)
end)

test('Remove and Clear drop registered entries', function()
    local _, thread = loadInteractions()
    DAG.Interactions.Register({ id = 'a', coords = at(0, 0, 0) })
    DAG.Interactions.Register({ id = 'b', coords = at(0, 0, 0) })

    DAG.Interactions.Remove('a')
    assertNil(DAG.Interactions.Get('a'))

    DAG.Interactions.Clear()
    harness.playerCoords = vector3(0, 0, 0)
    harness.runThread(thread)
    assertEq(#harness.drawnMarkers, 0)
end)

test('an entry can open a menu', function()
    local _, thread = loadInteractions()
    DAG.Menu.Register({ id = 'shop', title = 'Shop', options = { { title = 'Buy' } } })
    DAG.Interactions.Register({ id = 'a', coords = at(0.2, 0, 0), menu = 'shop' })

    harness.playerCoords = vector3(0, 0, 0)
    harness.controlsReleased[Config.InteractionKey] = true
    harness.runThread(thread)

    local opened = false
    for _, event in ipairs(harness.localEvents) do
        if event.event == 'chat:addMessage' then opened = true end
    end
    assertTrue(opened)
end)

-- A prompt anchored to a spawn point is wrong the moment the thing it belongs
-- to moves. Following an entity is what lets a fleeing suspect stay
-- interactable where they actually are.
test('an interaction follows the entity it is attached to', function()
    local DAG = harness.loadClient({ modules = { 'menu', 'interactions' } })
    local ped = 4242
    harness.entityCoords[ped] = vector3(100.0, 100.0, 0.0)

    DAG.Interactions.Register({
        id = 'follow-me',
        coords = vector3(0.0, 0.0, 0.0),
        follow = ped
    })

    local entry = DAG.Interactions.Get('follow-me')
    assertEq(DAG.Interactions.PositionOf(entry).x, 100.0, 'tracks the entity, not the registration')

    harness.entityCoords[ped] = vector3(250.0, 300.0, 0.0)
    assertEq(DAG.Interactions.PositionOf(entry).x, 250.0)
    assertEq(DAG.Interactions.PositionOf(entry).y, 300.0)
end)

test('a follow entity that no longer exists falls back to the registered spot', function()
    local DAG = harness.loadClient({ modules = { 'menu', 'interactions' } })
    DAG.Interactions.Register({
        id = 'gone',
        coords = vector3(7.0, 8.0, 9.0),
        follow = 0
    })

    local entry = DAG.Interactions.Get('gone')
    assertEq(DAG.Interactions.PositionOf(entry).x, 7.0, 'the entry does not vanish with the entity')
end)

test('the marker is drawn where the followed entity is', function()
    local DAG = harness.loadClient({ modules = { 'menu', 'interactions' } })
    local ped = 555
    harness.entityCoords[ped] = vector3(12.0, 0.0, 0.0)
    harness.playerCoords = vector3(10.0, 0.0, 0.0)

    DAG.Interactions.Register({ id = 'tracked', coords = vector3(0.0, 0.0, 0.0), follow = ped })
    harness.runThread(harness.threads[1], 1)

    local drawn = harness.drawnMarkers[#harness.drawnMarkers]
    assertEq(drawn.coords.x, 12.0)
end)
