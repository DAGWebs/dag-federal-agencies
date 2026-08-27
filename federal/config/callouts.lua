-- Investigation callout templates.
--
-- A callout is a multi-stage case, not a waypoint: officers arrive, work the
-- scene, interview a witness, collect physical evidence, and only then detain
-- a suspect. Progress on every stage is reported by the client but validated
-- on the server against the stage's kind and the officer's real position, so a
-- stage cannot be skipped.
--
-- Stage kinds: arrive, interview, evidence, investigate, identify, search,
-- arrest, report. `investigate` requires leads produced by the lab to have
-- been followed, and `identify` requires one of them to have named the
-- subject -- which is what makes analysing evidence worth doing.
--
-- `suspect.source`:
--   'auto'   prefer a real player carrying an active warrant, else spawn an NPC
--   'player' only run when a real warranted player is online
--   'npc'    always spawn an NPC
--
-- Locations are pools; one is drawn per dispatch. They are ordinary Los Santos
-- coordinates and are meant to be edited — a callout that always fires in the
-- same four places stops being interesting quickly.

local function coords(x, y, z)
    return { x = x, y = y, z = z }
end

-- Stage constructors. Each returns the shape the server's progress validator
-- expects; using these instead of raw tables keeps a typo'd `kind` out of the
-- catalog, because an unknown kind is rejected when the template is loaded.
local function arrive(label, radius)
    return { id = 'arrive', kind = 'arrive', label = label or 'Respond to the scene', radius = radius or 25.0 }
end

local function interview(label, count)
    return { id = 'interview', kind = 'interview', label = label or 'Interview the witness', count = count or 1 }
end

local function evidence(label, count, kinds)
    return { id = 'evidence', kind = 'evidence', label = label, count = count or 2, kinds = kinds }
end

local function search(label)
    return { id = 'search', kind = 'search', label = label or 'Search the suspect for contraband' }
end

-- Requires evidence to have been analysed at the lab and the leads it produced
-- actually followed. This is the stage that makes the lab worth the trip.
local function investigate(label, count)
    return { id = 'investigate', kind = 'investigate', label = label or 'Follow up the leads', count = count or 1 }
end

-- The subject is anonymous until a lead names them.
local function identify(label)
    return { id = 'identify', kind = 'identify', label = label or 'Identify the subject' }
end

local function arrest(label)
    return { id = 'arrest', kind = 'arrest', label = label or 'Detain the suspect' }
end

local function report(label)
    return { id = 'report', kind = 'report', label = label or 'File the incident report' }
end

Config.Federal.Callouts = {
    {
        id = 'wire-fraud',
        label = 'Suspected wire fraud',
        description = 'A business has flagged a series of transfers to a shell account. Work the scene and identify who moved the money.',
        agencies = { 'fib' },
        priority = 2,
        blip = { sprite = 498, color = 26 },
        locations = {
            coords(215.4, -810.2, 30.73),
            coords(-704.1, -292.4, 35.51),
            coords(1050.6, -750.3, 58.03)
        },
        suspect = { source = 'auto', models = { 'a_m_y_business_01', 'a_m_m_business_01' } },
        witnesses = { count = 1, models = { 'a_f_y_business_02' } },
        evidence = { radius = 14.0, kinds = { 'document', 'print' } },
        stages = {
            arrive('Respond to the reporting business'),
            interview('Interview the branch manager'),
            evidence('Recover the transfer records and prints', 2, { 'document', 'print' }),
            investigate('Analyse the evidence and work the leads', 1),
            identify('Identify the account holder'),
            arrest('Detain the account holder'),
            report()
        },
        incident = { type = 'Financial crime', charges = { 'Wire fraud', 'Identity theft' } }
    },

    {
        id = 'informant-dark',
        label = 'Informant has gone dark',
        description = 'A confidential informant missed a scheduled contact. Sweep the meeting site and establish what happened.',
        agencies = { 'fib', 'iaa' },
        priority = 3,
        blip = { sprite = 280, color = 1 },
        locations = {
            coords(-1604.2, -1013.5, 13.02),
            coords(101.7, -2903.4, 6.11),
            coords(-1032.6, -2729.8, 13.75)
        },
        suspect = { source = 'npc', models = { 'g_m_y_lost_01', 'g_m_m_armboss_01' } },
        witnesses = { count = 1, models = { 'a_m_y_downtown_01' } },
        evidence = { radius = 18.0, kinds = { 'casing', 'dna', 'print' } },
        stages = {
            arrive('Reach the last known contact point', 30.0),
            evidence('Process the meeting site', 3, { 'casing', 'dna', 'print' }),
            investigate('Run the samples and work the leads', 2),
            interview('Canvass the area for a witness'),
            arrest('Detain the person responsible'),
            report()
        },
        incident = { type = 'Violent crime', charges = { 'Kidnapping', 'Obstruction of a federal investigation' } }
    },

    {
        id = 'foreign-asset',
        label = 'Foreign asset surveillance',
        description = 'Signals traffic places a foreign asset at this location. Establish identity and recover anything they were carrying.',
        agencies = { 'iaa' },
        priority = 2,
        blip = { sprite = 487, color = 27 },
        locations = {
            coords(-75.4, -819.9, 326.18),
            coords(300.2, 200.4, 104.38),
            coords(-1200.3, -1500.1, 4.41)
        },
        suspect = { source = 'auto', models = { 'a_m_m_eastsa_02', 'a_m_y_vinewood_02' } },
        witnesses = { count = 0 },
        evidence = { radius = 12.0, kinds = { 'document', 'dna' } },
        stages = {
            arrive('Take up an observation position'),
            evidence('Recover the dead drop', 2, { 'document', 'dna' }),
            investigate('Analyse the drop and work the leads', 1),
            identify('Identify the asset'),
            search('Search the asset'),
            arrest('Detain the asset for questioning'),
            report()
        },
        incident = { type = 'Counter-intelligence', charges = { 'Espionage', 'Unlawful transfer of classified material' } }
    },

    {
        id = 'unlicensed-transfer',
        label = 'Unlicensed firearms transfer',
        description = 'A tip places an unlicensed firearms sale here. Identify the seller and seize the merchandise.',
        agencies = { 'doa' },
        priority = 2,
        blip = { sprite = 110, color = 47 },
        locations = {
            coords(1960.4, 3740.2, 32.34),
            coords(800.6, -1700.4, 29.71),
            coords(1700.2, 4900.5, 42.06)
        },
        suspect = { source = 'auto', models = { 'a_m_m_hillbilly_01', 'g_m_y_lost_02' } },
        witnesses = { count = 1, models = { 'a_m_m_farmer_01' } },
        evidence = { radius = 16.0, kinds = { 'weapon', 'casing', 'print' } },
        stages = {
            arrive('Approach the transfer point'),
            interview('Interview the tipster'),
            search('Search the seller'),
            evidence('Seize and log the merchandise', 2, { 'weapon', 'casing' }),
            arrest('Detain the seller'),
            report()
        },
        incident = { type = 'Firearms', charges = { 'Unlicensed transfer of firearms', 'Possession of an unregistered weapon' } }
    },

    {
        id = 'counterfeit-passing',
        label = 'Counterfeit currency passing',
        description = 'Marked bills have surfaced at this business. Trace them back to whoever passed them.',
        agencies = { 'usss' },
        priority = 2,
        blip = { sprite = 434, color = 3 },
        locations = {
            coords(2.65, -667.9, 16.13),
            coords(215.4, -810.2, 30.73),
            coords(-1222.1, -906.5, 12.33)
        },
        suspect = { source = 'auto', models = { 'a_m_y_hipster_01', 'a_m_m_business_01' } },
        witnesses = { count = 1, models = { 'a_f_m_business_02' } },
        evidence = { radius = 12.0, kinds = { 'document', 'print' } },
        stages = {
            arrive('Respond to the reporting business'),
            interview('Interview the cashier'),
            evidence('Recover the marked bills', 2, { 'document', 'print' }),
            investigate('Trace the bills back', 1),
            search('Search the passer'),
            arrest('Detain the passer'),
            report()
        },
        incident = { type = 'Financial crime', charges = { 'Counterfeiting', 'Passing forged currency' } }
    },

    {
        id = 'protectee-threat',
        label = 'Threat against a protectee',
        description = 'A credible threat was made against a protected person. Sweep the site and locate the source.',
        agencies = { 'usss', 'fib' },
        priority = 3,
        blip = { sprite = 487, color = 1 },
        locations = {
            coords(-544.2, -204.4, 38.22),
            coords(-1370.1, -500.3, 30.29),
            coords(105.5, -745.2, 45.75)
        },
        suspect = { source = 'auto', models = { 'a_m_y_methhead_01', 'a_m_m_tramp_01' } },
        witnesses = { count = 1, models = { 's_m_m_security_01' } },
        evidence = { radius = 15.0, kinds = { 'document', 'print', 'dna' } },
        stages = {
            arrive('Secure the protective perimeter', 30.0),
            interview('Interview the detail supervisor'),
            evidence('Process the threat material', 2, { 'document', 'print', 'dna' }),
            investigate('Work the leads from the material', 1),
            identify('Identify the source of the threat'),
            arrest('Detain the source of the threat'),
            report()
        },
        incident = { type = 'Protective intelligence', charges = { 'Threatening a protected person' } }
    },

    {
        id = 'stolen-federal-property',
        label = 'Stolen federal property',
        description = 'Federal equipment was reported stolen from this site. Recover what you can and identify the crew.',
        agencies = { 'fib', 'doa', 'usss' },
        priority = 1,
        blip = { sprite = 478, color = 5 },
        locations = {
            coords(-100.4, 6460.2, 31.63),
            coords(101.7, -2903.4, 6.11),
            coords(1848.4, 3689.5, 34.27)
        },
        suspect = { source = 'npc', models = { 'a_m_y_stbla_01', 'g_m_y_ballasout_01' } },
        witnesses = { count = 1, models = { 's_m_y_construct_01' } },
        evidence = { radius = 20.0, kinds = { 'property', 'print', 'casing' } },
        stages = {
            arrive('Reach the reported site'),
            evidence('Recover the stolen property', 3, { 'property', 'print', 'casing' }),
            interview('Interview the site foreman'),
            arrest('Detain the suspect'),
            report()
        },
        incident = { type = 'Property crime', charges = { 'Theft of federal property' } }
    }
}
