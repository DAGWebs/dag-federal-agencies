-- Reports from the public. Callouts on a timer are the same seven cases
-- forever; this is the only source of work nobody planned.
local function loadReports()
    return harness.loadFederalServer({
        federal = { 'core', 'cad', 'uniforms', 'armory', 'actions', 'leads', 'callouts', 'reports' }
    })
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

local function caller(playerSource, name)
    harness.identifiers[playerSource] = 'license:civ' .. tostring(playerSource)
    harness.names[playerSource] = name or ('Civilian ' .. playerSource)
    harness.setJob(playerSource, 'unemployed', 0)
    harness.placePlayer(playerSource, vector3(500.0, -900.0, 25.0))
end

test('anybody can call something in', function()
    loadReports()
    officer(1)
    caller(2, 'Ali Novak')

    local report = DAG.Federal.Reports.Submit(2, { text = 'Two men loading crates into a van' })
    assertEq(report.caller, 'Ali Novak')
    assertEq(report.status, 'open')
    assertEq(report.location.x, 500.0, 'the position the server read, not one they sent')
end)

test('a report needs something said and somebody on duty to hear it', function()
    loadReports()
    caller(2)

    -- Nobody on duty anywhere.
    local _, empty = DAG.Federal.Reports.Submit(2, { text = 'Something is happening' })
    assertEq(empty, 'nobody is on duty to take that right now')

    officer(1)
    local _, blank = DAG.Federal.Reports.Submit(2, { text = '   ' })
    assertEq(blank, 'say what you are reporting')
end)

test('the caller can withhold their name but stays traceable server-side', function()
    loadReports()
    officer(1)
    caller(2, 'Ali Novak')

    local report = DAG.Federal.Reports.Submit(2, { text = 'A tip about a warehouse', anonymous = true })
    assertEq(report.caller, 'Anonymous')
    assertTrue(report.anonymous)

    -- Withheld from officers, kept for abuse tracing.
    assertEq(DAG.Federal.Reports.Get(report.id).callerIdentifier, 'license:civ2')
end)

test('anonymity can be switched off', function()
    loadReports()
    Config.Federal.reports.allowAnonymous = false
    officer(1)
    caller(2, 'Ali Novak')

    local report = DAG.Federal.Reports.Submit(2, { text = 'A tip', anonymous = true })
    assertEq(report.caller, 'Ali Novak')
    assertFalse(report.anonymous)
end)

-- Without a cooldown one player can bury the board.
test('a caller is rate limited between reports', function()
    loadReports()
    officer(1)
    caller(2)

    assertTrue(DAG.Federal.Reports.Submit(2, { text = 'First call' }) ~= nil)
    local _, message = DAG.Federal.Reports.Submit(2, { text = 'Second call' })
    assertEq(message, 'you have only just called that in')
    assertEq(DAG.Federal.Reports.Count(), 1)
end)

test('reporting can be restricted to particular jobs', function()
    loadReports()
    officer(1)
    caller(2)
    Config.Federal.reports.jobs = { 'security' }

    assertFalse(DAG.Federal.Reports.CanReport(2))
    local _, message = DAG.Federal.Reports.Submit(2, { text = 'A tip' })
    assertEq(message, 'you cannot call this in')

    harness.setJob(2, 'security', 0)
    assertTrue(DAG.Federal.Reports.CanReport(2))
end)

test('the line can be closed entirely', function()
    loadReports()
    Config.Federal.reports.enabled = false
    officer(1)
    caller(2)

    local _, message = DAG.Federal.Reports.Submit(2, { text = 'A tip' })
    assertEq(message, 'the tip line is closed')
end)

-- A phone call becoming a real case is the whole point.
test('a keyword in the report escalates it into a full callout', function()
    loadReports()
    officer(1)
    caller(2)

    local report = DAG.Federal.Reports.Submit(2, { text = 'I think someone is running a fraud out of that office' })
    assertEq(report.status, 'dispatched')
    assertTrue(report.calloutId ~= nil)

    local callouts = DAG.Federal.Callouts.Active(1)
    assertEq(#callouts, 1)
    assertEq(callouts[1].template, 'wire-fraud')
end)

test('a report with no keyword stays a plain report', function()
    loadReports()
    officer(1)
    caller(2)

    local report = DAG.Federal.Reports.Submit(2, { text = 'Someone is shouting in the street' })
    assertEq(report.status, 'open')
    assertNil(report.calloutId)
    assertEq(#DAG.Federal.Callouts.Active(1), 0)
end)

test('keyword matching is case insensitive and stable', function()
    loadReports()
    assertEq(DAG.Federal.Reports.Escalation('A COUNTERFEIT note'), 'counterfeit-passing')
    assertEq(DAG.Federal.Reports.Escalation('nothing relevant here'), nil)

    -- Two keywords present: the same text must always route the same way.
    local first = DAG.Federal.Reports.Escalation('a stolen gun')
    local second = DAG.Federal.Reports.Escalation('a stolen gun')
    assertEq(first, second)
end)

-- A call is never filed to an empty room.
test('a report routes to an agency that actually has units on duty', function()
    loadReports()
    officer(1, 'usss', 2)
    caller(2)

    -- 'fraud' is a FIB template, but only the Secret Service is working.
    local report = DAG.Federal.Reports.Submit(2, { text = 'possible fraud downtown' })
    assertEq(report.agency, 'usss')
    assertNil(report.calloutId, 'the FIB template does not apply to them')
end)

test('a keyword routes to the agency whose template it is when both are staffed', function()
    loadReports()
    officer(1, 'usss', 2)
    officer(3, 'fib', 2)
    caller(2)

    local report = DAG.Federal.Reports.Submit(2, { text = 'a fraud at the bank' })
    assertEq(report.agency, 'fib')
    assertTrue(report.calloutId ~= nil)
end)

test('the board only shows your own agency', function()
    loadReports()
    officer(1, 'fib', 2)
    officer(3, 'doa', 2)
    caller(2)
    DAG.Federal.Reports.Submit(2, { text = 'Something odd at the docks' })

    local board = DAG.Federal.Reports.Board(1)
    assertEq(#board, 1)
    assertEq(#DAG.Federal.Reports.Board(3), 0, 'the DOA was not the one called')
end)

test('officers are notified of a new report and can respond to it', function()
    loadReports()
    officer(1)
    officer(3)
    caller(2)
    harness.clientEvents = {}

    local report = DAG.Federal.Reports.Submit(2, { text = 'A break-in' })
    local told = {}
    for _, event in ipairs(harness.clientEvents) do
        if event.event:find('federal:report', 1, true) then told[event.target] = true end
    end
    assertTrue(told[1] and told[3], 'both on-duty officers heard it')

    assertEq(DAG.Federal.Reports.Acknowledge(1, report.id).status, 'responding')
end)

test('closing a report takes it off the board and thanks the caller', function()
    loadReports()
    officer(1)
    caller(2)
    local report = DAG.Federal.Reports.Submit(2, { text = 'A break-in' })

    assertEq(DAG.Federal.Reports.Close(1, report.id).status, 'closed')
    assertEq(#DAG.Federal.Reports.Board(1), 0)
    assertNil(DAG.Federal.Reports.Get(report.id))
end)

test('another agency cannot work your reports', function()
    loadReports()
    officer(1, 'fib', 2)
    officer(3, 'doa', 2)
    caller(2)
    local report = DAG.Federal.Reports.Submit(2, { text = 'A break-in' })

    local _, message = DAG.Federal.Reports.Acknowledge(3, report.id)
    assertEq(message, 'that report belongs to another agency')
end)

test('stale reports fall off the board', function()
    loadReports()
    officer(1)
    caller(2)
    DAG.Federal.Reports.Submit(2, { text = 'A break-in' })

    assertEq(DAG.Federal.Reports.Expire(os.time()), 0)
    assertEq(DAG.Federal.Reports.Expire(os.time() + 7200), 1)
    assertEq(DAG.Federal.Reports.Count(), 0)
end)

test('a caller who disconnects leaves the report standing', function()
    loadReports()
    officer(1)
    caller(2)
    local report = DAG.Federal.Reports.Submit(2, { text = 'A break-in' })

    _G.source = 2
    TriggerEvent('playerDropped')
    _G.source = nil

    assertEq(#DAG.Federal.Reports.Board(1), 1, 'the work does not vanish with the caller')
    assertNil(DAG.Federal.Reports.Get(report.id).callerSource)
end)
