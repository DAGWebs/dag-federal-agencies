-- DAG Federal Agencies — ESX Legacy.
--
-- Inserts the four agency jobs with grades 0-5 and the items the armory and
-- field equipment reference. Safe to re-run: INSERT IGNORE skips rows that
-- already exist. Restart the server afterwards — ESX caches jobs at startup.
--
-- If you run ox_inventory on ESX, skip the items section at the bottom and
-- merge install/ox_inventory/items.lua instead.

-- Jobs -----------------------------------------------------------------

INSERT IGNORE INTO `jobs` (`name`, `label`) VALUES
    ('fib',  'Federal Investigation Bureau'),
    ('iaa',  'International Affairs Agency'),
    ('doa',  'Department of Alcohol & Firearms'),
    ('usss', 'United States Secret Service');

-- Some ESX builds have a `whitelisted` column; if yours does and you want
-- these jobs whitelisted, run:
-- UPDATE `jobs` SET `whitelisted` = 1 WHERE `name` IN ('fib','iaa','doa','usss');

INSERT IGNORE INTO `job_grades` (`job_name`, `grade`, `name`, `label`, `salary`, `skin_male`, `skin_female`) VALUES
    ('fib', 0, 'probationary',   'Probationary Agent',   500,  '{}', '{}'),
    ('fib', 1, 'agent',          'Special Agent',        750,  '{}', '{}'),
    ('fib', 2, 'senioragent',    'Senior Special Agent', 900,  '{}', '{}'),
    ('fib', 3, 'supervisor',     'Supervisory Agent',    1100, '{}', '{}'),
    ('fib', 4, 'assistantdirector', 'Assistant Director', 1400, '{}', '{}'),
    ('fib', 5, 'director',       'Director',             1800, '{}', '{}'),

    ('iaa', 0, 'operations',     'Operations Officer',   500,  '{}', '{}'),
    ('iaa', 1, 'fieldofficer',   'Field Officer',        750,  '{}', '{}'),
    ('iaa', 2, 'caseofficer',    'Case Officer',         900,  '{}', '{}'),
    ('iaa', 3, 'stationchief',   'Station Chief',        1100, '{}', '{}'),
    ('iaa', 4, 'deputydirector', 'Deputy Director',      1400, '{}', '{}'),
    ('iaa', 5, 'director',       'Director',             1800, '{}', '{}'),

    ('doa', 0, 'inspector',      'Inspector',            500,  '{}', '{}'),
    ('doa', 1, 'fieldinspector', 'Field Inspector',      750,  '{}', '{}'),
    ('doa', 2, 'seniorinspector','Senior Inspector',     900,  '{}', '{}'),
    ('doa', 3, 'groupsupervisor','Group Supervisor',     1100, '{}', '{}'),
    ('doa', 4, 'assistantdirector', 'Assistant Director', 1400, '{}', '{}'),
    ('doa', 5, 'director',       'Director',             1800, '{}', '{}'),

    ('usss', 0, 'specialofficer','Special Officer',      500,  '{}', '{}'),
    ('usss', 1, 'agent',         'Special Agent',        750,  '{}', '{}'),
    ('usss', 2, 'senioragent',   'Senior Agent',         900,  '{}', '{}'),
    ('usss', 3, 'detailleader',  'Detail Leader',        1100, '{}', '{}'),
    ('usss', 4, 'deputydirector','Deputy Director',      1400, '{}', '{}'),
    ('usss', 5, 'director',      'Director',             1800, '{}', '{}');

-- Items (ESX default inventory only) -----------------------------------
--
-- ESX treats weapons separately (not items), so only the gear items are
-- inserted here. Skip this section entirely if you use ox_inventory.

INSERT IGNORE INTO `items` (`name`, `label`, `weight`) VALUES
    ('armour',              'Body Armour',              5),
    ('evidence_kit',        'Evidence Collection Kit',  1),
    ('gps_tracker',         'GPS Tracker',              1),
    ('field_test_kit',      'Substance Test Kit',       1),
    ('earpiece',            'Detail Earpiece',          1),
    ('surveillance_camera', 'Surveillance Camera',      2),
    ('spikestrip',          'Spike Strip',              3),
    ('radio',               'Radio',                    2),
    ('handcuffs',           'Handcuffs',                1),
    ('thermite',            'Thermite',                 1);
