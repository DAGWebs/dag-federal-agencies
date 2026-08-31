-- DAG Federal Agencies — Ox Core.
--
-- Ox Core models jobs as GROUPS. The bridge reads a player's active group as
-- their job, so create groups named fib, iaa, doa and usss with grades 0-5.
--
-- NOTE: the ox_groups schema has changed between Ox Core releases. The
-- statement below targets the common schema where `grades` is a JSON array of
-- grade labels (index 1 = grade 0). If your build defines groups in a data
-- file or uses different columns, transcribe the same names/labels/grades
-- there instead — the names are what matter to this resource.
--
-- Items go in ox_inventory: merge install/ox_inventory/items.lua.

INSERT IGNORE INTO `ox_groups` (`name`, `label`, `grades`) VALUES
    ('fib',  'Federal Investigation Bureau',
     '["Probationary Agent","Special Agent","Senior Special Agent","Supervisory Agent","Assistant Director","Director"]'),
    ('iaa',  'International Affairs Agency',
     '["Operations Officer","Field Officer","Case Officer","Station Chief","Deputy Director","Director"]'),
    ('doa',  'Department of Alcohol & Firearms',
     '["Inspector","Field Inspector","Senior Inspector","Group Supervisor","Assistant Director","Director"]'),
    ('usss', 'United States Secret Service',
     '["Special Officer","Special Agent","Senior Agent","Detail Leader","Deputy Director","Director"]');
