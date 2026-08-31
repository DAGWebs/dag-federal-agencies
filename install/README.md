# Installation

The resource stores everything it owns (editor overrides, CAD records,
evidence, court cases, jail time, doors, applications) in **MySQL when
oxmysql is running**, falling back to `data/storage.json` otherwise. The
table creates itself and an existing storage.json is imported automatically
on the first MySQL start — see `sql/storage.sql` and `Config.Storage` in
config.lua. The JSON file keeps being written as a live backup either way.
What every framework *does* need is:

1. **The four agency jobs** — `fib`, `iaa`, `doa`, `usss` with grades 0-5.
   Membership comes from the framework job, so without them the agencies have
   no members.
2. **The items** the armory and field equipment reference, if your inventory
   validates item names (all of them do): `armour`, `evidence_kit`,
   `gps_tracker`, `field_test_kit`, `earpiece`, `surveillance_camera`,
   `spikestrip`. The weapons (`weapon_pistol`, `weapon_stungun`,
   `weapon_carbinerifle`, `weapon_smg`, `weapon_microsmg`,
   `weapon_pumpshotgun`, `thermite`) plus `radio` and `handcuffs` ship with
   every mainstream framework already.

Pick your framework below, then finish with the common steps at the bottom.

## QBCore / QBus

No SQL required — jobs and items are Lua tables in `qb-core/shared/`.

1. Merge [`qbcore/jobs.lua`](qbcore/jobs.lua) into `qb-core/shared/jobs.lua`
   (paste the four job blocks inside `QBCore.Shared.Jobs = { ... }`).
2. Merge [`qbcore/items.lua`](qbcore/items.lua) into `qb-core/shared/items.lua`
   (paste inside `QBCore.Shared.Items = { ... }`).
3. Optional: run [`../sql/qbcore.sql`](../sql/qbcore.sql) to pre-seed
   qb-banking society accounts for the four agencies. Recent qb-banking
   creates job accounts automatically from `QBCore.Shared.Jobs`, so this is
   only needed on older versions.

Item images: drop matching `.png` files (e.g. `evidence_kit.png`) into your
inventory's `html/images` folder, or the items show a placeholder icon.

## Qbox

1. Merge [`qbox/jobs.lua`](qbox/jobs.lua) into `qbx_core/shared/jobs.lua`.
2. Merge [`ox_inventory/items.lua`](ox_inventory/items.lua) into
   `ox_inventory/data/items.lua` (Qbox's inventory is ox_inventory).
   The weapons already exist in `ox_inventory/data/weapons.lua`.

## ESX (Legacy)

1. Run [`../sql/esx.sql`](../sql/esx.sql) — it inserts the four jobs into
   `jobs`/`job_grades` and the items into the legacy `items` table.
2. If you use **ox_inventory** instead of the ESX default inventory, skip the
   items half of the SQL and merge
   [`ox_inventory/items.lua`](ox_inventory/items.lua) into
   `ox_inventory/data/items.lua`.
3. Restart the server (ESX caches jobs at startup).

## Ox Core

1. Run [`../sql/ox_core.sql`](../sql/ox_core.sql) to create the four groups
   (Ox Core models jobs as groups). Check the comments in the file — the
   `ox_groups` schema differs between Ox Core versions.
2. Merge [`ox_inventory/items.lua`](ox_inventory/items.lua) into
   `ox_inventory/data/items.lua`.

## vRP

vRP forks share almost nothing; the bundled adapter covers identity only.
Define groups/jobs named `fib`, `iaa`, `doa` and `usss` in your fork's group
config, and wire job reads in with `DAG.Framework.ExtendAdapter` (see the main
README). No generic SQL can be shipped for vRP.

## Standalone

Nothing to install — the in-memory adapter fabricates jobs and inventory.
Assign jobs at runtime for testing.

## Common steps (all frameworks)

1. Ensure the framework (and `ox_inventory` where used) starts **before** this
   resource, then add to `server.cfg`:

   ```cfg
   ensure dag-federal-agencies
   ```

2. Grant the editor/admin ACE:

   ```cfg
   add_ace group.admin federal.admin allow
   ```

3. Start the server and read the capability line it prints, then in game run
   `/<resource>:fed` and use the editor to place the stations.

### The configuration GUI

`/fedconfig` opens a full configuration panel for the agency you work for.
Access: the `federal.admin` ACE (any agency), or holding the **highest rank**
of your own agency. Tabs: Agency (name, jobs, boss grade), Stations (HQ or
field office, map-icon visibility for non-members, coordinates with a
**"Use my position"** button), Ranks (labels, grades, permission checkboxes),
Divisions, Uniforms (capture what you are wearing), Armory (searchable item
catalog), Vehicles (capture the one you sit in, minimum grades), and Doors.

**Doors** lock real doors and gates for everyone through the game's door
system; members at or above a door's grade can lock/unlock it standing next
to it. Register one from the panel ("Capture the door I am aiming at" gives
you 4 seconds to aim) or with `/feddoor <agency> [grade] [name]` while aiming
at it.

**Applications** let each agency recruit through a custom form. In the
panel's Applications tab: build the questions, place application desks
(anyone can use them - they get a small map blip), and set which rank and
division an approved applicant receives. Pending applications are reviewed
from the boss menu (or `/fed` → Management → Applications): approving hires
the applicant at the configured rank and assigns the configured division in
one click; denying tells them it was declined. Applicants must be online to
be hired, one pending application per person per agency.

`/fedconfig <agency> text` prints the plain-text dump instead.

### Config commands

Everything below needs the `federal.admin` ACE (or a rank with
`editor.manage` for your own agency; the agency's highest rank always
qualifies). Stand where the thing belongs, then:

| Command | Does |
| --- | --- |
| `/fedzone <agency> <kind> [station]` | Place/move a room where you stand. Kinds: `duty` (sign-in desk), `locker`, `armory`, `evidence`, `cad`, `boss`, `cells`, `garage` |
| `/fedzoneremove <agency> <kind> [station]` | Remove a room |
| `/fedstation <agency> <label>` | Place/move a whole station where you stand |
| `/fedstationremove <agency> <id>` | Delete a station |
| `/fedaddcar <agency> [label]` | **Sitting in a vehicle:** captures it as it stands, mods and liveries included. **On foot:** opens the vehicle studio — search for a model, a preview spawns, customize it live (liveries, colours, extras, performance, wheels, tint), then save it to the motor pool |
| `/fedremovecar <agency> <id or model>` | Remove a motor pool vehicle |
| `/fedcars <agency>` | List the motor pool |
| `/feduniform <agency> [minGrade] <name>` | Save the outfit you are **wearing** as a uniform. With no name it opens the uniform studio: cycle every clothing slot live on your ped, then save |
| `/fedremoveuniform <agency> <id>` | Delete a uniform |
| `/fedadditem <agency> <item> [minGrade] [price] [label]` | Stock an armory item. With no item it opens a **searchable picker** over your server's item catalog |
| `/fedranks <agency>` | Rank loadout editor: pick a rank, then pick which uniforms, armory items and vehicles it unlocks |
| `/feddivision <agency> add\|remove\|list <name>` | Manage sub-departments; assign members from the Personnel menu |
| `/fedremoveitem <agency> <id>` | Remove an armory item |
| `/fedconfig <agency>` | Show everything configured: stations, rooms, ranks, uniforms, armory, vehicles (with the ids the remove commands take) |

Edits persist to the resource store (`data/storage.json`) and win over the
Lua config, exactly like the in-game editor.

### Contraband list

`Config.Federal.contraband` in `config.lua` is matched against **your**
server's item names. The default list includes a few names your server may not
use (for example this QBCore build has `weed_whitewidow`, not
`weed_white-widow`, and no `heroin` or `advancedlockpick` item). Searches
simply never find a name that doesn't exist — align that list with your
server's actual contraband items.
