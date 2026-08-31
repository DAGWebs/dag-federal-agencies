-- DAG Federal Agencies — QBCore items.
--
-- Paste the block below inside `QBCore.Shared.Items = { ... }` in
-- qb-core/shared/items.lua. Skip any item your server already defines.
--
-- The armory and field equipment also reference items every stock QBCore
-- already ships: radio, handcuffs, thermite, weapon_pistol, weapon_stungun,
-- weapon_carbinerifle, weapon_smg, weapon_microsmg, weapon_pumpshotgun.
--
-- Note: the default armory issues 'armour' (British spelling, as configured
-- in federal/config/agencies.lua). If you would rather reuse QBCore's stock
-- 'armor' item, change that one line in the agency config instead of adding
-- the item here.
--
-- Add matching .png images to your inventory's html/images folder or the
-- items render with a placeholder icon.

-- DAG Federal Agencies
armour = { name = 'armour', label = 'Body Armour', weight = 5000, type = 'item', image = 'armor.png', unique = false, useable = true, shouldClose = true, description = 'Agency-issue ballistic vest.' },
evidence_kit = { name = 'evidence_kit', label = 'Evidence Collection Kit', weight = 1000, type = 'item', image = 'evidence_kit.png', unique = false, useable = false, shouldClose = true, description = 'Swabs, print tape and evidence bags.' },
gps_tracker = { name = 'gps_tracker', label = 'GPS Tracker', weight = 250, type = 'item', image = 'gps_tracker.png', unique = false, useable = false, shouldClose = true, description = 'Magnetic covert tracking unit.' },
field_test_kit = { name = 'field_test_kit', label = 'Substance Test Kit', weight = 500, type = 'item', image = 'field_test_kit.png', unique = false, useable = false, shouldClose = true, description = 'Reagent kit for identifying substances in the field.' },
earpiece = { name = 'earpiece', label = 'Detail Earpiece', weight = 100, type = 'item', image = 'earpiece.png', unique = false, useable = false, shouldClose = true, description = 'Discreet radio earpiece.' },
surveillance_camera = { name = 'surveillance_camera', label = 'Surveillance Camera', weight = 2000, type = 'item', image = 'surveillance_camera.png', unique = false, useable = false, shouldClose = true, description = 'Deployable surveillance camera.' },
spikestrip = { name = 'spikestrip', label = 'Spike Strip', weight = 3000, type = 'item', image = 'spikestrip.png', unique = false, useable = false, shouldClose = true, description = 'Deployable tyre-deflation strip.' },
fed_tablet = { name = 'fed_tablet', label = 'MDT Tablet', weight = 1000, type = 'item', image = 'fed_tablet.png', unique = true, useable = true, shouldClose = true, description = 'Federal mobile data terminal. Credentials required.' },
evidence_bag = { name = 'evidence_bag', label = 'Evidence Bag', weight = 50, type = 'item', image = 'evidence.png', unique = false, useable = false, shouldClose = true, description = 'Tamper-evident bag for sealing evidence at a scene.' },
bagged_evidence = { name = 'bagged_evidence', label = 'Sealed Evidence', weight = 500, type = 'item', image = 'evidence.png', unique = true, useable = false, shouldClose = true, description = 'A sealed evidence bag. Check it into an evidence locker.' },
