-- DAG Federal Agencies — QBCore (optional).
--
-- QBCore needs NO SQL for this resource: jobs and items are Lua tables in
-- qb-core/shared/jobs.lua and items.lua — see install/qbcore/.
--
-- This file only pre-seeds qb-banking society ("job") accounts for the four
-- agencies so boss menus have an account from day one. Recent qb-banking
-- versions create these automatically from QBCore.Shared.Jobs on startup, in
-- which case running this is harmless but unnecessary.
--
-- Requires the bank_accounts table from qb-banking/banking.sql to exist.
-- Safe to re-run: INSERT IGNORE skips accounts that already exist.

INSERT IGNORE INTO `bank_accounts` (`account_name`, `account_balance`, `account_type`) VALUES
    ('fib',  0, 'job'),
    ('iaa',  0, 'job'),
    ('doa',  0, 'job'),
    ('usss', 0, 'job');
