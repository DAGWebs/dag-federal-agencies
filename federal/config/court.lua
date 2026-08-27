-- Courthouses and the charge catalog.
--
-- Like the agency catalog, everything here is a default that the in-game
-- editor can replace. Seats are what make a courtroom work: the judge, the
-- dock, the two counsel tables and the jury box are placed positions, and an
-- NPC standing in for an empty role sits in the same seat a player would.
--
-- Charges are looked up by their text, which is the same text the CAD stores
-- on an incident or a warrant, so a charge written by an officer flows into
-- sentencing without a second catalog to keep in sync. Anything not listed
-- falls back to Config.Federal.court.defaultCharge below.

local function coords(x, y, z)
    return { x = x, y = y, z = z }
end

local function offset(anchor, dx, dy, dz)
    return coords(anchor.x + dx, anchor.y + dy, anchor.z + (dz or 0.0))
end

-- Lays out a standard courtroom around one anchor: bench facing the room,
-- counsel tables either side, dock beside the defense, jury box along one
-- wall and a row of gallery seats at the back.
local function courtroom(id, label, anchor, blip)
    local seats = {
        { id = 'bench', role = 'judge', label = 'Bench', coords = offset(anchor, 0.0, 4.0), heading = 180.0 },
        { id = 'clerk', role = 'clerk', label = 'Clerk desk', coords = offset(anchor, 2.5, 3.0), heading = 200.0 },
        { id = 'prosecution', role = 'prosecutor', label = 'Prosecution table', coords = offset(anchor, -2.0, 0.5), heading = 0.0 },
        { id = 'defense', role = 'defense', label = 'Defense table', coords = offset(anchor, 2.0, 0.5), heading = 0.0 },
        { id = 'dock', role = 'defendant', label = 'Dock', coords = offset(anchor, 3.2, 0.5), heading = 270.0 },
        { id = 'stand', role = 'witness', label = 'Witness stand', coords = offset(anchor, -2.8, 3.0), heading = 160.0 }
    }

    -- Six jury seats in two rows along the left wall.
    for index = 1, 6 do
        local row = index <= 3 and 0.0 or 1.2
        local step = ((index - 1) % 3) * 1.2
        seats[#seats + 1] = {
            id = ('jury-%d'):format(index),
            role = 'jury',
            label = ('Jury seat %d'):format(index),
            coords = offset(anchor, -4.5 - row, 1.0 + step),
            heading = 90.0
        }
    end

    -- Four gallery seats at the back for spectators and the bailiff.
    for index = 1, 4 do
        seats[#seats + 1] = {
            id = ('gallery-%d'):format(index),
            role = 'gallery',
            label = ('Gallery seat %d'):format(index),
            coords = offset(anchor, -1.5 + ((index - 1) * 1.0), -4.0),
            heading = 0.0
        }
    end

    return { id = id, label = label, coords = anchor, blip = blip, seats = seats }
end

Config.Federal.Courthouses = {
    courtroom('los-santos-courthouse', 'Los Santos Courthouse',
        coords(242.6, -1379.4, 39.53), { sprite = 419, color = 5, scale = 0.9 }),
    courtroom('paleto-courthouse', 'Paleto Bay Circuit Court',
        coords(-448.2, 6013.5, 31.72), { sprite = 419, color = 5, scale = 0.7 })
}

-- Charge catalog -------------------------------------------------------------
--
-- `months` is the custodial recommendation, `fine` the monetary one, and
-- `severity` (1-3) weighs how strongly a charge pushes a jury toward convicting
-- when the evidence is thin. Charges an officer writes that are not listed
-- here still work; they fall back to `defaultCharge`.
Config.Federal.Charges = {
    ['Wire fraud'] = { months = 36, fine = 25000, severity = 2 },
    ['Identity theft'] = { months = 24, fine = 15000, severity = 2 },
    ['Counterfeiting'] = { months = 48, fine = 40000, severity = 3 },
    ['Passing forged currency'] = { months = 18, fine = 12000, severity = 2 },
    ['Espionage'] = { months = 180, fine = 100000, severity = 3 },
    ['Unlawful transfer of classified material'] = { months = 96, fine = 60000, severity = 3 },
    ['Kidnapping'] = { months = 120, fine = 50000, severity = 3 },
    ['Obstruction of a federal investigation'] = { months = 30, fine = 20000, severity = 2 },
    ['Unlicensed transfer of firearms'] = { months = 42, fine = 30000, severity = 2 },
    ['Possession of an unregistered weapon'] = { months = 18, fine = 10000, severity = 1 },
    ['Threatening a protected person'] = { months = 60, fine = 35000, severity = 3 },
    ['Theft of federal property'] = { months = 30, fine = 20000, severity = 2 },
    ['Resisting a federal officer'] = { months = 12, fine = 5000, severity = 1 },
    ['Failure to appear'] = { months = 6, fine = 2500, severity = 1 }
}

-- Applied to any charge that is not in the catalog above.
Config.Federal.court.defaultCharge = { months = 12, fine = 5000, severity = 1 }

-- Ped models used when a role has to be filled by an NPC.
Config.Federal.court.npcModels = {
    judge = 's_m_m_highsec_01',
    prosecutor = 'a_m_y_business_01',
    defense = 'a_m_m_business_01',
    juror = {
        'a_f_m_bevhills_02', 'a_m_m_business_01', 'a_f_y_business_02',
        'a_m_y_hipster_01', 'a_f_m_fatwhite_01', 'a_m_m_eastsa_02'
    }
}
