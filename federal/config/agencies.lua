-- Default agency catalog.
--
-- These are STARTING POINTS. Every field here can be changed in game by a
-- player holding `editor.manage` (or the `Config.Federal.adminPermission`
-- ACE), and those edits are stored in the resource's own store and take
-- precedence over this file. Nothing below is authoritative at runtime.
--
-- Coordinates place each station on solid ground in Los Santos so the resource
-- is usable the moment it starts. Reposition them with the in-game editor
-- rather than hand-editing this file: the editor writes your real standing
-- position, which is always more accurate than a number typed here.

local function coords(x, y, z)
    return { x = x, y = y, z = z }
end

-- Zone coordinates are expressed as offsets from the station anchor so a
-- default station reads as one coherent building instead of eight unrelated
-- numbers. The editor stores absolute coordinates once you move a zone.
local function offset(anchor, dx, dy, dz)
    return coords(anchor.x + dx, anchor.y + dy, anchor.z + (dz or 0.0))
end

-- Builds a rank ladder, accumulating permissions as grades rise: a rank keeps
-- everything the rank below it had and adds its own grants. Spelling out all
-- fourteen permissions on all six ranks of all four agencies would be noise,
-- and the cumulative shape is what a promotion actually means.
local function ladder(rows)
    local ranks, carried = {}, {}
    for _, row in ipairs(rows) do
        local permissions = {}
        for name in pairs(carried) do permissions[name] = true end
        for _, name in ipairs(row[3] or {}) do
            permissions[name] = true
            carried[name] = true
        end
        ranks[#ranks + 1] = { grade = row[1], label = row[2], permissions = permissions }
    end
    return ranks
end

-- The four grants every sworn agent starts with.
local SWORN = { 'cad.view', 'armory.use', 'actions.detain', 'actions.search', 'actions.evidence' }

-- A placeholder outfit built from low drawable indexes that exist on both
-- freemode peds, so it renders as something sensible on any server. Replace it
-- with "Save my current outfit" from the boss menu: capturing the clothes you
-- are actually wearing is the intended workflow, and it is one menu click.
local function placeholderUniform(id, label, minGrade)
    return {
        id = id,
        label = label,
        variant = 'any',
        minGrade = minGrade or 0,
        armour = 0,
        components = {
            { slot = 3, drawable = 1, texture = 0 },   -- arms
            { slot = 4, drawable = 10, texture = 0 },  -- legs
            { slot = 6, drawable = 10, texture = 0 },  -- shoes
            { slot = 8, drawable = 15, texture = 0 },  -- undershirt
            { slot = 11, drawable = 4, texture = 0 }   -- jacket
        },
        props = {}
    }
end

-- Shared armory baseline. Each agency layers its own specialist kit on top.
local function baseArmory()
    return {
        { id = 'radio', item = 'radio', label = 'Handheld radio', category = 'Comms', minGrade = 0 },
        { id = 'handcuffs', item = 'handcuffs', label = 'Handcuffs', category = 'Restraints', minGrade = 0 },
        { id = 'armour', item = 'armour', label = 'Body armour', category = 'Protection', minGrade = 0 },
        { id = 'evidence-kit', item = 'evidence_kit', label = 'Evidence collection kit', category = 'Investigation', minGrade = 0 },
        { id = 'pistol', item = 'weapon_pistol', label = 'Service pistol', category = 'Sidearm', minGrade = 1 },
        { id = 'stungun', item = 'weapon_stungun', label = 'Taser', category = 'Less lethal', minGrade = 0 }
    }
end

local function withExtras(base, extras)
    for _, entry in ipairs(extras) do base[#base + 1] = entry end
    return base
end

-- A full station: the eight zone kinds laid out around one anchor point.
local function station(id, label, anchor, blip)
    return {
        id = id,
        label = label,
        coords = anchor,
        blip = blip,
        -- Offsets are spread so no two zones are within Config.Federal.zoneDistance
        -- of each other: overlapping zones would let one marker satisfy the
        -- server check for a different room.
        zones = {
            { id = 'duty', kind = 'duty', label = 'Sign-in desk', coords = offset(anchor, 2.0, 0.0), radius = 1.5 },
            { id = 'cad', kind = 'cad', label = 'CAD terminal', coords = offset(anchor, 2.0, 8.0), radius = 1.5 },
            { id = 'locker', kind = 'locker', label = 'Locker room', coords = offset(anchor, -8.0, 2.0), radius = 2.0 },
            -- No zone grade here on purpose: the armory is gated per item, so a
            -- probationary agent can still draw a radio and cuffs.
            { id = 'armory', kind = 'armory', label = 'Armory', coords = offset(anchor, -8.0, -6.0), radius = 1.5 },
            { id = 'evidence', kind = 'evidence', label = 'Evidence lab', coords = offset(anchor, 10.0, -6.0), radius = 2.0 },
            { id = 'cells', kind = 'cells', label = 'Holding cells', coords = offset(anchor, -14.0, 8.0), radius = 2.5 },
            { id = 'boss', kind = 'boss', label = 'Command office', coords = offset(anchor, 12.0, 8.0), radius = 1.5, minGrade = 4 },
            { id = 'garage', kind = 'garage', label = 'Motor pool', coords = offset(anchor, 0.0, -20.0), radius = 4.0 }
        }
    }
end

local fibTower = coords(105.5, -745.2, 45.75)
local fibSandy = coords(1848.4, 3689.5, 34.27)
local iaaAnnex = coords(134.5, -761.2, 45.75)
local doaField = coords(-544.2, -204.4, 38.22)
local ussDepot = coords(2.65, -667.9, 16.13)

Config.Federal.Agencies = {
    -- Federal Investigation Bureau -------------------------------------
    {
        id = 'fib',
        label = 'Federal Investigation Bureau',
        short = 'FIB',
        -- Framework job names that count as membership. Add your server's
        -- own spelling here rather than renaming the agency.
        jobs = { 'fib', 'fbi' },
        bossGrade = 4,
        color = '#1f6feb',
        blip = { sprite = 60, color = 26, scale = 0.85 },
        callouts = true,
        cad = {
            enabled = true,
            prefix = 'FIB',
            modules = { incidents = true, warrants = true, bolos = true, evidence = true, records = true, units = true },
            -- Read-only grant. IAA agents can read FIB records; they can
            -- never write to them.
            shareWith = { 'iaa' }
        },
        ranks = ladder({
            { 0, 'Probationary Agent', SWORN },
            { 1, 'Special Agent', { 'cad.write', 'actions.arrest' } },
            { 2, 'Senior Special Agent', { 'cad.warrant' } },
            { 3, 'Supervisory Agent', { 'roster.manage', 'callout.manage' } },
            { 4, 'Assistant Director', { 'armory.manage', 'uniform.manage', 'cad.expunge' } },
            { 5, 'Director', { 'editor.manage' } }
        }),
        stations = {
            station('fib-tower', 'FIB Tower', fibTower, { sprite = 60, color = 26 }),
            station('fib-sandy', 'Sandy Shores Field Office', fibSandy, { sprite = 60, color = 26, scale = 0.7 })
        },
        uniforms = {
            placeholderUniform('field-suit', 'Field suit', 0),
            placeholderUniform('raid-kit', 'Raid kit', 2)
        },
        armory = withExtras(baseArmory(), {
            { id = 'carbine', item = 'weapon_carbinerifle', label = 'Carbine rifle', category = 'Long gun', minGrade = 2 },
            { id = 'breach', item = 'thermite', label = 'Breaching charge', category = 'Entry', minGrade = 3 }
        })
    },

    -- International Affairs Agency -------------------------------------
    {
        id = 'iaa',
        label = 'International Affairs Agency',
        short = 'IAA',
        jobs = { 'iaa' },
        bossGrade = 4,
        color = '#8957e5',
        blip = { sprite = 487, color = 27, scale = 0.85 },
        callouts = true,
        cad = {
            enabled = true,
            prefix = 'IAA',
            -- Counter-intelligence work does not issue public BOLOs.
            modules = { incidents = true, warrants = true, bolos = false, evidence = true, records = true, units = true },
            shareWith = { 'fib' }
        },
        ranks = ladder({
            { 0, 'Operations Officer', SWORN },
            { 1, 'Field Officer', { 'cad.write', 'actions.arrest' } },
            { 2, 'Case Officer', { 'cad.warrant' } },
            { 3, 'Station Chief', { 'roster.manage', 'callout.manage' } },
            { 4, 'Deputy Director', { 'armory.manage', 'uniform.manage', 'cad.expunge' } },
            { 5, 'Director', { 'editor.manage' } }
        }),
        stations = { station('iaa-annex', 'IAA Annex', iaaAnnex, { sprite = 487, color = 27 }) },
        uniforms = {
            placeholderUniform('covert', 'Covert dress', 0),
            placeholderUniform('tactical', 'Tactical loadout', 3)
        },
        armory = withExtras(baseArmory(), {
            { id = 'smg', item = 'weapon_smg', label = 'Compact SMG', category = 'Long gun', minGrade = 2 },
            { id = 'tracker', item = 'gps_tracker', label = 'GPS tracker', category = 'Surveillance', minGrade = 1 }
        })
    },

    -- Department of Alcohol & Firearms ----------------------------------
    -- The acronym came from the request; the expansion is a guess. Change
    -- `label` (and `jobs`) to whatever your server calls it.
    {
        id = 'doa',
        label = 'Department of Alcohol & Firearms',
        short = 'DOA',
        jobs = { 'doa' },
        bossGrade = 4,
        color = '#d29922',
        blip = { sprite = 110, color = 47, scale = 0.85 },
        callouts = true,
        cad = {
            enabled = true,
            prefix = 'DOA',
            modules = { incidents = true, warrants = true, bolos = true, evidence = true, records = true, units = true },
            shareWith = { 'fib' }
        },
        ranks = ladder({
            { 0, 'Inspector', SWORN },
            { 1, 'Field Inspector', { 'cad.write', 'actions.arrest' } },
            { 2, 'Senior Inspector', { 'cad.warrant' } },
            { 3, 'Group Supervisor', { 'roster.manage', 'callout.manage' } },
            { 4, 'Assistant Director', { 'armory.manage', 'uniform.manage', 'cad.expunge' } },
            { 5, 'Director', { 'editor.manage' } }
        }),
        stations = { station('doa-field', 'DOA Field Division', doaField, { sprite = 110, color = 47 }) },
        uniforms = {
            placeholderUniform('inspector', 'Inspector dress', 0),
            placeholderUniform('raid-vest', 'Raid vest', 2)
        },
        armory = withExtras(baseArmory(), {
            { id = 'shotgun', item = 'weapon_pumpshotgun', label = 'Breaching shotgun', category = 'Long gun', minGrade = 2 },
            { id = 'test-kit', item = 'field_test_kit', label = 'Substance test kit', category = 'Investigation', minGrade = 0 }
        })
    },

    -- United States Secret Service --------------------------------------
    {
        id = 'usss',
        label = 'United States Secret Service',
        short = 'USSS',
        jobs = { 'usss', 'secretservice' },
        bossGrade = 4,
        color = '#2ea043',
        blip = { sprite = 487, color = 3, scale = 0.85 },
        callouts = true,
        cad = {
            enabled = true,
            prefix = 'USSS',
            modules = { incidents = true, warrants = true, bolos = true, evidence = true, records = true, units = true },
            shareWith = { 'fib' }
        },
        ranks = ladder({
            { 0, 'Special Officer', SWORN },
            { 1, 'Special Agent', { 'cad.write', 'actions.arrest' } },
            { 2, 'Senior Agent', { 'cad.warrant' } },
            { 3, 'Detail Leader', { 'roster.manage', 'callout.manage' } },
            { 4, 'Deputy Director', { 'armory.manage', 'uniform.manage', 'cad.expunge' } },
            { 5, 'Director', { 'editor.manage' } }
        }),
        stations = { station('usss-depot', 'Union Depository Detail', ussDepot, { sprite = 487, color = 3 }) },
        uniforms = {
            placeholderUniform('protective-detail', 'Protective detail', 0),
            placeholderUniform('counter-assault', 'Counter-assault kit', 3)
        },
        armory = withExtras(baseArmory(), {
            { id = 'smg', item = 'weapon_microsmg', label = 'Concealed SMG', category = 'Long gun', minGrade = 2 },
            { id = 'earpiece', item = 'earpiece', label = 'Detail earpiece', category = 'Comms', minGrade = 0 }
        })
    }
}
