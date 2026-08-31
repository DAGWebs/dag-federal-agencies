-- DAG Federal Agencies — ox_inventory items.
--
-- For Qbox, Ox Core, or any QBCore/ESX server running ox_inventory.
-- Paste the block below inside the table in ox_inventory/data/items.lua.
-- Skip any item your server already defines.
--
-- Weapons (WEAPON_PISTOL, WEAPON_STUNGUN, WEAPON_CARBINERIFLE, WEAPON_SMG,
-- WEAPON_MICROSMG, WEAPON_PUMPSHOTGUN) already exist in data/weapons.lua.
-- radio, handcuffs and thermite exist on most servers — add them here too if
-- yours lacks them.
--
-- The default armory issues 'armour' (as configured in
-- federal/config/agencies.lua); if your server already has an 'armor' item,
-- either keep this entry or change the agency config to your spelling.

['armour'] = {
    label = 'Body Armour',
    weight = 5000,
    stack = false,
    close = true,
    description = 'Agency-issue ballistic vest.',
},

['evidence_kit'] = {
    label = 'Evidence Collection Kit',
    weight = 1000,
    stack = true,
    close = true,
    description = 'Swabs, print tape and evidence bags.',
},

['gps_tracker'] = {
    label = 'GPS Tracker',
    weight = 250,
    stack = true,
    close = true,
    description = 'Magnetic covert tracking unit.',
},

['field_test_kit'] = {
    label = 'Substance Test Kit',
    weight = 500,
    stack = true,
    close = true,
    description = 'Reagent kit for identifying substances in the field.',
},

['earpiece'] = {
    label = 'Detail Earpiece',
    weight = 100,
    stack = true,
    close = true,
    description = 'Discreet radio earpiece.',
},

['surveillance_camera'] = {
    label = 'Surveillance Camera',
    weight = 2000,
    stack = true,
    close = true,
    description = 'Deployable surveillance camera.',
},

['spikestrip'] = {
    label = 'Spike Strip',
    weight = 3000,
    stack = true,
    close = true,
    description = 'Deployable tyre-deflation strip.',
},

['fed_tablet'] = {
    label = 'MDT Tablet',
    weight = 1000,
    stack = false,
    close = true,
    description = 'Federal mobile data terminal. Credentials required.',
},

['evidence_bag'] = {
    label = 'Evidence Bag',
    weight = 50,
    stack = true,
    close = true,
    description = 'Tamper-evident bag for sealing evidence at a scene.',
},

['bagged_evidence'] = {
    label = 'Sealed Evidence',
    weight = 500,
    stack = false,
    close = true,
    description = 'A sealed evidence bag. Check it into an evidence locker.',
},
