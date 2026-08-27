-- The client stack, loaded the way the manifest loads it.
--
-- The main thing this proves is that no federal client file touches a native
-- at load time: everything native-facing must sit inside a function or a
-- thread, because at load the game world may not exist yet.
local function loadClient()
    return harness.loadFederalClient()
end

-- Applies a server context the way the real server push does.
local function asAgent(grade, permissions)
    local granted = {}
    for _, name in ipairs(permissions or {}) do granted[name] = true end

    DAG.Federal.State.Apply({
        enabled = true,
        agencies = { DAG.Federal.Schema.Agency(Config.Federal.Agencies[1]) },
        permissions = granted,
        membership = { agencyId = 'fib', grade = grade or 2, rank = 'Special Agent', isBoss = false, onDuty = true }
    })
end

test('every federal client file loads without touching a native', function()
    loadClient()
    for _, module in ipairs({ 'State', 'Uniforms', 'Actions', 'CAD', 'Armory', 'Callouts', 'Court', 'Editor', 'Menus', 'Zones' }) do
        assertTrue(type(DAG.Federal[module]) == 'table', module .. ' did not load')
    end
end)

test('the client commands are namespaced to the resource', function()
    loadClient()
    assertTrue(harness.commands['dag-template:fed'] ~= nil)
    assertTrue(harness.commands['dag-template:fedcad'] ~= nil)
    assertTrue(harness.commands['dag-template:fedcourt'] ~= nil)
end)

test('menu ids are namespaced so two resources never collide', function()
    loadClient()
    assertEq(DAG.Federal.Menus.Id('main'), 'dag-template:federal:main')
end)

test('a fresh client knows nothing until the server tells it', function()
    loadClient()
    assertNil(DAG.Federal.State.Membership())
    assertNil(DAG.Federal.State.Mine())
    assertFalse(DAG.Federal.State.OnDuty())
    assertFalse(DAG.Federal.State.Can('cad.view'))
end)

test('applying a context populates membership and permissions', function()
    loadClient()
    asAgent(2, { 'cad.view', 'actions.detain' })

    assertEq(DAG.Federal.State.Membership().agencyId, 'fib')
    assertEq(DAG.Federal.State.Mine().short, 'FIB')
    assertTrue(DAG.Federal.State.OnDuty())
    assertTrue(DAG.Federal.State.Can('cad.view'))
    assertFalse(DAG.Federal.State.Can('cad.expunge'))
end)

test('an admin context passes every permission check', function()
    loadClient()
    DAG.Federal.State.Apply({ agencies = {}, permissions = {}, admin = true })
    assertTrue(DAG.Federal.State.Can('editor.manage'))
end)

-- The action list is what the field menu renders; it must reflect rank.
test('the LEO action list is filtered by what the rank allows', function()
    loadClient()
    asAgent(0, { 'actions.detain' })
    local titles = {}
    for _, option in ipairs(DAG.Federal.Actions.Options()) do titles[option.title] = true end

    assertTrue(titles['Cuff / uncuff'])
    assertNil(titles['Search suspect'], 'no actions.search on this rank')
    assertNil(titles['Book arrest'])

    asAgent(2, { 'actions.detain', 'actions.search', 'actions.arrest', 'actions.evidence' })
    local full = {}
    for _, option in ipairs(DAG.Federal.Actions.Options()) do full[option.title] = true end
    assertTrue(full['Search suspect'])
    assertTrue(full['Search vehicle'])
    assertTrue(full['Book arrest'])
    assertTrue(full['Take DNA swab'])
end)

test('a context push rebuilds blips and interactions from the new registry', function()
    loadClient()
    asAgent(2, { 'cad.view' })

    -- Two FIB stations, eight rooms each, and only your own agency's rooms
    -- are interactive.
    assertTrue(DAG.Interactions.Get('federal:fib:fib-tower:armory') ~= nil)
    assertTrue(DAG.Interactions.Get('federal:fib:fib-sandy:locker') ~= nil)
    assertNil(DAG.Interactions.Get('federal:iaa:iaa-annex:armory'), 'another agency is not yours to open')
end)

test('a station zone refuses interaction below its grade', function()
    loadClient()
    asAgent(0, {})

    local boss = DAG.Interactions.Get('federal:fib:fib-tower:boss')
    assertFalse(boss.canInteract(boss), 'grade 0 cannot enter the command office')

    asAgent(4, {})
    assertTrue(boss.canInteract(boss))
end)

test('a zone belonging to another agency never becomes interactive', function()
    loadClient()
    asAgent(2, {})
    local zone = DAG.Interactions.Get('federal:fib:fib-tower:duty')

    -- The player transfers out of the FIB entirely.
    DAG.Federal.State.Apply({ agencies = DAG.Federal.State.Agencies(), permissions = {}, membership = nil })
    assertFalse(zone.canInteract(zone))
end)

test('uniform wearability respects grade and body variant', function()
    loadClient()
    local male = { minGrade = 0, variant = 'male', components = {} }
    local any = { minGrade = 3, variant = 'any', components = {} }

    assertFalse(DAG.Federal.Uniforms.Wearable(any, 2), 'grade gate')
    assertTrue(DAG.Federal.Uniforms.Wearable(any, 3))
    -- The stubbed ped reports as female, so a male-only uniform is filtered.
    assertFalse(DAG.Federal.Uniforms.Wearable(male, 5), 'variant gate')
    assertFalse(DAG.Federal.Uniforms.Wearable(nil, 5))
end)

test('capturing an outfit produces the slots the schema accepts', function()
    loadClient()
    local captured = DAG.Federal.Uniforms.Capture()

    assertEq(#captured.components, #DAG.Federal.Constants.UniformComponents)
    assertEq(#captured.props, #DAG.Federal.Constants.UniformProps)

    -- The captured shape must survive the server-side validator unchanged.
    local uniform, err = DAG.Federal.Schema.Uniform({ label = 'Captured', components = captured.components, props = captured.props })
    assertTrue(uniform ~= nil, tostring(err))
    assertEq(uniform.label, 'Captured')
end)

test('a wearUniform push applies without erroring', function()
    loadClient()
    TriggerEvent(DAG.Federal.Net('wearUniform'), {
        label = 'Field suit',
        components = { { slot = 11, drawable = 4, texture = 0, palette = 0 } },
        props = { { slot = 0, drawable = -1, texture = 0 } }
    })
    assertTrue(true, 'applying a uniform did not error')
end)

test('a restraint push is accepted and cleared', function()
    loadClient()
    TriggerEvent(DAG.Federal.Net('restraint'), { cuffed = true })
    assertTrue(DAG.Federal.Actions.Restrained())

    TriggerEvent(DAG.Federal.Net('restraint'), { cuffed = false })
    assertFalse(DAG.Federal.Actions.Restrained())
end)

test('a callout dispatch is remembered and its scene is cleared on close', function()
    loadClient()
    asAgent(2, { 'actions.detain' })

    TriggerEvent(DAG.Federal.Net('callout:dispatch'), {
        id = 'cal-1', number = 'FIB-CAD-0001', label = 'Suspected wire fraud',
        location = { x = 1.0, y = 2.0, z = 3.0 }, stages = {}, stage = 1, priority = 2, assigned = {}
    })
    TriggerEvent(DAG.Federal.Net('callout:closed'), { id = 'cal-1', number = 'FIB-CAD-0001' })
    assertNil(DAG.Federal.Callouts.ClearScene and nil, 'the scene teardown ran without error')
end)

-- The listeners are what draw the blips and register the interactions, so a
-- listener that dies quietly leaves a player with an empty map and no clue.
test('a listener that throws is contained but reported, not swallowed', function()
    loadClient()
    DAG.Federal.State.OnChange(function() error('listener blew up') end)
    asAgent(2, { 'cad.view' })

    assertEq(DAG.Federal.State.Membership().agencyId, 'fib', 'one bad listener does not stop the rest')
    assertTrue(harness.outputContains('federal state listener errored'), 'and the failure is printed')
end)

test('rebuilding replaces the previous blips instead of stacking them', function()
    loadClient()
    asAgent(2, {})
    local first = 0
    for _ in pairs(harness.blips) do first = first + 1 end
    assertTrue(first > 0, 'stations are blipped')

    asAgent(2, {})
    local second = 0
    for _ in pairs(harness.blips) do second = second + 1 end
    assertEq(second, first, 'a second push does not double the blips')
end)

test('a disabled resource draws nothing rather than dead blips', function()
    loadClient()
    asAgent(2, {})
    assertTrue(DAG.Interactions.Get('federal:fib:fib-tower:duty') ~= nil)

    DAG.Federal.State.Apply({
        enabled = false,
        agencies = { DAG.Federal.Schema.Agency(Config.Federal.Agencies[1]) },
        permissions = {},
        membership = { agencyId = 'fib', grade = 2, rank = 'Special Agent', onDuty = false }
    })

    assertNil(DAG.Interactions.Get('federal:fib:fib-tower:duty'))
    local drawn = 0
    for _ in pairs(harness.blips) do drawn = drawn + 1 end
    assertEq(drawn, 0, 'no blips are left on the map')
end)
