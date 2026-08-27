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

-- Timed actions ---------------------------------------------------------------

test('a timed action runs the bar and reports completion', function()
    loadClient()
    local completed, sent
    harness.runThread(function()
        -- Captured inside the thread: runThread clears the NUI log on the way
        -- out, and this table reference survives that reset.
        sent = harness.nuiMessages
        completed = DAG.Federal.Progress.Run({ label = 'Searching', duration = 1000, animation = 'search' })
    end, 200)

    assertTrue(completed)
    local opened, closed = false, false
    for _, message in ipairs(sent) do
        if message.action == 'progress:open' then
            opened = true
            assertEq(message.label, 'Searching')
            assertEq(message.duration, 1000)
        end
        if message.action == 'progress:close' then closed = true end
    end
    assertTrue(opened, 'the bar was shown')
    assertTrue(closed, 'and taken down again')
end)

test('a timed action is cancelled by the cancel key', function()
    loadClient()
    harness.controlsReleased[202] = true

    local completed
    harness.runThread(function()
        completed = DAG.Federal.Progress.Run({ label = 'Searching', duration = 10000 })
    end, 200)

    assertFalse(completed)
    assertFalse(DAG.Federal.Progress.Active(), 'and the lock is released')
end)

-- Being cuffed or killed mid-action means you are no longer in a position to
-- be doing it, so the action ends rather than completing anyway.
test('being restrained mid-action interrupts it', function()
    loadClient()
    TriggerEvent(DAG.Federal.Net('restraint'), { cuffed = true })

    local completed
    harness.runThread(function()
        completed = DAG.Federal.Progress.Run({ label = 'Searching', duration = 10000 })
    end, 200)
    assertFalse(completed)
end)

test('dying mid-action interrupts it', function()
    loadClient()
    harness.pedIsDead = true

    local completed
    harness.runThread(function()
        completed = DAG.Federal.Progress.Run({ label = 'Searching', duration = 10000 })
    end, 200)
    assertFalse(completed)
end)

-- A leaked lock would leave the player unable to perform any action for the
-- rest of the session, so it has to survive the bar throwing.
test('the action lock is released even when the bar is torn down mid-run', function()
    loadClient()
    assertFalse(DAG.Federal.Progress.Active())

    -- The wait budget runs out mid-bar, which unwinds the loop the way an
    -- error inside it would.
    harness.runThread(function()
        DAG.Federal.Progress.Run({ label = 'Interrupted', duration = 100000 })
    end, 3)

    assertFalse(DAG.Federal.Progress.Active(), 'the lock did not leak')

    -- And the next action still works.
    local completed
    harness.runThread(function()
        completed = DAG.Federal.Progress.Run({ label = 'Next', duration = 300 })
    end, 200)
    assertTrue(completed)
end)

test('a zero duration skips the bar entirely', function()
    loadClient()
    Config.Federal.timings.search = 0
    -- timedOnTarget short-circuits, so no NUI message is produced at all.
    assertTrue(DAG.Federal.Actions.TimedOnTarget(1, 'Searching', 'search', 'search'))
    assertEq(#harness.nuiMessages, 0)
end)

-- A suspect who walked off mid-search has not been searched.
test('a target that moved away during the bar fails the action', function()
    loadClient()
    Config.Federal.timings.search = 500
    harness.activePlayers = {}

    local ok
    harness.runThread(function()
        ok = DAG.Federal.Actions.TimedOnTarget(99, 'Searching', 'search', 'search')
    end, 200)
    assertFalse(ok, 'the target is no longer the nearest player')
end)

test('a skill check passes through when no provider can run one', function()
    loadClient()
    assertTrue(DAG.Federal.Progress.SkillCheck({ 'easy' }), 'no ox_lib means no gate')
end)

test('every named animation resolves to a dictionary and clip', function()
    loadClient()
    for name, animation in pairs(DAG.Federal.Progress.Animations) do
        assertTrue(type(animation.dict) == 'string' and animation.dict ~= '', name .. ' dict')
        assertTrue(type(animation.clip) == 'string' and animation.clip ~= '', name .. ' clip')
    end
end)

-- HUD ---------------------------------------------------------------------------

test('the HUD stays hidden for somebody who is not in an agency', function()
    loadClient()
    assertFalse(DAG.Federal.Hud.Build().visible)
end)

-- Off duty it would be clutter on a civilian's screen.
test('the HUD is hidden off duty unless the server asks for it', function()
    loadClient()
    DAG.Federal.State.Apply({
        agencies = { DAG.Federal.Schema.Agency(Config.Federal.Agencies[1]) },
        permissions = {},
        membership = { agencyId = 'fib', grade = 2, rank = 'Special Agent', onDuty = false }
    })
    assertFalse(DAG.Federal.Hud.Build().visible)

    Config.Federal.hud.offDuty = true
    assertTrue(DAG.Federal.Hud.Build().visible)
end)

test('the HUD shows the unit, rank and status of an on-duty officer', function()
    loadClient()
    asAgent(2, {})
    DAG.Federal.State.Apply({
        agencies = { DAG.Federal.Schema.Agency(Config.Federal.Agencies[1]) },
        permissions = {},
        membership = {
            agencyId = 'fib', grade = 2, rank = 'Senior Special Agent', onDuty = true,
            unit = { callsign = 'ALPHA-1', status = 'enroute' }
        }
    })

    local hud = DAG.Federal.Hud.Build()
    assertTrue(hud.visible)
    assertEq(hud.agency, 'FIB')
    assertEq(hud.callsign, 'ALPHA-1')
    assertEq(hud.rank, 'Senior Special Agent')
    assertEq(hud.status, 'En route')
    assertEq(hud.statusTone, 'accent')
end)

test('the HUD reflects being restrained', function()
    loadClient()
    asAgent(2, {})
    assertFalse(DAG.Federal.Hud.Build().restrained)

    TriggerEvent(DAG.Federal.Net('restraint'), { cuffed = true })
    assertTrue(DAG.Federal.Hud.Build().restrained)
end)

test('the objective list marks done, current and pending', function()
    loadClient()
    local stages = {
        { label = 'Arrive' }, { label = 'Interview' }, { label = 'Evidence' }, { label = 'Arrest' }
    }
    local list = DAG.Federal.Hud.Objectives({ stages = stages, stage = 3 })

    local byLabel = {}
    for _, entry in ipairs(list) do byLabel[entry.label] = entry.state end
    assertEq(byLabel['Interview'], 'done')
    assertEq(byLabel['Evidence'], 'current')
    assertEq(byLabel['Arrest'], 'pending')
end)

-- A ten-stage case would otherwise fill the screen.
test('the objective list is windowed around the current stage', function()
    loadClient()
    local stages = {}
    for index = 1, 10 do stages[index] = { label = 'Stage ' .. index } end

    local list = DAG.Federal.Hud.Objectives({ stages = stages, stage = 7 })
    assertEq(#list, 4, 'capped at the configured window')
    assertEq(list[1].label, 'Stage 6', 'starting one before the current objective')
    assertEq(list[2].state, 'current')
end)

test('an attached callout appears on the HUD and clears when it closes', function()
    loadClient()
    asAgent(2, { 'actions.detain' })
    DAG.Federal.State.Apply({
        agencies = { DAG.Federal.Schema.Agency(Config.Federal.Agencies[1]) },
        permissions = {},
        membership = {
            agencyId = 'fib', grade = 2, rank = 'Senior Special Agent', onDuty = true,
            unit = { callsign = 'ALPHA-1', status = 'onscene' }
        }
    })

    local me = GetPlayerServerId(PlayerId())
    DAG.Federal.Callouts.Track({
        id = 'cal-1', number = 'FIB-CAD-0001', label = 'Suspected wire fraud',
        stage = 2, assigned = { me }, location = { x = 0.0, y = 0.0, z = 0.0 },
        stages = { { id = 'arrive', label = 'Arrive' }, { id = 'interview', label = 'Interview the witness' } }
    })

    local hud = DAG.Federal.Hud.Build()
    assertEq(hud.callout.number, 'FIB-CAD-0001')
    assertEq(hud.callout.objectives[2].state, 'current')

    TriggerEvent(DAG.Federal.Net('callout:closed'), { id = 'cal-1', number = 'FIB-CAD-0001' })
    assertNil(DAG.Federal.Hud.Build().callout, 'the closed callout left the HUD')
end)

test('a callout somebody else is on does not appear on your HUD', function()
    loadClient()
    asAgent(2, { 'actions.detain' })
    DAG.Federal.Callouts.Track({
        id = 'cal-2', number = 'FIB-CAD-0002', label = 'Not yours',
        stage = 1, assigned = { 999 }, location = { x = 0.0, y = 0.0, z = 0.0 }, stages = {}
    })
    assertNil(DAG.Federal.Hud.Build().callout)
end)

-- Pushing an identical frame every second is pure noise across the boundary.
test('the HUD only pushes when something actually changed', function()
    loadClient()
    asAgent(2, {})
    DAG.Federal.Hud.Refresh()

    harness.nuiMessages = {}
    assertFalse(DAG.Federal.Hud.Refresh(), 'nothing changed')
    assertEq(#harness.nuiMessages, 0)

    TriggerEvent(DAG.Federal.Net('restraint'), { cuffed = true })
    assertTrue(#harness.nuiMessages > 0, 'a real change is pushed')
end)

test('the HUD can be switched off entirely', function()
    loadClient()
    asAgent(2, {})
    Config.Federal.hud.enabled = false
    assertFalse(DAG.Federal.Hud.Build().visible)
end)

-- Unit blips -----------------------------------------------------------------

local function onDuty(status)
    DAG.Federal.State.Apply({
        agencies = { DAG.Federal.Schema.Agency(Config.Federal.Agencies[1]) },
        permissions = {},
        membership = {
            agencyId = 'fib', grade = 2, rank = 'Senior Special Agent', onDuty = true,
            unit = { callsign = 'ALPHA-1', status = status or 'available' }
        }
    })
end

test('a unit push draws one blip per colleague', function()
    loadClient()
    onDuty()
    DAG.Federal.Units.Apply({
        { source = 2, callsign = 'BRAVO-2', name = 'Agent 2', status = 'enroute',
          coords = { x = 10.0, y = 20.0, z = 30.0 } },
        { source = 3, callsign = 'CHARLIE-3', name = 'Agent 3', status = 'onscene',
          coords = { x = 40.0, y = 50.0, z = 60.0 } }
    })

    local drawn = DAG.Federal.Units.Blips()
    assertTrue(drawn[2] ~= nil and drawn[3] ~= nil)
    assertEq(harness.blips[drawn[2]].colour, DAG.Federal.Units.StatusColour.enroute)
    assertEq(harness.blips[drawn[3]].coords.x, 40.0)
end)

-- Recreating the blip every interval would make it flicker.
test('a repeated push moves the existing blip instead of making a new one', function()
    loadClient()
    onDuty()
    DAG.Federal.Units.Apply({
        { source = 2, callsign = 'BRAVO-2', name = 'Agent 2', status = 'available',
          coords = { x = 10.0, y = 20.0, z = 30.0 } }
    })
    local first = DAG.Federal.Units.Blips()[2]

    DAG.Federal.Units.Apply({
        { source = 2, callsign = 'BRAVO-2', name = 'Agent 2', status = 'busy',
          coords = { x = 99.0, y = 20.0, z = 30.0 } }
    })
    assertEq(DAG.Federal.Units.Blips()[2], first, 'same blip')
    assertEq(harness.blips[first].coords.x, 99.0, 'moved')
    assertEq(harness.blips[first].colour, DAG.Federal.Units.StatusColour.busy)
end)

test('a unit that drops out of the push loses its blip', function()
    loadClient()
    onDuty()
    DAG.Federal.Units.Apply({
        { source = 2, callsign = 'B', name = 'Two', status = 'available', coords = { x = 1.0, y = 1.0, z = 1.0 } },
        { source = 3, callsign = 'C', name = 'Three', status = 'available', coords = { x = 2.0, y = 2.0, z = 2.0 } }
    })

    DAG.Federal.Units.Apply({
        { source = 2, callsign = 'B', name = 'Two', status = 'available', coords = { x = 1.0, y = 1.0, z = 1.0 } }
    })
    assertTrue(DAG.Federal.Units.Blips()[2] ~= nil)
    assertNil(DAG.Federal.Units.Blips()[3], 'they went off duty')
end)

test('a panicking unit flashes and is drawn larger', function()
    loadClient()
    onDuty()
    DAG.Federal.Units.Apply({
        { source = 2, callsign = 'B', name = 'Two', status = 'panic', panic = true,
          coords = { x = 1.0, y = 1.0, z = 1.0 } }
    })

    local blip = DAG.Federal.Units.Blips()[2]
    assertTrue(harness.blips[blip].flashing)
    assertEq(harness.blips[blip].scale, 1.0)
    assertEq(harness.blips[blip].colour, DAG.Federal.Units.StatusColour.panic)
end)

test('a panic alert drops a routed beacon that clears on demand', function()
    loadClient()
    onDuty()
    TriggerEvent(DAG.Federal.Net('panic'), {
        source = 2, name = 'Agent 2', callsign = 'BRAVO-2', coords = { x = 5.0, y = 6.0, z = 7.0 }
    })

    local beacon = DAG.Federal.Units.Panicking()[2]
    assertTrue(beacon ~= nil)
    assertTrue(harness.blips[beacon].flashing)
    assertTrue(harness.blips[beacon].route)

    TriggerEvent(DAG.Federal.Net('panic:clear'), 2)
    assertNil(DAG.Federal.Units.Panicking()[2])
end)

-- Leaving them up would show a civilian where every federal unit is.
test('going off duty clears every unit blip', function()
    loadClient()
    onDuty()
    DAG.Federal.Units.Apply({
        { source = 2, callsign = 'B', name = 'Two', status = 'available', coords = { x = 1.0, y = 1.0, z = 1.0 } }
    })
    assertTrue(DAG.Federal.Units.Blips()[2] ~= nil)

    DAG.Federal.State.Apply({ agencies = {}, permissions = {}, membership = nil })
    assertNil(DAG.Federal.Units.Blips()[2])
end)

test('the status menu offers panic separately from the ordinary statuses', function()
    loadClient()
    onDuty()
    local titles = {}
    for _, option in ipairs(DAG.Federal.Units.StatusOptions()) do titles[option.title] = true end

    assertTrue(titles['Available'])
    assertTrue(titles['En route'])
    assertTrue(titles['Panic button'])
    assertNil(titles['Panic'], 'not offered as an ordinary status')
end)
