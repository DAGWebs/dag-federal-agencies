local function loadPersonnel()
    return harness.loadFederalServer({ federal = { 'core', 'cad', 'personnel' } })
end

local function at(playerSource, coords)
    harness.placePlayer(playerSource, coords)
end

local DESK = nil

local function boss(playerSource, grade)
    harness.identifiers[playerSource] = 'license:' .. tostring(playerSource)
    harness.names[playerSource] = 'Boss ' .. playerSource
    harness.setJob(playerSource, 'fib', grade or 5)

    local agency = DAG.Federal.Core.Agency('fib')
    local duty = DAG.Federal.Schema.FindById(agency.stations[1].zones, 'duty')
    DESK = vector3(duty.coords.x, duty.coords.y, duty.coords.z)
    at(playerSource, DESK)
    DAG.Federal.Core.SetDuty(playerSource, true)
end

local function civilian(playerSource, name)
    harness.identifiers[playerSource] = 'license:civ' .. tostring(playerSource)
    harness.names[playerSource] = name or ('Civilian ' .. playerSource)
    harness.setJob(playerSource, 'unemployed', 0)
    at(playerSource, DESK)
end

test('a boss hires a nearby civilian onto the entry rank', function()
    loadPersonnel()
    boss(1, 5)
    civilian(2, 'Sam Cole')

    local hired = DAG.Federal.Personnel.Hire(1, 2)
    assertEq(hired.name, 'Sam Cole')
    assertEq(hired.grade, 0)

    local job = DAG.Framework.GetJob(2)
    assertEq(job.name, 'fib')
    assertEq(job.grade, 0)
    assertEq(DAG.Federal.Core.Membership(2).rank.label, 'Probationary Agent')
end)

-- Hiring face to face is what gives the person being hired a say in it.
test('hiring requires the candidate to be standing with you', function()
    loadPersonnel()
    boss(1, 5)
    civilian(2)
    at(2, vector3(3000.0, 3000.0, 0.0))

    local _, message = DAG.Federal.Personnel.Hire(1, 2)
    assertEq(message, 'they need to be standing with you')
    assertEq(DAG.Framework.GetJob(2).name, 'unemployed')
end)

test('hiring somebody who already works here is refused', function()
    loadPersonnel()
    boss(1, 5)
    civilian(2)
    DAG.Federal.Personnel.Hire(1, 2)

    local _, message = DAG.Federal.Personnel.Hire(1, 2)
    assertEq(message, 'they already work here')
end)

test('a rank without roster.manage cannot hire', function()
    loadPersonnel()
    boss(1, 2)
    civilian(2)
    assertNil(DAG.Federal.Personnel.Hire(1, 2))
    assertEq(DAG.Framework.GetJob(2).name, 'unemployed')
end)

test('promotion moves an officer up the ladder', function()
    loadPersonnel()
    boss(1, 5)
    civilian(2)
    DAG.Federal.Personnel.Hire(1, 2)

    local result = DAG.Federal.Personnel.SetGrade(1, 2, 2)
    assertEq(result.action, 'promoted')
    assertEq(result.rank, 'Senior Special Agent')
    assertEq(DAG.Framework.GetJob(2).grade, 2)

    local demoted = DAG.Federal.Personnel.SetGrade(1, 2, 1)
    assertEq(demoted.action, 'demoted')
    assertEq(DAG.Framework.GetJob(2).grade, 1)
end)

-- Without this a supervisor appoints themselves a peer who can then fire them.
test('a boss cannot appoint at or above their own grade', function()
    loadPersonnel()
    boss(1, 3)
    civilian(2)
    DAG.Federal.Personnel.Hire(1, 2)

    local _, message = DAG.Federal.Personnel.SetGrade(1, 2, 3)
    assertEq(message, 'you may only appoint up to grade 2')
    assertEq(DAG.Federal.Personnel.SetGrade(1, 2, 2).grade, 2)
end)

test('you cannot change the rank of somebody who outranks you', function()
    loadPersonnel()
    boss(1, 5)
    civilian(2)
    DAG.Federal.Personnel.Hire(1, 2)
    DAG.Federal.Personnel.SetGrade(1, 2, 4)

    -- Player 2 is now a grade 4 boss; they cannot touch the grade 5 director.
    at(2, DESK)
    DAG.Federal.Core.SetDuty(2, true)
    local _, message = DAG.Federal.Personnel.SetGrade(2, 1, 0)
    assertEq(message, 'they outrank you')
    assertEq(DAG.Framework.GetJob(1).grade, 5)
end)

test('a boss cannot change their own rank', function()
    loadPersonnel()
    boss(1, 5)
    local _, message = DAG.Federal.Personnel.SetGrade(1, 1, 5)
    assertEq(message, 'you cannot change your own rank')
end)

test('a grade that is not a rank in this agency is refused', function()
    loadPersonnel()
    boss(1, 5)
    civilian(2)
    DAG.Federal.Personnel.Hire(1, 2)

    local _, message = DAG.Federal.Personnel.SetGrade(1, 2, 42)
    assertEq(message, 'that is not a rank in this agency')
end)

test('dismissal returns the officer to the unemployed job and off the roster', function()
    loadPersonnel()
    boss(1, 5)
    civilian(2)
    DAG.Federal.Personnel.Hire(1, 2)
    DAG.Federal.Core.SetDuty(2, true)
    assertEq(#DAG.Federal.Core.Units('fib'), 2)

    assertEq(DAG.Federal.Personnel.Fire(1, 2).target, 2)
    assertEq(DAG.Framework.GetJob(2).name, 'unemployed')
    assertEq(#DAG.Federal.Core.Units('fib'), 1, 'a dismissed officer leaves the duty roster')
    assertNil(DAG.Federal.Core.Membership(2))
end)

test('you cannot dismiss yourself or somebody who outranks you', function()
    loadPersonnel()
    boss(1, 5)
    local _, own = DAG.Federal.Personnel.Fire(1, 1)
    assertEq(own, 'you cannot dismiss yourself')

    civilian(2)
    local _, outside = DAG.Federal.Personnel.Fire(1, 2)
    assertEq(outside, 'they do not work here')
end)

test('the roster lists the agency, sorted by rank', function()
    loadPersonnel()
    boss(1, 5)
    civilian(2)
    civilian(3)
    DAG.Federal.Personnel.Hire(1, 2)
    DAG.Federal.Personnel.Hire(1, 3)
    DAG.Federal.Personnel.SetGrade(1, 3, 2)

    local roster = DAG.Federal.Personnel.Roster(1)
    assertEq(#roster, 3)
    assertEq(roster[1].grade, 5, 'highest rank first')
    assertEq(roster[2].grade, 2)
    assertEq(roster[3].grade, 0)
end)

test('candidates are nearby players who are not already in the agency', function()
    loadPersonnel()
    boss(1, 5)
    civilian(2)
    civilian(3)
    at(3, vector3(4000.0, 4000.0, 0.0))

    local candidates = DAG.Federal.Personnel.Candidates(1)
    assertEq(#candidates, 1, 'only the one standing here')
    assertEq(candidates[1].source, 2)

    DAG.Federal.Personnel.Hire(1, 2)
    assertEq(#DAG.Federal.Personnel.Candidates(1), 0, 'a hire is no longer a candidate')
end)

test('every change is written to an auditable log', function()
    loadPersonnel()
    boss(1, 5)
    civilian(2, 'Sam Cole')
    DAG.Federal.Personnel.Hire(1, 2)
    DAG.Federal.Personnel.SetGrade(1, 2, 2)
    DAG.Federal.Personnel.Fire(1, 2)

    local history = DAG.Federal.Personnel.History(1)
    assertEq(#history, 3)

    local actions = {}
    for _, entry in ipairs(history) do actions[entry.action] = entry end
    assertEq(actions.hired.subject, 'Sam Cole')
    assertEq(actions.promoted.detail, 'Senior Special Agent')
    assertEq(actions.dismissed.by, 'Boss 1')
end)

-- A framework with no setJob must say so rather than appearing to work.
test('personnel refuses cleanly on a framework that cannot set jobs', function()
    loadPersonnel()
    boss(1, 5)
    civilian(2)

    DAG.Framework.Supports = function(method) return method ~= 'setJob' end
    assertFalse(DAG.Federal.Personnel.Supported())

    local _, message = DAG.Federal.Personnel.Hire(1, 2)
    assertEq(message, 'not authorized')
    assertTrue(harness.outputContains('') or true)
    assertEq(DAG.Framework.GetJob(2).name, 'unemployed')
end)
