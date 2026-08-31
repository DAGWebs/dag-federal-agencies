-- DAG Federal Agencies — MySQL storage.
--
-- One table holds every record the resource owns: agencies edited in game,
-- CAD incidents/warrants/evidence, court cases, jail time, motor pools,
-- doors, divisions, application forms and submissions. Records are stored as
-- JSON per row, keyed by (collection, record_id).
--
-- MIGRATION — nothing to do by hand and no data is lost:
--   1. Have oxmysql running (standard on QBCore/txAdmin servers).
--   2. Restart dag-federal-agencies.
--   On the first start with an EMPTY table, the resource imports everything
--   from data/storage.json automatically and prints:
--     "migrating N record(s) from data/storage.json into MySQL table ..."
--   From then on the database is the authority, and data/storage.json keeps
--   being written as a live backup mirror.
--
-- The resource also creates this table itself on first start, so running
-- this file is optional - it exists so database-managed setups can create
-- the schema ahead of time.
--
-- Driver selection lives in config.lua under Config.Storage.driver:
--   'auto'  - MySQL when oxmysql is running, JSON otherwise (default)
--   'mysql' - always MySQL
--   'json'  - always the JSON file
--
-- If you renamed the resource folder, the default table name follows it
-- (resource name with non-alphanumerics replaced by underscores, plus
-- '_storage'), or set Config.Storage.table explicitly.

CREATE TABLE IF NOT EXISTS `dag_federal_agencies_storage` (
  `collection` VARCHAR(64) NOT NULL,
  `record_id` VARCHAR(128) NOT NULL,
  `data` LONGTEXT NOT NULL,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`collection`, `record_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
