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

-- An arrive stage with a real cordon: it completes only once `count` pieces
-- of field equipment (cones, barriers - the Field equipment menu) stand
-- deployed at the scene.
local function perimeter(label, count, radius)
    return {
        id = 'arrive', kind = 'arrive',
        label = label or 'Set the perimeter',
        radius = radius or 35.0,
        deploy = count or 2
    }
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
        incident = { type = 'Financial crime', charges = { 'Wire fraud', 'Identity theft' } },
        -- What ambient NPCs near the scene say when interviewed (%s becomes
        -- the suspect description). Pressing a witness can shake loose one
        -- of the `leads` lines, filed as a real lead. Every template can
        -- carry a block like this.
        investigation = {
            statements = {
                'I work the counter. %s brought in signed transfer orders, but the signatures did not match the ones on file.',
                'The manager took %s into the back office twice this week. Nobody books two private sessions for a normal transfer.',
                '%s kept taking calls in the doorway, reading out account numbers from a note.'
            },
            leads = {
                'ledger: They binned a draft transfer slip - the account numbers on it are still legible.',
                'contact: A courier picked up an envelope from them out front. Same courier does this block daily.',
                'name: The manager greeted them by a name that was NOT the name on the paperwork.'
            }
        }
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
        incident = { type = 'Violent crime', charges = { 'Kidnapping', 'Obstruction of a federal investigation' } },
        investigation = {
            statements = {
                'There was a scuffle by the underpass. %s dragged somebody toward a waiting car.',
                'I heard one short shout, then a car door. %s drove off calm, like nothing happened.',
                'Somebody was pacing here for an hour before. %s, definitely watching for a meet.'
            },
            leads = {
                'contact: A rough sleeper camps right there - he watches everything that happens on this corner.',
                'address: They asked me for directions earlier. To a specific warehouse - I can describe where.'
            }
        }
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
            perimeter('Secure the protective perimeter', 2, 30.0),
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
    },

    -- NPC callout pack ---------------------------------------------------------
    --
    -- Guaranteed-NPC cases (suspect.source = 'npc'), five per agency, each a
    -- full arc: work the scene, run the lab, follow the leads, raid, arrest -
    -- and on conviction the NPC goes through the court like anyone else.
    -- `support` marks joint operations: the listed agencies see the callout,
    -- may attach, and get the dispatch alert.

    -- FIB -----------------------------------------------------------------------
    {
        id = 'fib-crypto-laundering',
        label = 'Crypto laundering front',
        description = 'A storefront is cycling dirty money through exchange kiosks. Build the paper trail and take the operator.',
        agencies = { 'fib' }, priority = 2,
        blip = { sprite = 500, color = 26 },
        locations = { coords(-635.1, -227.9, 38.06), coords(378.5, 327.2, 103.57), coords(1135.7, -982.3, 46.42) },
        suspect = { source = 'npc', models = { 'a_m_y_business_02', 'a_m_m_business_01' } },
        witnesses = { count = 1, models = { 'a_f_y_business_01' } },
        evidence = { radius = 15.0, kinds = { 'document', 'print' } },
        stages = {
            arrive('Respond to the storefront'),
            interview('Question the clerk'),
            evidence('Seize ledgers and hardware', 3, { 'document', 'print' }),
            investigate('Run the paper trail', 1),
            identify('Identify the operator'),
            search('Search the operator'),
            arrest('Detain the operator'),
            report()
        },
        incident = { type = 'Financial crime', charges = { 'Wire fraud' } }
    },
    {
        id = 'fib-identity-mill',
        label = 'Identity mill',
        description = 'Stolen identities are being packaged and sold out of a rented office. Trace the documents to the seller.',
        agencies = { 'fib' }, priority = 2,
        blip = { sprite = 498, color = 26 },
        locations = { coords(-1080.9, -248.5, 37.76), coords(235.3, -409.4, 47.92), coords(-585.2, -1000.4, 22.34) },
        suspect = { source = 'npc', models = { 'a_m_y_smartcaspat_01', 'a_m_m_bevhills_02' } },
        witnesses = { count = 1, models = { 'a_f_m_business_02' } },
        evidence = { radius = 14.0, kinds = { 'document', 'print' } },
        stages = {
            arrive('Respond to the office'),
            evidence('Collect forged documents', 3, { 'document', 'print' }),
            investigate('Follow the document trail', 1),
            identify('Identify the seller'),
            arrest('Detain the seller'),
            report()
        },
        incident = { type = 'Financial crime', charges = { 'Identity theft' } }
    },
    {
        id = 'fib-witness-intimidation',
        label = 'Witness intimidation',
        description = 'A federal witness is being leaned on before trial. Find who is applying the pressure and stop them.',
        agencies = { 'fib' }, priority = 1,
        blip = { sprite = 458, color = 26 },
        locations = { coords(1141.6, -573.1, 64.5), coords(-14.9, -1441.2, 31.1), coords(86.9, -1959.5, 21.12) },
        suspect = { source = 'npc', models = { 'g_m_y_famca_01', 'g_m_m_armboss_01' } },
        witnesses = { count = 2, models = { 'a_m_y_bevhills_01', 'a_f_y_bevhills_01' } },
        evidence = { radius = 16.0, kinds = { 'print', 'document', 'casing' } },
        stages = {
            arrive('Get to the witness'),
            interview('Take the witness statement', 2),
            evidence('Sweep the scene', 2, { 'print', 'document', 'casing' }),
            investigate('Work the leads', 1),
            identify('Identify the enforcer'),
            arrest('Detain the enforcer'),
            report()
        },
        incident = { type = 'Obstruction', charges = { 'Obstruction of a federal investigation' } }
    },
    {
        id = 'fib-safehouse-raid',
        label = 'Fugitive safehouse',
        description = 'A tip places a wanted fugitive in a rented safehouse. Confirm, breach, and bring them in. IAA is read in.',
        agencies = { 'fib' }, support = { 'iaa' }, priority = 1,
        blip = { sprite = 484, color = 26 },
        locations = { coords(105.4, -1940.3, 20.8), coords(1204.5, -1275.6, 35.23), coords(-1620.5, -984.7, 13.02) },
        suspect = { source = 'npc', models = { 'g_m_y_lost_01', 'g_m_m_chemwork_01' } },
        witnesses = { count = 1, models = { 'a_m_m_stlat_02' } },
        evidence = { radius = 18.0, kinds = { 'print', 'property', 'casing' } },
        stages = {
            perimeter('Set the perimeter', 2),
            evidence('Confirm occupancy', 2, { 'print', 'property' }),
            search('Clear and search the safehouse'),
            arrest('Detain the fugitive'),
            report()
        },
        incident = { type = 'Fugitive operation', charges = { 'Obstruction of a federal investigation', 'Resisting a federal officer' } }
    },
    {
        id = 'fib-cold-case',
        label = 'Cold case break',
        description = 'New evidence surfaced in an old abduction. Rework the scene with modern tools and close it for good.',
        agencies = { 'fib' }, priority = 2,
        blip = { sprite = 486, color = 26 },
        locations = { coords(-409.9, 1174.8, 325.64), coords(2354.6, 3135.5, 48.2), coords(-1585.2, 2098.4, 67.94) },
        suspect = { source = 'npc', models = { 'a_m_m_hillbilly_01', 'a_m_m_farmer_01' } },
        witnesses = { count = 1, models = { 'a_f_m_tourist_01' } },
        evidence = { radius = 20.0, kinds = { 'dna', 'print', 'property' } },
        stages = {
            arrive('Return to the scene'),
            evidence('Re-process the scene', 3, { 'dna', 'print', 'property' }),
            investigate('Run the new evidence', 2),
            identify('Name the abductor'),
            arrest('Detain the abductor'),
            report()
        },
        incident = { type = 'Violent crime', charges = { 'Kidnapping' } }
    },

    -- IAA -----------------------------------------------------------------------
    {
        id = 'iaa-dead-drop',
        label = 'Dead drop intercept',
        description = 'Signals flagged a dead drop being serviced tonight. Catch the courier with the material on them.',
        agencies = { 'iaa' }, priority = 1,
        blip = { sprite = 459, color = 27 },
        locations = { coords(-1660.9, -1090.4, 13.15), coords(756.4, -776.2, 26.32), coords(-341.3, -2166.5, 10.31) },
        suspect = { source = 'npc', models = { 'a_m_y_vinewood_03', 'a_m_m_prolhost_01' } },
        witnesses = { count = 0 },
        evidence = { radius = 15.0, kinds = { 'document', 'print' } },
        stages = {
            arrive('Stake out the drop point'),
            evidence('Recover the drop', 2, { 'document', 'print' }),
            investigate('Decode the material', 1),
            identify('Identify the courier'),
            search('Search the courier'),
            arrest('Detain the courier'),
            report()
        },
        incident = { type = 'Counter-intelligence', charges = { 'Espionage' } }
    },
    {
        id = 'iaa-leak-hunt',
        label = 'Classified leak',
        description = 'Classified files walked out of a contractor site. Find the copy chain and the hands it passed through.',
        agencies = { 'iaa' }, priority = 2,
        blip = { sprite = 521, color = 27 },
        locations = { coords(-1037.7, -2737.5, 20.17), coords(464.8, -991.2, 30.69), coords(2489.3, -384.5, 94.11) },
        suspect = { source = 'npc', models = { 'a_m_y_business_03', 's_m_m_scientist_01' } },
        witnesses = { count = 1, models = { 'a_f_y_business_04' } },
        evidence = { radius = 15.0, kinds = { 'document', 'print' } },
        stages = {
            arrive('Respond to the site'),
            interview('Question the security lead'),
            evidence('Image the terminals', 3, { 'document', 'print' }),
            investigate('Trace the copies', 1),
            identify('Identify the leaker'),
            arrest('Detain the leaker'),
            report()
        },
        incident = { type = 'Counter-intelligence', charges = { 'Unlawful transfer of classified material' } }
    },
    {
        id = 'iaa-double-agent',
        label = 'Suspected double agent',
        description = 'An asset may be working both sides. Joint with the FIB: build the case before they burn the network.',
        agencies = { 'iaa' }, support = { 'fib' }, priority = 1,
        blip = { sprite = 480, color = 27 },
        locations = { coords(-75.4, -819.2, 326.17), coords(-2027.3, -465.1, 11.6), coords(925.3, 46.1, 81.09) },
        suspect = { source = 'npc', models = { 'a_m_y_business_01', 'ig_agent' } },
        witnesses = { count = 1, models = { 'a_m_m_business_01' } },
        evidence = { radius = 16.0, kinds = { 'document', 'print' } },
        stages = {
            arrive('Shadow the meet'),
            evidence('Document the exchange', 2, { 'document', 'print' }),
            investigate('Corroborate the treachery', 2),
            identify('Confirm the double agent'),
            search('Search them for tradecraft'),
            arrest('Detain the double agent'),
            report()
        },
        incident = { type = 'Counter-intelligence', charges = { 'Espionage', 'Obstruction of a federal investigation' } }
    },
    {
        id = 'iaa-listening-post',
        label = 'Illegal listening post',
        description = 'Somebody wired a safe flat into a listening post aimed at a federal facility. Roll it up quietly.',
        agencies = { 'iaa' }, priority = 2,
        blip = { sprite = 407, color = 27 },
        locations = { coords(-1130.4, -1573.4, 4.66), coords(120.1, -1290.5, 29.28), coords(2748.1, 3472.1, 55.68) },
        suspect = { source = 'npc', models = { 's_m_m_hairdress_01', 'a_m_y_hipster_01' } },
        witnesses = { count = 1, models = { 'a_f_y_hipster_02' } },
        evidence = { radius = 14.0, kinds = { 'document', 'print' } },
        stages = {
            arrive('Locate the flat'),
            evidence('Seize the equipment', 3, { 'document', 'print' }),
            investigate('Pull the recordings', 1),
            identify('Identify the operator'),
            arrest('Detain the operator'),
            report()
        },
        incident = { type = 'Counter-intelligence', charges = { 'Unlawful transfer of classified material' } }
    },
    {
        id = 'iaa-courier-cell',
        label = 'Foreign courier cell',
        description = 'A rotating cell of couriers is moving material through the port. Break one link and take the handler.',
        agencies = { 'iaa' }, priority = 2,
        blip = { sprite = 477, color = 27 },
        locations = { coords(1210.4, -2985.2, 5.87), coords(-424.9, -2789.4, 6.0), coords(816.1, -2975.7, 5.9) },
        suspect = { source = 'npc', models = { 's_m_m_dockwork_01', 'a_m_m_polynesian_01' } },
        witnesses = { count = 1, models = { 's_m_m_dockwork_01' } },
        evidence = { radius = 18.0, kinds = { 'document', 'property', 'print' } },
        stages = {
            arrive('Move on the port'),
            interview('Press the dockhand'),
            evidence('Open the container', 2, { 'document', 'property' }),
            investigate('Map the cell', 1),
            identify('Identify the handler'),
            arrest('Detain the handler'),
            report()
        },
        incident = { type = 'Counter-intelligence', charges = { 'Espionage' } }
    },

    -- DOA -----------------------------------------------------------------------
    {
        id = 'doa-gun-mill',
        label = 'Backyard gun mill',
        description = 'Machined receivers are turning up with no serials. The mill is somewhere in the county - find it.',
        agencies = { 'doa' }, priority = 2,
        blip = { sprite = 110, color = 47 },
        locations = { coords(1960.2, 3740.5, 32.34), coords(551.1, 2668.6, 42.16), coords(2433.9, 4968.6, 42.35) },
        suspect = { source = 'npc', models = { 'a_m_m_hillbilly_02', 'g_m_y_lost_03' } },
        witnesses = { count = 1, models = { 'a_f_y_rurmeth_01' } },
        evidence = { radius = 18.0, kinds = { 'property', 'print', 'casing' } },
        stages = {
            arrive('Respond to the property'),
            evidence('Collect unserialised parts', 3, { 'property', 'print' }),
            investigate('Trace the tooling', 1),
            identify('Identify the machinist'),
            search('Search the workshop'),
            arrest('Detain the machinist'),
            report()
        },
        incident = { type = 'Firearms', charges = { 'Unlicensed transfer of firearms' } }
    },
    {
        id = 'doa-straw-ring',
        label = 'Straw purchase ring',
        description = 'Clean buyers are feeding pistols to a middleman within hours of purchase. Take the middleman with the guns.',
        agencies = { 'doa' }, priority = 2,
        blip = { sprite = 154, color = 47 },
        locations = { coords(21.7, -1106.4, 29.8), coords(810.2, -2157.2, 29.62), coords(-330.3, 6083.9, 31.45) },
        suspect = { source = 'npc', models = { 'g_m_y_ballaeast_01', 'a_m_y_mexthug_01' } },
        witnesses = { count = 1, models = { 's_m_y_ammucity_01' } },
        evidence = { radius = 15.0, kinds = { 'document', 'property', 'print' } },
        stages = {
            arrive('Set up on the handoff'),
            interview('Question the store clerk'),
            evidence('Document the buys', 2, { 'document', 'property' }),
            investigate('Link the purchases', 1),
            identify('Identify the middleman'),
            search('Search the middleman'),
            arrest('Detain the middleman'),
            report()
        },
        incident = { type = 'Firearms', charges = { 'Unlicensed transfer of firearms' } }
    },
    {
        id = 'doa-arms-cache',
        label = 'Buried arms cache',
        description = 'A hiker reported disturbed earth and a rifle case in the hills. Dig it up and find who planted it.',
        agencies = { 'doa' }, priority = 3,
        blip = { sprite = 486, color = 47 },
        locations = { coords(-1585.8, 4491.7, 19.75), coords(2856.4, 5924.6, 356.71), coords(1536.9, 6329.9, 24.41) },
        suspect = { source = 'npc', models = { 'a_m_m_hillbilly_01', 'g_m_m_armlieut_01' } },
        witnesses = { count = 1, models = { 'a_m_m_tourist_01' } },
        evidence = { radius = 20.0, kinds = { 'property', 'print', 'casing' } },
        stages = {
            arrive('Hike to the cache'),
            evidence('Recover the cache', 3, { 'property', 'print', 'casing' }),
            investigate('Trace the weapons', 1),
            identify('Identify the owner'),
            arrest('Detain the owner'),
            report()
        },
        incident = { type = 'Firearms', charges = { 'Possession of an unregistered weapon' } }
    },
    {
        id = 'doa-border-runner',
        label = 'Gun runner convoy',
        description = 'A loaded convoy is staging to move crates north tonight. Joint with the FIB: hit the staging yard first.',
        agencies = { 'doa' }, support = { 'fib' }, priority = 1,
        blip = { sprite = 477, color = 47 },
        locations = { coords(1690.4, 4929.5, 42.08), coords(2664.9, 3523.5, 52.71), coords(-2172.8, 4289.1, 49.04) },
        suspect = { source = 'npc', models = { 'g_m_m_mexboss_01', 'g_m_y_mexgang_01' } },
        witnesses = { count = 1, models = { 's_m_m_trucker_01' } },
        evidence = { radius = 22.0, kinds = { 'property', 'casing', 'print' } },
        stages = {
            arrive('Move on the staging yard'),
            evidence('Open the crates', 2, { 'property', 'casing' }),
            search('Search the drivers'),
            arrest('Detain the runner'),
            report()
        },
        incident = { type = 'Firearms', charges = { 'Unlicensed transfer of firearms', 'Resisting a federal officer' } }
    },
    {
        id = 'doa-chop-shop-arsenal',
        label = 'Chop shop arsenal',
        description = 'A chop shop is fencing more than parts - a wall of unregistered long guns, by the informant\'s count.',
        agencies = { 'doa' }, priority = 2,
        blip = { sprite = 446, color = 47 },
        locations = { coords(484.1, -1315.4, 29.25), coords(-1155.4, -2007.3, 13.18), coords(2340.6, 3049.9, 48.15) },
        suspect = { source = 'npc', models = { 'g_m_y_salvaboss_01', 's_m_m_autoshop_02' } },
        witnesses = { count = 1, models = { 's_m_m_autoshop_01' } },
        evidence = { radius = 18.0, kinds = { 'property', 'print' } },
        stages = {
            arrive('Respond to the shop'),
            interview('Question the informant'),
            evidence('Photograph the arsenal', 3, { 'property', 'print' }),
            investigate('Trace the serial grinds', 1),
            identify('Identify the fence'),
            arrest('Detain the fence'),
            report()
        },
        incident = { type = 'Firearms', charges = { 'Possession of an unregistered weapon' } }
    },

    -- USSS ----------------------------------------------------------------------
    {
        id = 'usss-print-shop',
        label = 'Counterfeit print shop',
        description = 'Superdollar-grade notes hit three banks this week. The plates are close - find the press.',
        agencies = { 'usss' }, priority = 1,
        blip = { sprite = 500, color = 3 },
        locations = { coords(717.6, -962.1, 30.4), coords(-521.4, -1220.7, 18.19), coords(2340.4, 3126.5, 48.21) },
        suspect = { source = 'npc', models = { 'a_m_m_socenlat_01', 'g_m_m_chigoon_01' } },
        witnesses = { count = 1, models = { 's_m_m_bouncer_01' } },
        evidence = { radius = 16.0, kinds = { 'document', 'property', 'print' } },
        stages = {
            arrive('Respond to the print shop'),
            evidence('Seize plates and stock', 3, { 'document', 'property', 'print' }),
            investigate('Match the note runs', 1),
            identify('Identify the printer'),
            search('Search the printer'),
            arrest('Detain the printer'),
            report()
        },
        incident = { type = 'Counterfeiting', charges = { 'Counterfeiting' } }
    },
    {
        id = 'usss-bleached-bills',
        label = 'Bleached bills ring',
        description = 'Small notes bleached and reprinted big are moving through nightlife tills. Follow the paper upstream.',
        agencies = { 'usss' }, priority = 2,
        blip = { sprite = 431, color = 3 },
        locations = { coords(126.9, -1278.4, 29.27), coords(-1387.8, -618.4, 30.82), coords(1985.5, 3053.4, 47.06) },
        suspect = { source = 'npc', models = { 'a_m_y_clubcust_01', 'g_m_y_korean_01' } },
        witnesses = { count = 2, models = { 's_f_y_bartender_01', 's_m_y_barman_01' } },
        evidence = { radius = 15.0, kinds = { 'document', 'print' } },
        stages = {
            arrive('Respond to the venue'),
            interview('Question the till staff', 2),
            evidence('Pull the marked notes', 2, { 'document', 'print' }),
            investigate('Trace the passer', 1),
            identify('Identify the passer'),
            arrest('Detain the passer'),
            report()
        },
        incident = { type = 'Counterfeiting', charges = { 'Passing forged currency' } }
    },
    {
        id = 'usss-route-recon',
        label = 'Motorcade route recon',
        description = 'The same vehicle keeps photographing the protectee\'s route. Joint with the FIB: intercept the spotter.',
        agencies = { 'usss' }, support = { 'fib' }, priority = 1,
        blip = { sprite = 458, color = 3 },
        locations = { coords(-542.1, -204.4, 38.22), coords(200.3, -554.8, 43.55), coords(-1289.5, 296.7, 64.85) },
        suspect = { source = 'npc', models = { 'a_m_y_stwhi_01', 'ig_karen_daniels' } },
        witnesses = { count = 1, models = { 's_m_m_security_01' } },
        evidence = { radius = 16.0, kinds = { 'document', 'print' } },
        stages = {
            arrive('Sweep the route'),
            evidence('Recover the surveillance kit', 2, { 'document', 'print' }),
            investigate('Pull the camera roll', 1),
            identify('Identify the spotter'),
            search('Search the spotter'),
            arrest('Detain the spotter'),
            report()
        },
        incident = { type = 'Protective intelligence', charges = { 'Threatening a protected person' } }
    },
    {
        id = 'usss-skimmer-cell',
        label = 'Card skimmer cell',
        description = 'Skimmers are appearing on fuel pumps along the highway. Catch the crew servicing them.',
        agencies = { 'usss' }, priority = 2,
        blip = { sprite = 521, color = 3 },
        locations = { coords(263.9, -1261.3, 29.3), coords(1207.3, 2660.2, 37.9), coords(-2555.4, 2334.3, 33.06) },
        suspect = { source = 'npc', models = { 'a_m_y_eastsa_02', 'g_m_y_armgoon_02' } },
        witnesses = { count = 1, models = { 'mp_m_shopkeep_01' } },
        evidence = { radius = 14.0, kinds = { 'document', 'print' } },
        stages = {
            arrive('Respond to the station'),
            evidence('Pull the skimmers', 2, { 'document', 'print' }),
            investigate('Read the dumps', 1),
            identify('Identify the crew lead'),
            arrest('Detain the crew lead'),
            report()
        },
        incident = { type = 'Financial crime', charges = { 'Identity theft' } }
    },
    {
        id = 'usss-threat-letters',
        label = 'Threat letters',
        description = 'Letters naming a protectee keep arriving from inside the city. Work the physical evidence back to a hand.',
        agencies = { 'usss' }, priority = 2,
        blip = { sprite = 525, color = 3 },
        locations = { coords(-425.5, -2789.3, 6.0), coords(78.9, 112.3, 81.17), coords(-212.1, -862.7, 30.27) },
        suspect = { source = 'npc', models = { 'a_m_m_tramp_01', 'a_m_y_methhead_01' } },
        witnesses = { count = 1, models = { 's_m_m_postal_01' } },
        evidence = { radius = 14.0, kinds = { 'document', 'dna', 'print' } },
        stages = {
            arrive('Respond to the sorting office'),
            interview('Question the sorter'),
            evidence('Bag the letters', 3, { 'document', 'dna', 'print' }),
            investigate('Run the handwriting and DNA', 2),
            identify('Name the author'),
            arrest('Detain the author'),
            report()
        },
        incident = { type = 'Protective intelligence', charges = { 'Threatening a protected person' } }
    }
}
