local function loadCourt()
    return harness.loadFederalServer({
        federal = { 'core', 'cad', 'uniforms', 'armory', 'actions', 'editor', 'court' }
    })
end

local function player(playerSource, jobName, grade, name)
    harness.identifiers[playerSource] = 'license:' .. tostring(playerSource)
    harness.names[playerSource] = name or ('Player ' .. playerSource)
    harness.setJob(playerSource, jobName, grade or 0)
    harness.placePlayer(playerSource, vector3(240.0, -1380.0, 39.5))
end

local function agent(playerSource, grade)
    local agency = DAG.Federal.Core.Agency('fib')
    local duty = DAG.Federal.Schema.FindById(agency.stations[1].zones, 'duty')
    player(playerSource, 'fib', grade or 2, 'Agent ' .. playerSource)
    harness.placePlayer(playerSource, vector3(duty.coords.x, duty.coords.y, duty.coords.z))
    DAG.Federal.Core.SetDuty(playerSource, true)
end

local function fileCase(filer, chargeList)
    return DAG.Federal.Court.File(filer, {
        identifier = 'license:defendant',
        name = 'Sam Cole',
        charges = chargeList or { 'Wire fraud' }
    })
end

test('the configured courthouses load with a full set of seats', function()
    loadCourt()
    local houses = DAG.Federal.Court.Courthouses()
    assertEq(#houses, 2)

    local seats = DAG.Federal.Schema.SeatsFor(houses[1], 'jury')
    assertEq(#seats, 6, 'six jury seats')
    assertEq(#DAG.Federal.Schema.SeatsFor(houses[1], 'judge'), 1, 'exactly one bench')
    assertEq(#DAG.Federal.Schema.SeatsFor(houses[1], 'gallery'), 4)
end)

-- The point of the job list: the court is not federal-only.
test('any job named in filingJobs can start a case', function()
    loadCourt()
    agent(1, 2)
    player(2, 'police', 3)
    player(3, 'mechanic', 0)

    assertTrue(DAG.Federal.Court.CanFile(1), 'a federal agent')
    assertTrue(DAG.Federal.Court.CanFile(2), 'police, because the config lists it')
    assertFalse(DAG.Federal.Court.CanFile(3), 'a mechanic cannot')

    assertEq(fileCase(2).filedBy.job, 'police')
    local _, message = fileCase(3)
    assertEq(message, 'your job cannot file a case')
end)

test('adding a job to the config extends the court to it', function()
    loadCourt()
    player(1, 'parkranger', 0)
    assertFalse(DAG.Federal.Court.CanFile(1))

    Config.Federal.court.filingJobs[#Config.Federal.court.filingJobs + 1] = 'parkranger'
    assertTrue(DAG.Federal.Court.CanFile(1))
    assertEq(fileCase(1).charges[1], 'Wire fraud')
end)

test('a case needs a defendant and at least one charge', function()
    loadCourt()
    agent(1, 2)
    local _, noSubject = DAG.Federal.Court.File(1, { charges = { 'Wire fraud' } })
    assertEq(noSubject, 'a case requires a defendant identifier')

    local _, noCharges = DAG.Federal.Court.File(1, { identifier = 'license:x', charges = {} })
    assertEq(noCharges, 'a case requires at least one charge')
end)

-- Two filers who both fall back to the CRT prefix must not collide.
test('case numbers and ids are unique across different filing jobs', function()
    loadCourt()
    agent(1, 2)
    player(2, 'police', 0)
    player(3, 'sheriff', 0)

    local federal = fileCase(1)
    local police = fileCase(2)
    local sheriff = fileCase(3)

    assertEq(federal.number, 'FIB-CR-0001')
    assertEq(police.number, 'CRT-CR-0001')
    assertEq(sheriff.number, 'CRT-CR-0002', 'the two non-agency filers share one counter')
    assertTrue(federal.id ~= police.id and police.id ~= sheriff.id, 'ids are distinct')
end)

test('an arrest files a case automatically when configured', function()
    loadCourt()
    agent(1, 2)
    player(2, 'unemployed', 0, 'Sam Cole')
    local agency = DAG.Federal.Core.Agency('fib')
    local duty = DAG.Federal.Schema.FindById(agency.stations[1].zones, 'duty')
    harness.placePlayer(2, vector3(duty.coords.x, duty.coords.y, duty.coords.z))

    DAG.Federal.Actions.Cuff(1, 2)
    local booking = DAG.Federal.Actions.Arrest(1, 2, { charges = { 'Wire fraud', 'Identity theft' } })

    assertEq(booking.caseNumber, 'FIB-CR-0001')
    assertEq(#DAG.Federal.Court.Docket(1), 1)
end)

test('auto-filing can be switched off', function()
    loadCourt()
    Config.Federal.court.autoFileOnArrest = false
    agent(1, 2)
    player(2, 'unemployed', 0)
    local agency = DAG.Federal.Core.Agency('fib')
    local duty = DAG.Federal.Schema.FindById(agency.stations[1].zones, 'duty')
    harness.placePlayer(2, vector3(duty.coords.x, duty.coords.y, duty.coords.z))

    DAG.Federal.Actions.Cuff(1, 2)
    assertNil(DAG.Federal.Actions.Arrest(1, 2, { charges = { 'Wire fraud' } }).caseNumber)
    assertEq(#DAG.Federal.Court.Docket(1), 0)
end)

-- A case that cannot start because nobody logged in is the failure the NPC
-- judge exists to prevent.
test('with no judge online an NPC judge is appointed', function()
    loadCourt()
    agent(1, 2)
    local case = fileCase(1)
    assertTrue(case.roles.judge.npc, 'an NPC took the bench')
    assertTrue(type(case.roles.judge.model) == 'string', 'with a ped model to spawn')
end)

test('with a real judge online the bench is left for them to take', function()
    loadCourt()
    agent(1, 2)
    player(2, 'judge', 0, 'Judge Amari')

    local case = fileCase(1)
    assertNil(case.roles.judge, 'no NPC is appointed while a judge is online')

    assertEq(DAG.Federal.Court.TakeRole(2, case.id, 'judge').name, 'Judge Amari')
    assertFalse(DAG.Federal.Court.Get(case.id).roles.judge.npc)
end)

test('a real judge displaces an NPC that already took the bench', function()
    loadCourt()
    agent(1, 2)
    local case = fileCase(1)
    assertTrue(DAG.Federal.Court.Get(case.id).roles.judge.npc)

    player(2, 'judge', 0, 'Judge Amari')
    assertEq(DAG.Federal.Court.TakeRole(2, case.id, 'judge').name, 'Judge Amari')
    assertFalse(DAG.Federal.Court.Get(case.id).roles.judge.npc)
end)

test('role eligibility follows the configured job lists', function()
    loadCourt()
    agent(1, 2)
    local case = fileCase(1)

    player(2, 'mechanic', 0)
    local _, message = DAG.Federal.Court.TakeRole(2, case.id, 'judge')
    assertEq(message, 'you are not eligible for that role')

    player(3, 'lawyer', 0, 'Robin Vance')
    assertEq(DAG.Federal.Court.TakeRole(3, case.id, 'defense').name, 'Robin Vance')

    -- A mechanic is still allowed on the jury: jury service is not a job.
    assertEq(DAG.Federal.Court.TakeRole(2, case.id, 'juror').name, 'Player 2')
end)

test('the defendant cannot take a role in their own case', function()
    loadCourt()
    agent(1, 2)
    local case = fileCase(1)

    harness.identifiers[4] = 'license:defendant'
    harness.names[4] = 'Sam Cole'
    harness.setJob(4, 'lawyer', 0)
    harness.placePlayer(4, vector3(240.0, -1380.0, 39.5))

    local _, message = DAG.Federal.Court.TakeRole(4, case.id, 'defense')
    assertEq(message, 'you are not eligible for that role')
end)

test('officers of the filing job are kept off the jury', function()
    loadCourt()
    agent(1, 2)
    local case = fileCase(1)

    agent(2, 1)
    local _, message = DAG.Federal.Court.TakeRole(2, case.id, 'juror')
    assertEq(message, 'you are not eligible for that role')
end)

test('the jury box fills and then refuses', function()
    loadCourt()
    agent(1, 2)
    local case = fileCase(1)
    Config.Federal.court.jury.size = 2

    player(10, 'mechanic', 0)
    player(11, 'mechanic', 0)
    player(12, 'mechanic', 0)
    DAG.Federal.Court.TakeRole(10, case.id, 'juror')
    DAG.Federal.Court.TakeRole(11, case.id, 'juror')

    local _, message = DAG.Federal.Court.TakeRole(12, case.id, 'juror')
    assertEq(message, 'the jury box is full')

    local _, duplicate = DAG.Federal.Court.TakeRole(10, case.id, 'juror')
    assertEq(duplicate, 'you are already on this jury')
end)

test('a plea is entered at arraignment by the defendant or their counsel', function()
    loadCourt()
    agent(1, 2)
    local case = fileCase(1)

    local _, early = DAG.Federal.Court.Plea(1, case.id, 'not_guilty')
    assertEq(early, 'a plea is entered at arraignment')

    DAG.Federal.Court.Progress(DAG.Federal.Court.Get(case.id))
    assertEq(DAG.Federal.Court.Get(case.id).stage, 'arraignment')

    local _, wrongPerson = DAG.Federal.Court.Plea(1, case.id, 'not_guilty')
    assertEq(wrongPerson, 'only the defendant or their counsel may enter a plea')

    harness.identifiers[4] = 'license:defendant'
    harness.setJob(4, 'unemployed', 0)
    assertEq(DAG.Federal.Court.Plea(4, case.id, 'not_guilty').plea, 'not_guilty')

    local _, unknown = DAG.Federal.Court.Plea(4, case.id, 'maybe')
    assertEq(unknown, 'unknown plea')
end)

test('a case will not leave arraignment without a plea', function()
    loadCourt()
    agent(1, 2)
    local case = fileCase(1)
    DAG.Federal.Court.Progress(DAG.Federal.Court.Get(case.id))

    local _, message = DAG.Federal.Court.Progress(DAG.Federal.Court.Get(case.id))
    assertEq(message, 'no plea has been entered')
end)

-- A guilty plea is a conviction; there is nothing to try.
test('a guilty plea skips the trial and goes straight to the verdict', function()
    loadCourt()
    agent(1, 2)
    local case = fileCase(1)
    DAG.Federal.Court.Progress(DAG.Federal.Court.Get(case.id))

    harness.identifiers[4] = 'license:defendant'
    harness.setJob(4, 'unemployed', 0)
    DAG.Federal.Court.Plea(4, case.id, 'guilty')

    local advanced = DAG.Federal.Court.Progress(DAG.Federal.Court.Get(case.id))
    assertEq(advanced.stage, 'verdict')
    assertEq(advanced.verdict, 'guilty')
end)

test('evidence is admitted from the CAD and only once', function()
    loadCourt()
    agent(1, 2)
    local item = DAG.Federal.CAD.CollectEvidence(1, { kind = 'document', label = 'Transfer records' })
    local case = fileCase(1)

    assertEq(#DAG.Federal.Court.AdmitEvidence(1, case.id, item.id).evidence, 1)
    local _, message = DAG.Federal.Court.AdmitEvidence(1, case.id, item.id)
    assertEq(message, 'that item is already admitted')

    local _, missing = DAG.Federal.Court.AdmitEvidence(1, case.id, 'evd-999')
    assertEq(missing, 'no such evidence item')
end)

-- Admitted, analysed evidence is what should carry a conviction, not the
-- number of charges typed onto the file.
test('case strength rises with admitted evidence and falls with a real defender', function()
    loadCourt()
    agent(1, 2)
    local case = fileCase(1)
    local bare = DAG.Federal.Court.Strength(DAG.Federal.Court.Get(case.id))

    local item = DAG.Federal.CAD.CollectEvidence(1, { kind = 'document', label = 'Ledger' })
    DAG.Federal.Court.AdmitEvidence(1, case.id, item.id)
    local withEvidence = DAG.Federal.Court.Strength(DAG.Federal.Court.Get(case.id))
    assertTrue(withEvidence > bare, 'evidence strengthens the case')

    player(3, 'lawyer', 0, 'Robin Vance')
    DAG.Federal.Court.TakeRole(3, case.id, 'defense')
    local withDefense = DAG.Federal.Court.Strength(DAG.Federal.Court.Get(case.id))
    assertTrue(withDefense < withEvidence, 'a real defender weakens it')
end)

test('an analysed item matching the defendant strengthens the case further', function()
    loadCourt()
    agent(1, 2)
    DAG.Federal.CAD.Record('license:defendant', 'Sam Cole')

    local case = fileCase(1)
    local plain = DAG.Federal.CAD.CollectEvidence(1, { kind = 'casing' })
    DAG.Federal.Court.AdmitEvidence(1, case.id, plain.id)
    local before = DAG.Federal.Court.Strength(DAG.Federal.Court.Get(case.id))

    local swab = DAG.Federal.CAD.CollectEvidence(1, { kind = 'dna', subject = 'license:defendant' })
    local agency = DAG.Federal.Core.Agency('fib')
    local lab = DAG.Federal.Schema.FindById(agency.stations[1].zones, 'evidence')
    harness.placePlayer(1, vector3(lab.coords.x, lab.coords.y, lab.coords.z))
    DAG.Federal.CAD.AnalyseEvidence(1, swab.id)
    DAG.Federal.Court.AdmitEvidence(1, case.id, swab.id)

    assertTrue(DAG.Federal.Court.Strength(DAG.Federal.Court.Get(case.id)) > before + 0.2)
end)

test('a short jury is topped up with NPC jurors who vote', function()
    loadCourt()
    agent(1, 2)
    local case = fileCase(1)
    Config.Federal.court.jury.size = 6

    player(10, 'mechanic', 0)
    DAG.Federal.Court.TakeRole(10, case.id, 'juror')

    local tally = DAG.Federal.Court.Tally(case.id)
    assertEq(#DAG.Federal.Court.Get(case.id).roles.jurors, 6, 'topped up to the configured size')
    assertEq(tally.total, 5, 'the real juror who never voted is not voted for')
end)

test('NPC top-up can be switched off, leaving only real jurors', function()
    loadCourt()
    agent(1, 2)
    local case = fileCase(1)
    Config.Federal.court.jury.npcFill = false

    player(10, 'mechanic', 0)
    DAG.Federal.Court.TakeRole(10, case.id, 'juror')
    DAG.Federal.Court.Tally(case.id)
    assertEq(#DAG.Federal.Court.Get(case.id).roles.jurors, 1)
end)

test('a real juror vote is counted and requires being on the jury', function()
    loadCourt()
    agent(1, 2)
    local case = fileCase(1)
    player(10, 'mechanic', 0)

    local _, notDeliberating = DAG.Federal.Court.Vote(10, case.id, true)
    assertEq(notDeliberating, 'the jury is not deliberating')

    local stored = DAG.Federal.Court.Get(case.id)
    stored.stage = 'deliberation'
    DAG.Federal.Court.cases.save(stored.id, stored)

    local _, notJuror = DAG.Federal.Court.Vote(10, case.id, true)
    assertEq(notJuror, 'you are not on this jury')

    DAG.Federal.Court.TakeRole(10, case.id, 'juror')
    assertTrue(DAG.Federal.Court.Vote(10, case.id, true).votes['license:10'])
end)

-- An NPC juror converts case strength into a vote, so pinning the roll is what
-- makes this about the evidence rather than about the dice.
test('a strong case convicts and a bare one does not', function()
    loadCourt()
    agent(1, 2)
    Config.Federal.court.jury.size = 7
    harness.fixRandom(0.5)

    local strong = fileCase(1, { 'Espionage', 'Kidnapping' })
    for index = 1, 5 do
        local item = DAG.Federal.CAD.CollectEvidence(1, { kind = 'document', label = 'Exhibit ' .. index })
        DAG.Federal.Court.AdmitEvidence(1, strong.id, item.id)
    end
    assertTrue(DAG.Federal.Court.Strength(DAG.Federal.Court.Get(strong.id)) > 0.85)
    assertEq(DAG.Federal.Court.Verdict(strong.id).verdict, 'guilty')

    -- The same jury, the same roll, but a case with nothing behind it.
    local bare = fileCase(1, { 'Failure to appear' })
    assertTrue(DAG.Federal.Court.Strength(DAG.Federal.Court.Get(bare.id)) < 0.5)
    assertEq(DAG.Federal.Court.Verdict(bare.id).verdict, 'not_guilty')
end)

test('a unanimous jury requirement can hang', function()
    loadCourt()
    agent(1, 2)
    Config.Federal.court.jury.unanimous = true
    Config.Federal.court.jury.size = 2

    local case = fileCase(1)
    player(10, 'mechanic', 0)
    player(11, 'mechanic', 0)
    DAG.Federal.Court.TakeRole(10, case.id, 'juror')
    DAG.Federal.Court.TakeRole(11, case.id, 'juror')

    local stored = DAG.Federal.Court.Get(case.id)
    stored.stage = 'deliberation'
    DAG.Federal.Court.cases.save(stored.id, stored)

    DAG.Federal.Court.Vote(10, case.id, true)
    DAG.Federal.Court.Vote(11, case.id, false)
    assertEq(DAG.Federal.Court.Verdict(case.id).verdict, 'hung')
end)

test('sentencing follows the charge catalog and only the judge may pass it', function()
    loadCourt()
    agent(1, 2)
    player(2, 'judge', 0, 'Judge Amari')

    local case = fileCase(1, { 'Wire fraud', 'Identity theft' })
    DAG.Federal.Court.TakeRole(2, case.id, 'judge')

    local recommendation = DAG.Federal.Court.Recommendation(DAG.Federal.Court.Get(case.id))
    assertEq(recommendation.months, 60, '36 + 24 from the catalog')
    assertEq(recommendation.fine, 40000)

    local stored = DAG.Federal.Court.Get(case.id)
    stored.stage = 'verdict'
    stored.verdict = 'guilty'
    DAG.Federal.Court.cases.save(stored.id, stored)

    local _, wrongPerson = DAG.Federal.Court.Sentence(1, case.id, 60, 40000)
    assertEq(wrongPerson, 'only the presiding judge may pass sentence')

    local sentenced = DAG.Federal.Court.Sentence(2, case.id, 60, 40000)
    assertEq(sentenced.sentence.months, 60)
    assertEq(sentenced.stage, 'closed')
end)

-- Sentencing is discretionary, not arbitrary.
test('a judge may depart from the recommendation only within the configured band', function()
    loadCourt()
    agent(1, 2)
    player(2, 'judge', 0, 'Judge Amari')

    local case = fileCase(1, { 'Wire fraud' })
    DAG.Federal.Court.TakeRole(2, case.id, 'judge')
    local stored = DAG.Federal.Court.Get(case.id)
    stored.stage = 'verdict'
    stored.verdict = 'guilty'
    DAG.Federal.Court.cases.save(stored.id, stored)

    -- Recommendation is 36 months; discretion is 0.5, so 18..54.
    local sentenced = DAG.Federal.Court.Sentence(2, case.id, 1, 0)
    assertEq(sentenced.sentence.months, 18, 'clamped to the floor of the band')
    assertEq(sentenced.sentence.fine, 12500)
end)

test('a conviction notes the citizen record and raises a sentencing event', function()
    loadCourt()
    agent(1, 2)
    player(2, 'judge', 0, 'Judge Amari')
    local case = fileCase(1, { 'Wire fraud' })
    DAG.Federal.Court.TakeRole(2, case.id, 'judge')

    local stored = DAG.Federal.Court.Get(case.id)
    stored.stage = 'verdict'
    stored.verdict = 'guilty'
    DAG.Federal.Court.cases.save(stored.id, stored)
    DAG.Federal.Court.Sentence(2, case.id, nil, nil)

    local record = DAG.Federal.CAD.LookupRecord(1, 'license:defendant')
    assertTrue(#record.notes > 0)

    local raised = false
    for _, event in ipairs(harness.localEvents) do
        if tostring(event.event):find('federal:sentenced', 1, true) then
            raised = true
            assertEq(event.args[1].months, 36)
        end
    end
    assertTrue(raised, 'a jail resource can act on the sentence')
end)

test('an acquittal closes the case without a sentence', function()
    loadCourt()
    agent(1, 2)
    local case = fileCase(1)

    local stored = DAG.Federal.Court.Get(case.id)
    stored.stage = 'verdict'
    stored.verdict = 'not_guilty'
    DAG.Federal.Court.cases.save(stored.id, stored)

    local closed = DAG.Federal.Court.Progress(DAG.Federal.Court.Get(case.id))
    assertEq(closed.stage, 'closed')
    assertNil(closed.sentence)
end)

-- The NPC judge has to be able to run a case end to end on its own.
test('an NPC judge runs a case from filing to sentence', function()
    loadCourt()
    agent(1, 2)
    Config.Federal.court.npcJudgeDelay = 1000
    harness.fixRandom(0.5)

    local case = fileCase(1, { 'Wire fraud' })
    for index = 1, 4 do
        local item = DAG.Federal.CAD.CollectEvidence(1, { kind = 'document', label = 'Exhibit ' .. index })
        DAG.Federal.Court.AdmitEvidence(1, case.id, item.id)
    end

    -- Each tick is a beat past the NPC judge's delay.
    local clock = os.time()
    for step = 1, 8 do
        DAG.Federal.Court.Tick(clock + (step * 10))
    end

    local finished = DAG.Federal.Court.Get(case.id)
    assertEq(finished.stage, 'closed')
    assertEq(finished.verdict, 'guilty')
    assertTrue(finished.sentence.months > 0)
    assertEq(finished.plea, 'not_guilty', 'a plea was recorded for the absent defendant')
end)

test('a real judge is never put on the NPC timer', function()
    loadCourt()
    agent(1, 2)
    player(2, 'judge', 0, 'Judge Amari')
    Config.Federal.court.npcJudgeDelay = 1000

    local case = fileCase(1)
    DAG.Federal.Court.TakeRole(2, case.id, 'judge')

    for step = 1, 5 do DAG.Federal.Court.Tick(os.time() + (step * 10)) end
    assertEq(DAG.Federal.Court.Get(case.id).stage, 'filed', 'the real judge moves it themselves')
end)

test('the transcript and votes are hidden from people outside the case', function()
    loadCourt()
    agent(1, 2)
    local case = fileCase(1)
    local stored = DAG.Federal.Court.Get(case.id)
    stored.stage = 'trial'
    DAG.Federal.Court.cases.save(stored.id, stored)
    DAG.Federal.Court.Testify(1, case.id, 'The transfers were authorised from this terminal.')

    assertEq(#DAG.Federal.Court.Case(1, case.id).transcript, 1, 'the filer sees it')

    player(9, 'mechanic', 0)
    local outsider = DAG.Federal.Court.Case(9, case.id)
    assertEq(outsider.number, case.number, 'the docket entry is public')
    assertNil(outsider.transcript, 'the transcript is not')
    assertNil(outsider.votes)
end)

test('courthouses are editable in game by an admin', function()
    loadCourt()
    harness.aceAllowed[1] = { ['federal.admin'] = true }
    harness.placePlayer(1, vector3(700.5, -1200.25, 25.0))

    local house = DAG.Federal.Court.SaveCourthouse(1, { label = 'Vespucci Night Court', here = true })
    assertEq(house.id, 'vespucci-night-court')
    assertEq(house.coords.x, 700.5)
    assertEq(#DAG.Federal.Court.Courthouses(), 3)

    harness.placePlayer(1, vector3(701.0, -1201.0, 25.0))
    local seat = DAG.Federal.Court.SaveSeat(1, house.id, { role = 'judge', label = 'Bench', here = true })
    assertEq(seat.coords.x, 701.0)

    DAG.Federal.Court.DeleteCourthouse(1, house.id)
    assertNil(DAG.Federal.Court.Courthouse(house.id))
end)

test('a non-admin cannot edit a courthouse', function()
    loadCourt()
    agent(1, 5)
    local _, message = DAG.Federal.Court.SaveCourthouse(1, { label = 'My own court', here = true })
    assertEq(message, 'editing a courthouse is an admin action')
end)

test('re-placing a single-position seat moves it instead of duplicating', function()
    loadCourt()
    harness.aceAllowed[1] = { ['federal.admin'] = true }
    harness.placePlayer(1, vector3(50.0, 60.0, 70.0))

    DAG.Federal.Court.SaveSeat(1, 'los-santos-courthouse', { id = 'bench', role = 'judge', label = 'Bench', here = true })
    local house = DAG.Federal.Court.Courthouse('los-santos-courthouse')
    assertEq(#DAG.Federal.Schema.SeatsFor(house, 'judge'), 1)
    assertEq(DAG.Federal.Schema.SeatsFor(house, 'judge')[1].coords.x, 50.0)
end)

test('the court can be switched off entirely', function()
    loadCourt()
    Config.Federal.court.enabled = false
    agent(1, 2)
    local _, message = fileCase(1)
    assertEq(message, 'the court process is disabled')
end)
