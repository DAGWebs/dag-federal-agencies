-- Uniforms, armory and the LEO actions.
local function loadOps()
    return harness.loadFederalServer({ federal = { 'core', 'cad', 'uniforms', 'armory', 'actions' } })
end

local function zoneCoords(agencyId, zoneId)
    local agency = DAG.Federal.Core.Agency(agencyId)
    local zone = DAG.Federal.Schema.FindById(agency.stations[1].zones, zoneId)
    return vector3(zone.coords.x, zone.coords.y, zone.coords.z)
end

local function officer(playerSource, agencyId, grade, zoneId)
    harness.identifiers[playerSource] = 'license:' .. tostring(playerSource)
    harness.names[playerSource] = 'Officer ' .. playerSource
    harness.setJob(playerSource, agencyId or 'fib', grade or 2)
    harness.placePlayer(playerSource, zoneCoords(agencyId or 'fib', zoneId or 'duty'))
    DAG.Federal.Core.SetDuty(playerSource, true)
end

local function civilian(playerSource, coords)
    harness.identifiers[playerSource] = 'license:civ' .. tostring(playerSource)
    harness.names[playerSource] = 'Civilian ' .. playerSource
    harness.setJob(playerSource, 'unemployed', 0)
    harness.placePlayer(playerSource, coords)
end

local SAMPLE = { { slot = 11, drawable = 12, texture = 2 }, { slot = 4, drawable = 8, texture = 0 } }

-- Checkout ledger ------------------------------------------------------------

test('armory draws land on a checkout ledger, aggregated and clearable', function()
    loadOps()
    officer(1, 'fib', 2, 'armory')

    assertTrue(DAG.Federal.Armory.Draw(1, 'radio') ~= nil)
    assertTrue(DAG.Federal.Armory.Draw(1, 'radio') ~= nil)
    assertTrue(DAG.Federal.Armory.Draw(1, 'handcuffs') ~= nil)

    local kit = DAG.Federal.Armory.CheckoutFor('license:1')
    assertEq(#kit.items, 2, 'the same item aggregates instead of stacking lines')
    assertEq(kit.items[1].item, 'radio')
    assertEq(kit.items[1].count, 2)

    DAG.Federal.Armory.ClearCheckout('license:1')
    assertNil(DAG.Federal.Armory.CheckoutFor('license:1'))
end)

test('drawing a motor pool vehicle records it on a callsign plate', function()
    loadOps()
    officer(1, 'fib', 3, 'garage')

    local entry = DAG.Federal.Armory.RequestVehicle(1, 'fbi')
    assertTrue(entry ~= nil, 'the stock fbi cruiser draws at grade 3')

    local kit = DAG.Federal.Armory.CheckoutFor('license:1')
    assertTrue(kit.vehicle ~= nil, 'the vehicle is on the ledger')
    -- The plate is the callsign with punctuation stripped: FIB-1 -> FIB1.
    assertEq(kit.vehicle.plate, 'FIB1')
end)

-- Uniforms -------------------------------------------------------------------

test('a boss standing in the office can save a captured outfit as a uniform', function()
    loadOps()
    officer(1, 'fib', 4, 'boss')

    local uniform = DAG.Federal.Uniforms.Save(1, { label = 'Night raid', minGrade = 2, components = SAMPLE })
    assertEq(uniform.id, 'night-raid')
    assertEq(uniform.components[1].drawable, 12)

    -- It is persisted on the agency, not in a side table.
    local stored = DAG.Federal.Schema.FindById(DAG.Federal.Core.Agency('fib').uniforms, 'night-raid')
    assertEq(stored.minGrade, 2)
end)

test('a uniform cannot be saved from outside the boss office', function()
    loadOps()
    officer(1, 'fib', 4, 'duty')
    local _, message = DAG.Federal.Uniforms.Save(1, { label = 'From the desk', components = SAMPLE })
    assertEq(message, 'not authorized')
end)

test('a rank without uniform.manage cannot save a uniform even in the office', function()
    loadOps()
    officer(1, 'fib', 3, 'boss')
    assertNil(DAG.Federal.Uniforms.Save(1, { label = 'Unauthorized', components = SAMPLE }))
end)

test('saving the same uniform id replaces it instead of duplicating', function()
    loadOps()
    officer(1, 'fib', 4, 'boss')
    local before = #DAG.Federal.Core.Agency('fib').uniforms

    DAG.Federal.Uniforms.Save(1, { label = 'Field suit', components = SAMPLE })
    local after = DAG.Federal.Core.Agency('fib').uniforms
    assertEq(#after, before, 'field-suit already existed in the catalog')
    assertEq(DAG.Federal.Schema.FindById(after, 'field-suit').components[1].drawable, 12)
end)

test('deleting a uniform removes it from the agency', function()
    loadOps()
    officer(1, 'fib', 4, 'boss')
    DAG.Federal.Uniforms.Delete(1, 'raid-kit')
    assertNil(DAG.Federal.Schema.FindById(DAG.Federal.Core.Agency('fib').uniforms, 'raid-kit'))

    local _, message = DAG.Federal.Uniforms.Delete(1, 'raid-kit')
    assertEq(message, 'that uniform no longer exists')
end)

test('uniforms are listed by grade and worn only in a locker room', function()
    loadOps()
    officer(1, 'fib', 0, 'locker')
    -- raid-kit is minGrade 2 in the catalog, so a probationary agent has one.
    assertEq(#DAG.Federal.Uniforms.List(1), 1)

    assertEq(DAG.Federal.Uniforms.Wear(1, 'field-suit').id, 'field-suit')
    local _, message = DAG.Federal.Uniforms.Wear(1, 'raid-kit')
    assertEq(message, 'your grade does not have that uniform issued')

    officer(1, 'fib', 3, 'duty')
    local _, placeMessage = DAG.Federal.Uniforms.Wear(1, 'field-suit')
    assertEq(placeMessage, 'not at a locker room')
end)

test('wearing a uniform pushes the component set to that player only', function()
    loadOps()
    officer(1, 'fib', 0, 'locker')
    DAG.Federal.Uniforms.Wear(1, 'field-suit')

    local pushed = harness.clientEvents[#harness.clientEvents]
    assertEq(pushed.target, 1)
    assertEq(pushed.args[1].id, 'field-suit')
end)

-- Armory -----------------------------------------------------------------------

test('the armory lists locked entries with the rank that unlocks them', function()
    loadOps()
    officer(1, 'fib', 0, 'armory')
    local list = DAG.Federal.Armory.List(1)

    local byId = {}
    for _, entry in ipairs(list) do byId[entry.id] = entry end
    assertFalse(byId.radio.locked)
    assertTrue(byId.carbine.locked)
    assertEq(byId.carbine.lockedReason, 'Requires Senior Special Agent')
end)

test('drawing an item requires the armory zone and the grade', function()
    loadOps()
    officer(1, 'fib', 0, 'armory')
    assertEq(DAG.Federal.Armory.Draw(1, 'radio').item, 'radio')
    assertEq(DAG.Framework.GetItemCount(1, 'radio'), 1)

    -- The refusal names the rank that unlocks the item.
    local _, gradeMessage = DAG.Federal.Armory.Draw(1, 'carbine')
    assertEq(gradeMessage, 'Requires Senior Special Agent')

    officer(1, 'fib', 3, 'duty')
    local _, placeMessage = DAG.Federal.Armory.Draw(1, 'radio')
    assertEq(placeMessage, 'not at an armory')
end)

test('an unaffordable item is refused and nothing is charged or issued', function()
    loadOps()
    officer(1, 'fib', 4, 'boss')
    DAG.Federal.Armory.Save(1, { id = 'drone', item = 'surveillance_drone', label = 'Drone', price = 5000 })

    officer(1, 'fib', 4, 'armory')
    local _, message = DAG.Federal.Armory.Draw(1, 'drone')
    assertEq(message, 'you cannot afford that')
    assertEq(DAG.Framework.GetItemCount(1, 'surveillance_drone'), 0)
    assertEq(DAG.Framework.GetMoney(1, 'bank'), 0)
end)

test('a paid item debits exactly the listed price', function()
    loadOps()
    officer(1, 'fib', 4, 'boss')
    DAG.Federal.Armory.Save(1, { id = 'drone', item = 'surveillance_drone', label = 'Drone', price = 250 })

    officer(1, 'fib', 4, 'armory')
    DAG.Framework.AddMoney(1, 'bank', 1000, 'test')
    assertEq(DAG.Federal.Armory.Draw(1, 'drone').item, 'surveillance_drone')
    assertEq(DAG.Framework.GetMoney(1, 'bank'), 750)
end)

test('stocking the armory is a boss action', function()
    loadOps()
    officer(1, 'fib', 2, 'boss')
    assertNil(DAG.Federal.Armory.Save(1, { item = 'grenade' }), 'a senior agent cannot restock')

    officer(1, 'fib', 4, 'boss')
    assertEq(DAG.Federal.Armory.Save(1, { item = 'flashbang', label = 'Flashbang' }).id, 'flashbang')
    assertEq(DAG.Federal.Armory.Delete(1, 'flashbang').id, 'flashbang')
end)

-- Actions ------------------------------------------------------------------------

test('cuffing toggles and requires the subject to be in range', function()
    loadOps()
    officer(1, 'fib', 1, 'duty')
    civilian(2, zoneCoords('fib', 'duty'))

    assertTrue(DAG.Federal.Actions.Cuff(1, 2).cuffed)
    assertTrue(DAG.Federal.Actions.IsCuffed(2))
    assertFalse(DAG.Federal.Actions.Cuff(1, 2).cuffed, 'the same action uncuffs')

    harness.placePlayer(2, vector3(3000.0, 3000.0, 0.0))
    assertNil(DAG.Federal.Actions.Cuff(1, 2), 'out of range is refused')
end)

test('an officer cannot cuff themselves', function()
    loadOps()
    officer(1, 'fib', 1, 'duty')
    assertNil(DAG.Federal.Actions.Cuff(1, 1))
end)

test('escorting only works on a restrained subject', function()
    loadOps()
    officer(1, 'fib', 1, 'duty')
    civilian(2, zoneCoords('fib', 'duty'))

    local _, message = DAG.Federal.Actions.Escort(1, 2)
    assertEq(message, 'that subject is not restrained')

    DAG.Federal.Actions.Cuff(1, 2)
    assertTrue(DAG.Federal.Actions.Escort(1, 2).escorting)
    assertFalse(DAG.Federal.Actions.Escort(1, 2).escorting, 'the same action lets go')
end)

test('searching a suspect finds and seizes configured contraband only', function()
    loadOps()
    officer(1, 'fib', 1, 'duty')
    civilian(2, zoneCoords('fib', 'duty'))
    DAG.Framework.AddItem(2, 'cocaine', 3)
    DAG.Framework.AddItem(2, 'lockpick', 1)
    DAG.Framework.AddItem(2, 'sandwich', 5)

    local report = DAG.Federal.Actions.SearchSuspect(1, 2)
    assertEq(#report.found, 2, 'the sandwich is not contraband')
    assertEq(#report.seized, 2)
    assertEq(DAG.Framework.GetItemCount(2, 'cocaine'), 0, 'seized')
    assertEq(DAG.Framework.GetItemCount(2, 'sandwich'), 5, 'untouched')
    assertEq(#report.evidence, 2, 'each seizure is filed as evidence')
end)

test('seizing can be switched off, leaving the search a report only', function()
    loadOps()
    Config.Federal.seizeOnSearch = false
    officer(1, 'fib', 1, 'duty')
    civilian(2, zoneCoords('fib', 'duty'))
    DAG.Framework.AddItem(2, 'meth', 2)

    local report = DAG.Federal.Actions.SearchSuspect(1, 2)
    assertEq(#report.found, 1)
    assertEq(#report.seized, 0)
    assertEq(DAG.Framework.GetItemCount(2, 'meth'), 2)
end)

-- Reporting an empty search on a framework that cannot read inventories would
-- read as "the suspect is clean", which is worse than refusing.
test('searching refuses rather than reporting clean when inventories are unreadable', function()
    loadOps()
    officer(1, 'fib', 1, 'duty')
    civilian(2, zoneCoords('fib', 'duty'))

    DAG.Framework.ExtendAdapter('standalone', { getItemCount = nil })
    local adapter = DAG.Framework.GetPlayer and true
    assertTrue(adapter)
    -- Remove the capability the way an adapter without item support presents.
    DAG.Framework.Supports = function(method) return method ~= 'getItemCount' end

    local _, message = DAG.Federal.Actions.SearchSuspect(1, 2)
    assertEq(message, 'this framework cannot report inventories; extend the bridge adapter to enable searching')
end)

test('searching a vehicle searches the players actually inside it', function()
    loadOps()
    officer(1, 'fib', 1, 'duty')
    civilian(2, zoneCoords('fib', 'duty'))
    civilian(3, zoneCoords('fib', 'duty'))
    DAG.Framework.AddItem(2, 'heroin', 1)

    local vehicle = 5000
    harness.networkEntities[77] = vehicle
    harness.entityCoords[vehicle] = zoneCoords('fib', 'duty')
    harness.vehicles[harness.peds[2]] = vehicle
    -- Player 3 is standing next to the car, not in it.

    local report = DAG.Federal.Actions.SearchVehicle(1, 77)
    assertEq(#report.occupants, 1, 'only the occupant is searched')
    assertEq(report.occupants[1].target, 2)
    assertEq(#report.occupants[1].found, 1)
end)

test('a vehicle that is not there cannot be searched', function()
    loadOps()
    officer(1, 'fib', 1, 'duty')
    local _, message = DAG.Federal.Actions.SearchVehicle(1, 999)
    assertEq(message, 'that vehicle is not there')
end)

test('identifying a subject surfaces their record and any warrant', function()
    loadOps()
    officer(1, 'fib', 2, 'duty')
    civilian(2, zoneCoords('fib', 'duty'))
    DAG.Federal.CAD.IssueWarrant(1, { identifier = 'license:civ2', name = 'Civilian 2', reason = 'Fraud' })

    local result = DAG.Federal.Actions.Identify(1, 2)
    assertEq(result.name, 'Civilian 2')
    assertEq(result.warrant.status, 'active')
end)

-- Fingerprinting is what puts a subject on file, which is what makes a later
-- DNA or print analysis able to match them.
test('fingerprinting puts a subject on file so the lab can match them later', function()
    loadOps()
    officer(1, 'fib', 2, 'duty')
    civilian(2, zoneCoords('fib', 'duty'))

    local swab = DAG.Federal.Actions.SwabSubject(1, 2)
    harness.placePlayer(1, zoneCoords('fib', 'evidence'))
    assertEq(DAG.Federal.CAD.AnalyseEvidence(1, swab.id).result, 'CODIS search returned no candidates on file')

    harness.placePlayer(1, zoneCoords('fib', 'duty'))
    assertTrue(DAG.Federal.Actions.Fingerprint(1, 2).record.printed)

    local second = DAG.Federal.Actions.SwabSubject(1, 2)
    harness.placePlayer(1, zoneCoords('fib', 'evidence'))
    assertEq(DAG.Federal.CAD.AnalyseEvidence(1, second.id).result, 'CODIS hit: Civilian 2')
end)

test('an arrest requires restraint first', function()
    loadOps()
    officer(1, 'fib', 2, 'duty')
    civilian(2, zoneCoords('fib', 'duty'))

    local _, message = DAG.Federal.Actions.Arrest(1, 2, { charges = { 'Fraud' } })
    assertEq(message, 'restrain the subject first')

    DAG.Federal.Actions.Cuff(1, 2)
    local booking = DAG.Federal.Actions.Arrest(1, 2, { charges = { 'Fraud' } })
    assertEq(booking.name, 'Civilian 2')
    assertEq(#DAG.Federal.CAD.LookupRecord(1, 'license:civ2').arrests, 1)
end)

test('an arrest serves an outstanding warrant and inherits its charges', function()
    loadOps()
    officer(1, 'fib', 2, 'duty')
    civilian(2, zoneCoords('fib', 'duty'))
    local warrant = DAG.Federal.CAD.IssueWarrant(1, {
        identifier = 'license:civ2', name = 'Civilian 2', reason = 'Wire fraud', charges = { 'Wire fraud' }
    })

    DAG.Federal.Actions.Cuff(1, 2)
    local booking = DAG.Federal.Actions.Arrest(1, 2, {})
    assertEq(booking.warrant, warrant.number)
    assertEq(booking.charges[1], 'Wire fraud', 'the warrant charges carried over')
    assertNil(DAG.Federal.CAD.ActiveWarrantFor('license:civ2'), 'the warrant was served')
end)

test('a fine is bounded and only charges what the subject can pay', function()
    loadOps()
    officer(1, 'fib', 2, 'duty')
    civilian(2, zoneCoords('fib', 'duty'))

    local _, low = DAG.Federal.Actions.Fine(1, 2, 5, 'Too small')
    assertEq(low, 'a fine must be between 50 and 50000')
    local _, high = DAG.Federal.Actions.Fine(1, 2, 999999, 'Too big')
    assertEq(high, 'a fine must be between 50 and 50000')

    local _, broke = DAG.Federal.Actions.Fine(1, 2, 500, 'Citation')
    assertEq(broke, 'the subject cannot pay that fine')

    DAG.Framework.AddMoney(2, 'bank', 800, 'test')
    assertEq(DAG.Federal.Actions.Fine(1, 2, 500, 'Citation').amount, 500)
    assertEq(DAG.Framework.GetMoney(2, 'bank'), 300)
end)

test('releasing clears the restraint state', function()
    loadOps()
    officer(1, 'fib', 2, 'duty')
    civilian(2, zoneCoords('fib', 'duty'))
    DAG.Federal.Actions.Cuff(1, 2)
    DAG.Federal.Actions.Release(1, 2)
    assertFalse(DAG.Federal.Actions.IsCuffed(2))
end)

test('a dropped player clears their restraint state', function()
    loadOps()
    officer(1, 'fib', 2, 'duty')
    civilian(2, zoneCoords('fib', 'duty'))
    DAG.Federal.Actions.Cuff(1, 2)

    _G.source = 2
    TriggerEvent('playerDropped')
    _G.source = nil
    assertFalse(DAG.Federal.Actions.IsCuffed(2))
end)
