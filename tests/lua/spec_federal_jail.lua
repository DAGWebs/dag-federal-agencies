-- Serving the sentence. The court used to pass sentence and stop.
local function loadJail()
    return harness.loadFederalServer({
        federal = { 'core', 'cad', 'uniforms', 'armory', 'actions', 'editor', 'court', 'jail' }
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

local function convict(playerSource, name)
    harness.identifiers[playerSource] = 'license:convict'
    harness.names[playerSource] = name or 'Sam Cole'
    harness.setJob(playerSource, 'unemployed', 0)
    harness.placePlayer(playerSource, zoneCoords('fib', 'duty'))
end

test('a sentence converts to bounded real time', function()
    loadJail()
    assertEq(DAG.Federal.Jail.Seconds(36), 720, '36 months at 20s each')
    assertEq(DAG.Federal.Jail.Seconds(0), 0)

    -- A life sentence is not a life sentence.
    assertEq(DAG.Federal.Jail.Seconds(9999), 3600, 'capped at the configured maximum')
end)

test('committing puts somebody inside with time to serve', function()
    loadJail()
    officer(1)
    convict(2)

    local record = DAG.Federal.Jail.Commit({
        identifier = 'license:convict', name = 'Sam Cole', months = 36, caseNumber = 'FIB-CR-0001'
    })
    assertEq(record.name, 'Sam Cole')
    assertEq(record.months, 36)
    assertTrue(DAG.Federal.Jail.Remaining('license:convict') > 700)
end)

test('a sentence with no custodial time is refused', function()
    loadJail()
    local _, message = DAG.Federal.Jail.Commit({ identifier = 'license:convict', months = 0 })
    assertEq(message, 'that sentence carries no custodial time')
end)

-- A second conviction while inside should add to what is left, not replace it.
test('a second committal runs consecutively', function()
    loadJail()
    DAG.Federal.Jail.Commit({ identifier = 'license:convict', name = 'Sam Cole', months = 12 })
    local first = DAG.Federal.Jail.Remaining('license:convict')

    DAG.Federal.Jail.Commit({ identifier = 'license:convict', name = 'Sam Cole', months = 12 })
    local second = DAG.Federal.Jail.Remaining('license:convict')

    assertTrue(second > first + 200, 'the second sentence was added, not substituted')
    assertEq(DAG.Federal.Jail.Record('license:convict').months, 24)
end)

-- The whole point: a guilty verdict now lands somewhere.
test('a court sentence puts the defendant in custody', function()
    loadJail()
    officer(1)
    -- The judge must not be the defendant: the court refuses that, correctly.
    harness.identifiers[2] = 'license:judge'
    harness.names[2] = 'Judge Amari'
    harness.setJob(2, 'judge', 0)
    harness.placePlayer(2, vector3(240.0, -1380.0, 39.5))

    local case = DAG.Federal.Court.File(1, {
        identifier = 'license:defendant', name = 'Sam Cole', charges = { 'Wire fraud' }
    })
    DAG.Federal.Court.TakeRole(2, case.id, 'judge')

    local stored = DAG.Federal.Court.Get(case.id)
    stored.stage = 'verdict'
    stored.verdict = 'guilty'
    DAG.Federal.Court.cases.save(stored.id, stored)
    DAG.Federal.Court.Sentence(2, case.id, nil, nil)

    local record = DAG.Federal.Jail.Record('license:defendant')
    assertTrue(record ~= nil, 'the sentence landed')
    assertEq(record.months, 36)
    assertEq(record.caseNumber, 'FIB-CR-0001')
end)

test('an acquittal puts nobody inside', function()
    loadJail()
    officer(1)
    local case = DAG.Federal.Court.File(1, {
        identifier = 'license:defendant', name = 'Sam Cole', charges = { 'Wire fraud' }
    })
    local stored = DAG.Federal.Court.Get(case.id)
    stored.stage = 'verdict'
    stored.verdict = 'not_guilty'
    DAG.Federal.Court.cases.save(stored.id, stored)
    DAG.Federal.Court.Progress(DAG.Federal.Court.Get(case.id))

    assertNil(DAG.Federal.Jail.Record('license:defendant'))
end)

-- Contraband comes back: taking it is a consequence, not a punishment.
test('contraband is held on booking and returned on release', function()
    loadJail()
    convict(2)
    DAG.Framework.AddItem(2, 'cocaine', 3)
    DAG.Framework.AddItem(2, 'sandwich', 2)
    harness.players = { 2 }

    DAG.Federal.Jail.Commit({ identifier = 'license:convict', name = 'Sam Cole', months = 12 })
    assertEq(DAG.Framework.GetItemCount(2, 'cocaine'), 0, 'taken')
    assertEq(DAG.Framework.GetItemCount(2, 'sandwich'), 2, 'not contraband, left alone')

    DAG.Federal.Jail.Release('license:convict', 'test')
    assertEq(DAG.Framework.GetItemCount(2, 'cocaine'), 3, 'returned')
end)

test('confiscation can be switched off', function()
    loadJail()
    Config.Federal.jail.confiscate = false
    convict(2)
    DAG.Framework.AddItem(2, 'cocaine', 3)
    harness.players = { 2 }

    DAG.Federal.Jail.Commit({ identifier = 'license:convict', name = 'Sam Cole', months = 12 })
    assertEq(DAG.Framework.GetItemCount(2, 'cocaine'), 3)
end)

test('an inmate who is online is delivered to the cells', function()
    loadJail()
    convict(2)
    harness.players = { 2 }
    harness.clientEvents = {}

    DAG.Federal.Jail.Commit({ identifier = 'license:convict', name = 'Sam Cole', months = 12 })

    local delivered = false
    for _, event in ipairs(harness.clientEvents) do
        if event.event:find('federal:jailed', 1, true) then
            delivered = true
            assertEq(event.target, 2)
            assertTrue(event.args[1].cells ~= nil)
        end
    end
    assertTrue(delivered)
end)

test('time served releases automatically', function()
    loadJail()
    convict(2)
    harness.players = { 2 }
    DAG.Federal.Jail.Commit({ identifier = 'license:convict', name = 'Sam Cole', months = 12 })

    assertEq(DAG.Federal.Jail.Tick(os.time()), 0, 'not yet')
    assertEq(DAG.Federal.Jail.Tick(os.time() + 100000), 1)
    assertNil(DAG.Federal.Jail.Record('license:convict'))
end)

test('an officer can release somebody early', function()
    loadJail()
    officer(1)
    DAG.Federal.Jail.Commit({ identifier = 'license:convict', name = 'Sam Cole', months = 36 })

    assertEq(DAG.Federal.Jail.ReleaseEarly(1, 'license:convict').name, 'Sam Cole')
    assertNil(DAG.Federal.Jail.Record('license:convict'))

    local _, message = DAG.Federal.Jail.ReleaseEarly(1, 'license:convict')
    assertEq(message, 'they are not in custody')
end)

test('a rank without actions.arrest cannot release anybody', function()
    loadJail()
    officer(1, 0)
    DAG.Federal.Jail.Commit({ identifier = 'license:convict', name = 'Sam Cole', months = 36 })

    assertNil(DAG.Federal.Jail.ReleaseEarly(1, 'license:convict'))
    assertTrue(DAG.Federal.Jail.Record('license:convict') ~= nil)
end)

test('work takes time off the sentence and is rate limited', function()
    loadJail()
    convict(2)
    harness.players = { 2 }
    DAG.Federal.Jail.Commit({ identifier = 'license:convict', name = 'Sam Cole', months = 36 })
    local before = DAG.Federal.Jail.Remaining('license:convict')

    local result = DAG.Federal.Jail.Labour(2)
    assertEq(result.reduced, 60)
    assertTrue(DAG.Federal.Jail.Remaining('license:convict') < before)

    local _, message = DAG.Federal.Jail.Labour(2)
    assertEq(message, 'you have only just finished a task')
end)

test('working off the last of a sentence releases the inmate', function()
    loadJail()
    convict(2)
    harness.players = { 2 }
    -- One month is 20 seconds; a single work detail is worth 60.
    DAG.Federal.Jail.Commit({ identifier = 'license:convict', name = 'Sam Cole', months = 1 })

    local result = DAG.Federal.Jail.Labour(2)
    assertTrue(result.released)
    assertNil(DAG.Federal.Jail.Record('license:convict'))
end)

test('somebody who is not inside cannot take a work detail', function()
    loadJail()
    convict(2)
    local _, message = DAG.Federal.Jail.Labour(2)
    assertEq(message, 'you are not in custody')
end)

-- Otherwise the obvious play is to disconnect for the whole sentence.
test('offline time counts by default', function()
    loadJail()
    convict(2)
    harness.players = { 2 }
    DAG.Federal.Jail.Commit({ identifier = 'license:convict', name = 'Sam Cole', months = 36 })

    local record = DAG.Federal.Jail.Record('license:convict')
    local releaseAt = record.releaseAt

    _G.source = 2
    TriggerEvent('playerDropped')
    _G.source = nil

    -- They come back much later; the clock kept running.
    local returned = DAG.Federal.Jail.Record('license:convict')
    returned.leftAt = os.time() - 600
    DAG.Federal.Jail.inmates.save('license:convict', returned)

    DAG.Federal.Jail.Resume(2)
    assertEq(DAG.Federal.Jail.Record('license:convict').releaseAt, releaseAt, 'unchanged')
end)

test('offline time can be made not to count', function()
    loadJail()
    Config.Federal.jail.serveOffline = false
    convict(2)
    harness.players = { 2 }
    DAG.Federal.Jail.Commit({ identifier = 'license:convict', name = 'Sam Cole', months = 36 })

    local record = DAG.Federal.Jail.Record('license:convict')
    local before = record.releaseAt
    record.leftAt = os.time() - 300
    DAG.Federal.Jail.inmates.save('license:convict', record)

    DAG.Federal.Jail.Resume(2)
    local after = DAG.Federal.Jail.Record('license:convict').releaseAt
    assertTrue(after >= before + 299, 'the clock was pushed back by the time away')
end)

test('somebody whose time ran out while away is released on return', function()
    loadJail()
    convict(2)
    harness.players = { 2 }
    DAG.Federal.Jail.Commit({ identifier = 'license:convict', name = 'Sam Cole', months = 1 })

    local record = DAG.Federal.Jail.Record('license:convict')
    record.releaseAt = os.time() - 10
    DAG.Federal.Jail.inmates.save('license:convict', record)

    DAG.Federal.Jail.Resume(2)
    assertNil(DAG.Federal.Jail.Record('license:convict'))
end)

test('the roster lists who is inside and how long is left', function()
    loadJail()
    DAG.Federal.Jail.Commit({ identifier = 'license:a', name = 'Short', months = 6 })
    DAG.Federal.Jail.Commit({ identifier = 'license:b', name = 'Long', months = 60 })

    local roster = DAG.Federal.Jail.Roster()
    assertEq(#roster, 2)
    assertEq(roster[1].name, 'Long', 'longest remaining first')
    assertTrue(roster[1].remaining > roster[2].remaining)
end)

test('a custody note is written to the citizen record', function()
    loadJail()
    officer(1)
    DAG.Federal.Jail.Commit({
        identifier = 'license:convict', name = 'Sam Cole', months = 36, caseNumber = 'FIB-CR-0001'
    })

    local record = DAG.Federal.CAD.LookupRecord(1, 'license:convict')
    assertTrue(#record.notes >= 1)
    assertTrue(tostring(record.notes[1].text):find('Committed to custody', 1, true) ~= nil)
end)

-- A server already running a jail resource must be able to turn this off
-- without losing the event their own script listens to.
test('the jail can be switched off while the sentencing event still fires', function()
    loadJail()
    Config.Federal.jail.enabled = false
    officer(1)

    local heard = false
    AddEventHandler(DAG.Federal.Net('sentenced'), function() heard = true end)
    TriggerEvent(DAG.Federal.Net('sentenced'), {
        identifier = 'license:convict', name = 'Sam Cole', months = 36
    })

    assertTrue(heard, 'another resource can still consume it')
    assertNil(DAG.Federal.Jail.Record('license:convict'), 'but this one stayed out of it')
end)
