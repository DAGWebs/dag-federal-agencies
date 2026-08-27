# DAG federal agencies

An advanced federal agencies job for FiveM: four agencies out of the box (FIB,
IAA, DOA and the Secret Service), a per-agency CAD with a full MDT, multi-station
facilities with locker rooms, armories, evidence labs and boss offices, in-game
uniform, armory and personnel management, timed and animated LEO actions,
evidence-driven investigation callouts with suspects who run and fight, 911
reports from the public, live unit tracking with a panic button, deployable
field equipment, a configurable court with bail and plea bargaining, and a jail
to serve the sentence in.

It runs **alongside** Qbox, QBCore/QBus, ESX, legacy vRP, Ox Core, or
framework-free FiveM through the bundled bridge. It never owns framework jobs,
players, accounts or inventories — your framework stays the authority on who a
player is and what they have. Jump to [Federal agencies](#federal-agencies) for
the job itself; the sections before it document the bridge and helpers it is
built on, which are also usable on their own.

## The bridge and helpers

A resource-development SDK that works alongside every supported framework. It
does not replace the active framework and it never owns framework jobs,
players, accounts, or inventories. Instead, it lets a job script, banking app,
stock market, garage, or other resource call those framework features through
one stable API.

The included menu, command, interaction, repository, and access helpers remove
boilerplate from the resource you are building. They are deliberately generic;
there is no second job system, society system, or player database hidden here.

## Install

1. Place this directory in `resources` (rename it if you like — every command,
   event and menu id is derived from the folder name).
2. Ensure the framework (and `ox_inventory` for Qbox/Ox Core) before this resource.
3. Add `ensure dag-federal-agencies` to `server.cfg`.
4. Create the framework jobs the agencies map to — `fib`, `iaa`, `doa` and
   `usss` by default — with grades 0-5. Membership comes from the framework
   job, so an agency with no matching job has no members.
5. Grant yourself the editor ACE: `add_ace group.admin federal.admin allow`.
6. Start the server and read the capability line it prints (see below).
7. In game, run `/<resource>:fed` and use the editor to move the stations to
   where your server actually wants them. The shipped coordinates are working
   starting points, not a layout anyone should have to keep.

No framework dependency is declared in the manifest, so standalone mode remains
possible. If more than one core is running, `Config.FrameworkPriority` decides.

The `<resource>:menu` and `<resource>:framework` commands in `client/main.lua`
and `server/main.lua` are bridge diagnostics; delete them once you no longer
need them.

## Unsupported operations return nil, not a plausible default

This is the most important thing to know about the bridge.

Not every framework can answer every question. Ox Core models jobs as groups,
vRP forks disagree about money, and standalone has no concept of either until
you wire one up. When the active adapter cannot implement a method:

- **reads** (`GetJob`, `GetMoney`) return `nil`
- **writes** (`AddMoney`, `SetDuty`, `CreateUseableItem`) return `false`
- a one-time line is printed naming the framework and the missing method

A read that returned `0` or `{ name = 'unemployed' }` would be worse than one
that errors, because a job gate would silently deny every player — or worse,
accidentally match a policy entry. Write your gates to treat `nil` as a denial:

```lua
local job = DAG.Framework.GetJob(source)
if not job or job.name ~= 'mechanic' then return end
```

On start, the resource prints the active framework and anything it cannot do:

```
[my-resource] framework adapter: ox
[my-resource] unsupported on this framework: createUseableItem, registerCallback
```

Check that line before shipping. `Config.ReportCapabilities = false` silences
it; `DAG.Framework.MissingCapabilities()` returns the same list at runtime, and
`DAG.Framework.Supports('setDuty')` tests one method.

## Wrapper API

Access the wrapper as `DAG.Framework` (`Bridge` below). Server methods:

```lua
local Bridge = DAG.Framework

Bridge.Detect()                          -- qbox/qb/esx/vrp/ox/standalone
Bridge.Is('qb')
Bridge.IsReady()
Bridge.AwaitReady(10000)
Bridge.Supports('setDuty')               -- feature detection
Bridge.MissingCapabilities()             -- everything this framework lacks

Bridge.GetPlayer(source)                 -- native framework player, or nil
Bridge.GetIdentifier(source)             -- always resolves (license fallback)
Bridge.GetName(source)                   -- always resolves (engine fallback)
Bridge.GetJob(source)                    -- normalized job table, or nil
Bridge.GetMoney(source, 'bank')          -- number, or nil if unsupported
Bridge.AddMoney(source, 'cash', 100, 'reward')
Bridge.RemoveMoney(source, 'cash', 25, 'purchase')
Bridge.TransferMoney(source, target, 'bank', 25, 'transfer')
Bridge.HasItem(source, 'water', 1)
Bridge.GetItemCount(source, 'water')
Bridge.AddItem(source, 'water', 1, metadata)
Bridge.RemoveItem(source, 'water', 1)
Bridge.InventoryProvider()               -- 'ox' or 'framework'
Bridge.Notify(source, 'Hello!', 'success', 5000)
Bridge.HasPermission(source, 'dag.admin')
Bridge.SetDuty(source, true)
Bridge.CreateUseableItem('water', function(source, item) end)
Bridge.RegisterCallback('my-resource:getData', function(source, reply, value)
    reply({ identifier = Bridge.GetIdentifier(source), value = value })
end)
```

Client methods:

```lua
local Bridge = DAG.Framework
local player = Bridge.GetPlayerData()
local job = Bridge.GetJob()              -- nil when nothing has loaded
Bridge.Notify('Hello!', 'success', 5000)
Bridge.TriggerCallback('my-resource:getData', function(result, err)
    if err then return end
    print(json.encode(result))
end, 'example')

Bridge.On('playerLoaded', function(playerData) end)
Bridge.On('playerUnloaded', function() end)
Bridge.On('jobUpdated', function(job) end)
```

Other resources can retrieve the same wrapper on either side:

```lua
local Bridge = exports['your-resource-name']:GetFrameworkBridge()
```

### Validation the bridge performs for you

- Money amounts must be positive and finite; `NaN` and `inf` are rejected.
- Item amounts must be positive **integers**.
- `RemoveMoney` re-reads the balance and refuses to overdraw. If the balance
  cannot be read, the removal is refused rather than attempted blind.
- `RemoveItem` refuses to take more than the player holds.
- `TransferMoney` refunds the sender if the recipient credit fails, and logs a
  `CRITICAL` line if the refund itself fails. It is still not a database
  transaction — see the banking notes below.

### Callbacks

Internal callback names, lifecycle event names, and the commands this template
registers are all derived from the current resource name, so multiple resources
created from this template can run together without sharing callback channels
or fighting over a command name. Use `Bridge.Event('name')` for your own
normalized local event names.

QBCore and ESX have native callback transports and the bridge uses them. Where
there is none, the built-in transport is used: it times out after
`Config.CallbackTimeout` (the client callback receives `nil, 'timeout'`),
replies at most once per request, contains handler errors, and applies a
per-player token bucket (`Config.CallbackRateLimit`) so one client cannot drive
unbounded server work by spamming the event.

Treat every client-provided value as untrusted and authorize in the callback.

## Provider selection and capabilities

Framework selection and inventory/notification provider selection are separate.
This lets an ESX or QBCore server use `ox_inventory` and `ox_lib` without
changing its player framework. Set `Config.Inventory` or `Config.Notify` to
`framework` to force native behavior.

> On Qbox and Ox Core the framework-native inventory **is** `ox_inventory`, so
> `Config.Inventory = 'framework'` behaves identically to `auto` there.

| Area | Qbox | QB/QBus | ESX | Ox Core | vRP | Standalone |
| --- | --- | --- | --- | --- | --- | --- |
| Identity | Yes | Yes | Yes | Yes | Yes | Engine fallback |
| Job | Yes | Yes | Yes | From groups | Extend | In-memory |
| Money | Yes | Yes | Yes | Cash only | Extend | In-memory |
| Inventory | ox_inventory | Native/ox | Native/ox | ox_inventory | Extend | In-memory |
| Useable items | Yes | Yes | Yes | Extend | Extend | Extend |
| Duty | Yes | Yes | Extend | Flag only | Extend | Yes |
| Client lifecycle events | Yes | Yes | Yes | Yes | Extend | Yes (state bag) |

"Extend" means the method is not implemented and the bridge reports it as
unsupported — add it with `ExtendAdapter` (below).

The Qbox, QBCore, ESX and standalone adapters are the well-trodden paths. The
**Ox Core adapter is best effort**: its player API changes between releases, so
every probe is guarded and degrades to "unsupported" rather than guessing.
The **vRP adapter covers identity only** — see below.

## Extending an adapter

Add framework methods from your own resource without editing the bundled files:

```lua
DAG.Framework.ExtendAdapter('vrp', {
    getMoney = function(source, account)
        local id = exports.vrp:getUserId(source)
        return id and exports.vrp:getBankMoney(id) or nil
    end,
    addMoney = function(source, account, amount)
        local id = exports.vrp:getUserId(source)
        if not id then return false end
        exports.vrp:giveBankMoney(id, amount)
        return true
    end
})
```

Adapter methods must return `true` on success and `false` on failure. Returning
an unverified `true` defeats the bridge's guards — the ESX adapter re-reads the
balance after a mutation for exactly this reason.

To add a whole framework: add its resource names to `Bridge.resourceNames`, add
its key to `Config.FrameworkPriority`, and create `bridge/client/<name>.lua`
and `bridge/server/<name>.lua` that call `Bridge.RegisterAdapter`. The
structural tests enforce that those three stay in sync.

### vRP

vRP forks share almost nothing but a name. vRP1 exposes its API through
`Proxy.getInterface`, which needs `@vrp/lib/utils.lua` in the manifest and
would make this template hard-depend on vRP. The bundled adapter therefore
probes `exports.vrp:getUserId` for identity and implements nothing else, so
economy and inventory calls report as unsupported instead of silently failing.
Use `ExtendAdapter` to wire in your fork.

## Menus

`DAG.Menu` renders one normalized menu definition through whichever provider is
available. `Config.Menu = 'auto'` picks Ox Lib, then `qb-menu`, then the
**bundled NUI menu in `ui/`** — a self-contained interface with no CDN, no
`ox_lib` and no `qb-menu` dependency. Set `Config.Menu = 'nui'` to use it even
on servers that have `ox_lib` installed.

```lua
DAG.Menu.Register({
    id = 'my-resource:garage',
    title = 'Los Santos Customs',
    subtitle = 'Sandy Shores branch',
    options = {
        { title = 'Vehicle', header = true },
        {
            title = 'Repair vehicle',
            description = 'Restores engine and body health',
            icon = 'wrench',
            badge = '$1,250',
            badgeTone = 'accent',
            serverEvent = 'my-resource:repair'
        },
        { title = 'Respray', icon = 'car', menu = 'my-resource:colours' },
        { title = 'Engine condition', icon = 'info', badge = '68%', progress = 68 },
        { title = 'Impound', icon = 'lock', disabled = true, badge = 'Locked', badgeTone = 'danger' }
    }
})

DAG.Menu.Open('my-resource:garage')
```

### Option fields

| Field | Effect |
| --- | --- |
| `title` | Row label. |
| `description` | Secondary line, clamped to two lines. |
| `icon` | A built-in glyph name, or any text/emoji rendered as-is. |
| `badge` / `badgeTone` | Right-aligned pill. Tones: `accent`, `success`, `danger`. |
| `progress` | 0-100 meter under the row, for durability/stock. |
| `header` | Renders a section label; not selectable. |
| `disabled` | Dimmed and unselectable. |
| `menu` | Opens a submenu and pushes a breadcrumb. |
| `keepOpen` | Leaves the menu open after selection. |
| `onSelect` / `event` / `serverEvent` | What the selection does. `args` is passed through. |

Built-in icons: `chevron`, `back`, `check`, `close`, `lock`, `user`, `car`,
`box`, `cash`, `wrench`, `info`. Anything else is rendered as text, so emoji
work without bundling an icon font.

### Navigation

Selecting an option with `menu` pushes onto a trail, so the UI shows a
breadcrumb and a Back affordance. `Menu.Open` from outside resets the trail;
`Menu.Back()` pops one level and closes at the root. Selecting an option closes
the menu unless it sets `keepOpen`.

```lua
DAG.Menu.Open(id)        DAG.Menu.Back()        DAG.Menu.Close()
DAG.Menu.Navigate(id)    DAG.Menu.Current()     DAG.Menu.Unregister(id)
DAG.Menu.Confirm('Delete vehicle?', 'This cannot be undone.', function(ok) end)
DAG.Menu.Input('Vehicle label', { { name = 'label', label = 'Label', required = true } }, function(values, err) end)
```

`Confirm` registers a single reusable menu and tears it down once answered, and
the callback fires at most once no matter how the dialog is dismissed.

### Theming the bundled menu

```lua
Config.MenuTheme = {
    accent = '#4c8dff',
    width = 384,        -- px
    position = 'right'  -- right, left, center, top
}
```

Every colour in `ui/style.css` is a CSS custom property on `.root`, so deeper
restyling means editing that one block. Keyboard control is arrow keys, Enter,
Backspace (back) and Escape (close); mouse hover and click work throughout.

### Previewing without running FiveM

Open `tests/ui/preview.html` in any browser. It embeds the real `ui/` files and
feeds them sample menus — icons, badges, meters, submenus, long scrolling lists,
the empty state — with live accent, width and position controls. Nothing to
install, and it is the fastest way to iterate on the design.

Handlers never cross into the browser: the NUI provider sends only display
fields and gets back an index, so `onSelect`, `serverEvent` and `args` stay in
Lua.

### Adding a provider

```lua
DAG.Menu.RegisterProvider('my-ui', {
    open = function(view) end,   -- view: id, title, subtitle, breadcrumb, canGoBack, options
    close = function() end
})
```

Call `DAG.Menu.Select(index)` from your provider when a row is chosen, and
`DAG.Menu.Back()` for a back action.

## Commands

Server commands go through `DAG.Commands.Register`, which provides console
rules, ACE/framework permissions, chat suggestions (replayed to players who
join later), error containment, and a consistent handler signature.

```lua
DAG.Commands.Register('mycommand', function(source, args, rawCommand)
    -- Always validate args and ownership on the server.
end, {
    permission = 'my-resource.admin',
    help = 'Example protected command',
    arguments = { { name = 'id', help = 'Record ID' } },
    allowConsole = false
})
```

`permission` is checked against ACE first, then the framework adapter, so
`add_ace group.admin my-resource.admin allow` works on every framework
including standalone.

Command names registered by this template are derived from the resource name,
so two resources built from it never collide. The chat fallback registers
`/<resource-name>:select` (override with `Config.ChatSelectCommand`) and is only
used when `Config.Menu = 'chat'`.

## Interactions

Register world interactions without depending on a target resource. The helper
draws a marker, shows the prompt for the **closest eligible** entry, and can
open a normalized menu or invoke a callback/event. Authorization for valuable
actions must still happen on the server.

```lua
DAG.Interactions.Register({
    id = 'mechanic:clock-in',
    coords = vector3(-347.1, -133.4, 39.0),
    label = 'Press ~INPUT_CONTEXT~ to open the mechanic menu',
    distance = 2.0,
    menu = 'mechanic:main',
    canInteract = function()
        local job = DAG.Framework.GetJob()
        return job ~= nil and job.name == 'mechanic'
    end
})

DAG.Interactions.Remove('mechanic:clock-in')
DAG.Interactions.Clear()
```

## Resource-owned storage and repositories

`DAG.Storage` is a small JSON-backed CRUD store intended for
configuration-sized records. It supplies `Get`, `All`, `Set`, `Update`,
`Delete`, `Find`, and `Save`. Reads and writes are deep-copied, so callers
cannot reach into the store by holding onto a returned table. Writes are
batched using `Config.Storage.saveInterval` (floored at 1000ms) and flushed
when the resource stops. A record that cannot be serialized fails that one
write with a logged reason instead of killing the save thread.

It is only for data owned by your resource. Do not copy framework player, job,
balance, or inventory state into it. **Do not use it for high-volume financial
transactions** — replace it with a transactional database driver for a
production banking app or stock exchange.

`DAG.Repository.Create` gives your resource a named CRUD repository with
optional validation and authorization. Validation failures return
`nil, message` rather than throwing, because they are usually driven by client
input and should not unwind the handler that produced them:

```lua
local watchlists = DAG.Repository.Create('stock_watchlists', {
    validate = function(record)
        return type(record.owner) == 'string' and type(record.symbols) == 'table',
            'A watchlist requires an owner and symbols'
    end
})

local saved, err = watchlists.save(identifier, { owner = identifier, symbols = { 'DAG' } })
if not saved then return DAG.Framework.Notify(source, err, 'error') end

watchlists.update(identifier, { symbols = { 'DAG', 'LSC' } })
watchlists.count()
watchlists.delete(identifier)
```

`DAG.Access.Allowed` supports public records, an owner, ACE permission, minimum
framework job grades, and members with per-action permissions. A job that
cannot be read is a denial, never a match. Repository authorization is always
server-side.

## Federal agencies

Everything below is the job itself. It is built entirely on the bridge above,
so it works the same on every supported framework and standalone.

### What ships configured

| Agency | Job names | CAD prefix | Notes |
| --- | --- | --- | --- |
| Federal Investigation Bureau | `fib`, `fbi` | `FIB` | Two stations; shares records with the IAA |
| International Affairs Agency | `iaa` | `IAA` | BOLOs disabled; shares records with the FIB |
| Department of Alcohol & Firearms | `doa` | `DOA` | Firearms-focused callouts and armory |
| United States Secret Service | `usss`, `secretservice` | `USSS` | Protective detail and counterfeiting work |

Membership comes from the **framework job**, not from a table this resource
owns. A player whose framework job is `fib` at grade 3 is a Supervisory Agent;
promote them in your framework and their rank here follows. Add your server's
own spelling to an agency's `jobs` list rather than renaming the agency.

`DOA` was given as an acronym without an expansion — "Department of Alcohol &
Firearms" is a guess. Change `label` in `federal/config/agencies.lua`, or
rename it in game from the editor.

### Ranks and permissions

Each agency has a rank ladder keyed to the framework job grade. A rank carries
a set of named permissions, and a permission that is not in
`federal/shared/constants.lua` is rejected when the rank is saved — a typo'd
`cad.wrtie` fails at the edit rather than silently denying every player.

| Permission | Allows |
| --- | --- |
| `cad.view` / `cad.write` | Read the CAD / file and update incidents |
| `cad.warrant` / `cad.expunge` | Issue and serve warrants / delete records |
| `armory.use` / `armory.manage` | Draw equipment / change what is stocked |
| `uniform.manage` | Create and edit uniforms |
| `roster.manage` | Manage ranks and the duty roster |
| `editor.manage` | Edit agencies, stations and zones in game |
| `callout.manage` | Dispatch, reassign and cancel callouts |
| `actions.detain` / `actions.search` | Cuff and escort / search suspects and vehicles |
| `actions.arrest` / `actions.evidence` | Book arrests and fines / collect evidence |

Two things override the ladder: the ACE permission in
`Config.Federal.adminPermission` (`federal.admin` by default) allows
everything, and reaching an agency's `bossGrade` grants the boss permissions
whatever that rank happens to list — without that, a server that rewrites the
ladder can end up with an agency nobody can administer.

```cfg
add_ace group.admin federal.admin allow
```

### Stations and zones

An agency has any number of stations, and a station has any number of rooms.
Each room is one of eight kinds, each with its own menu and its own grade gate:

`duty` (clock on, set a callsign), `locker` (change into a uniform), `armory`
(draw equipment), `evidence` (the lab), `cad` (the terminal), `boss` (command
office), `cells` (booking and release), `garage` (motor pool).

Zones are checked **server-side against the position the server reads for that
player**, never against a coordinate the client sent. Standing at the sign-in
desk is not standing in the evidence lab, and the default layouts keep every
room further apart than `Config.Federal.zoneDistance` so one marker can never
satisfy the check for another room.

### The in-game editor

Open it from the boss office or the main menu with `editor.manage`. The editor
works by **standing where the thing belongs and pressing "place here"** — the
server writes the position it reads for you, so what you see is what is stored.

- Agencies: rename, retune, set job names and boss grade, create and delete
- Stations: place, move (rooms come with it), delete
- Rooms: place any of the eight kinds, set grade and radius, remove
- Ranks: add, rename, toggle each permission, delete
- Uniforms and armory: from the boss office (below)
- Courthouses and courtroom seats: place and move (admin)

Edits are stored in the resource's own store and **replace** the seeded config
entry, so `federal/config/agencies.lua` is only ever a starting point. Deleting
a seeded agency writes a tombstone so the config cannot resurrect it on the
next restart. Every write is validated whole: a rejected edit changes nothing
and reports why.

Creating and deleting whole agencies, and editing courthouses, are admin
actions — an agency nobody belongs to yet has no rank ladder that could
authorize it.

### Uniforms

Uniforms belong to an agency and are managed by its boss, standing in the
command office. The intended flow is **wear it, then save it**: get dressed
however you want the uniform to look, then "Save my current outfit". The client
captures the ped component slots and the server stores them against the agency.

Each uniform carries a minimum grade and a body variant (`any`, `male`,
`female`), and the locker room only offers the ones that fit the player. The
uniforms in the config are placeholders built from low drawable indexes so they
render as *something* on any server — replace them by re-capturing in game.

### The CAD

Each agency gets its own CAD, configured by its `cad` block: which modules are
enabled, the case-number prefix, and which other agencies may read its records.

- **Incidents** — numbered cases with charges, suspects, assigned officers and
  a running narrative
- **Warrants** — one active warrant per subject, visible force-wide (a warrant
  only one agency can see is useless), served automatically on arrest
- **BOLOs** — persons and vehicles; can be disabled per agency
- **Citizen records** — arrests, fines and notes, keyed by framework identifier
  so they follow the character rather than the session
- **Evidence** — chain of custody, and a lab that must be stood in

`shareWith` is a **read** grant and stays one: an IAA agent can read a FIB case
and cannot write a word to it.

Evidence is the part worth understanding. Collecting a DNA swab does not tell
you whose it is — the subject is stored but hidden until the item is analysed
at an evidence lab, and an identifying analysis only ever matches somebody who
is **already on file**. That is what makes fingerprinting a suspect worth
doing, and what ties the investigation loop together.

### LEO actions

Cuff and uncuff, escort, seat in a vehicle, search a suspect, search a vehicle,
identify, fingerprint, take a DNA swab, book an arrest, issue a fine, release.

Every action re-reads both players' real positions and re-checks the officer's
rank on the server. The client supplies only a target id — never a distance,
never an item list, never a "yes I am allowed" flag. Escorting requires the
subject to be restrained first, and an arrest requires it too.

Nothing is instant. Every action runs a timed, animated, cancellable bar
(`Config.Federal.timings`) through `ox_lib` when it is running and a bundled NUI
bar otherwise, and a target who walks away mid-search has not been searched.
Taking a DNA swab is a skill check — it is the one collection step where
technique matters and a contaminated sample is a real outcome.

Searching sweeps `Config.Federal.contraband`; found items are reported and,
when `seizeOnSearch` is on, seized and filed as evidence tied to the subject
they came from. On a framework whose adapter cannot read inventories the search
**refuses and says so** rather than reporting an empty result, because an empty
report reads as "the suspect is clean".

### Investigation callouts

A callout is a multi-stage case, not a waypoint. Officers attach to one, work
its stages in order, and closing it files a real CAD incident carrying the
evidence they collected.

Stage kinds are `arrive`, `interview`, `evidence`, `search`, `arrest` and
`report`. Progress is validated server-side against what actually happened:
the `evidence` stage counts the records genuinely filed against the callout,
and the `arrest` stage for a real suspect only closes on a real arrest.
Naming a later objective does not skip ahead.

The suspect is the interesting part. When `playerSuspects` is on, a **real
player carrying an active warrant** becomes the subject of the investigation;
with nobody warranted, an NPC is spawned instead. On-duty officers are never
selected. This is what stops the warrants players write from being a dead end.

An NPC suspect is not a prop. Each one rolls a disposition at spawn — whether
they run, whether they fight if cornered, whether they are carrying — and keeps
it for the callout. An armed suspect keeps the weapon holstered until they
decide to fight, so arriving on scene is not automatically a shootout. They
surrender when outnumbered, at gunpoint, when they have run far enough, or when
cornered and unwilling to fight. **Detaining only works once they are actually
subdued**, and the prompt follows the ped, so a suspect who ran is arrested
where they are.

### Leads: what the lab tells you

Analysing evidence produces a **lead**, and a lead changes the case:

| Lead | What you get |
| --- | --- |
| Partial plate | A plate to run in the CAD, which names a keeper |
| An address | A second search location, blipped, with evidence of its own |
| A name | The subject is identified |
| A known associate | A witness who will now talk |
| Financial records | Documentary proof; strengthens the case in court |

Which lead an item yields depends on its kind, except that an item that already
**matched** somebody always names them. The suspect starts anonymous —
"Unidentified subject" — because shipping their name with the dispatch would
make every lead pointless, and an NPC suspect has no identity until a lead gives
it one: a print that matched Sam Cole means Sam Cole is who you are looking for.

Two stage kinds go with it: `investigate` counts leads actually **followed**
(not evidence merely collected) and `identify` requires the subject named.

The first officer to attach **hosts** the scene: their client spawns the
suspect, the witnesses and the evidence markers, so exactly one machine owns
them, and hosting passes on if they detach.

```lua
-- Dispatch by hand (needs callout.manage):
/<resource>:fed:dispatch fib wire-fraud
```

### Reports from the public

Callouts on a timer are the same seven cases forever. Any player can call
something in with `/<resource>:report`: it lands on the duty board with the
location the server read for the caller, blipped for every on-duty officer, and
officers respond to it and close it from there.

Reports route to an agency that **actually has units on duty**, so a call is
never filed to an empty room, and a report whose text matches a configured
keyword escalates into a full investigation callout — which is what turns a
phone call into a case. A caller can withhold their name and stays traceable
server-side. Callers are rate limited and stale reports fall off the board.

### Units, panic and dispatch

On-duty units appear on each other's maps, coloured by status. Who you see
follows the same grant as records: if you may read an agency's cases, you may
see its units. Blips clear the moment you go off duty, so a civilian is never
shown where every federal unit is.

**Panic** (`/<resource>:panic`, bindable) routes every unit to the officer with
a flashing beacon and a waypoint, and holds — an ordinary status change cannot
clear it, only the officer can.

Alerts go through one dispatch layer that picks a provider: `ps-dispatch`,
`cd_dispatch` or `linden_outlawalert` when started, and the built-in
notification when none is. Two alert systems shouting over each other is worse
than either alone, so the built-in one is suppressed by default when an external
provider is handling it.

### Field equipment

Spike strips, cones, barriers, evidence markers and cameras. The client creates
the object and the server owns the ledger of what is out and who put it there,
which is what lets an officer pick up somebody else's cones and stops one player
leaving two hundred barriers on a motorway. Items are consumed on deploy and
returned on pickup, each piece can be gated on a rank permission, and a
supervisor can clear everything the agency has out.

### The MDT

The CAD has a full terminal as well as the quick menu: a mouse-driven panel with
tabs for incidents, warrants, BOLOs, records, evidence, leads, reports, units
and custody, built from the same server callbacks. Open it at a CAD terminal
zone, from the main menu, or with `/<resource>:fedcad`.

Actions in it are filtered by rank, and the evidence tab deliberately offers no
analysis button — the lab is a place, and the server refuses it from anywhere
else.

### Personnel

`roster.manage` lets a boss run the agency's staff, standing in the command
office. Hire the person in front of you (face to face, so they have a say in
it), move people up and down the ladder, dismiss, all written to an audit log.

A boss can never appoint at or above their own grade, and cannot touch someone
who outranks them. This runs on `Bridge.SetJob`, which re-reads the job
afterwards, so a framework whose adapter cannot set jobs says so plainly instead
of letting a boss believe a promotion landed. vRP needs `setJob` added via
`ExtendAdapter` before personnel works there.

### The court process

Filed → arraignment → trial → deliberation → verdict → closed.

**Who may file is a config list of job names, not an agency permission.** That
is the extension point: `Config.Federal.court.filingJobs` already includes the
four agencies plus `police` and `sheriff`, and adding your own job to that list
is all it takes to let that job prosecute in the same system.

```lua
Config.Federal.court.filingJobs = { 'fib', 'iaa', 'doa', 'usss', 'police', 'sheriff', 'parkranger' }
Config.Federal.court.judgeJobs  = { 'judge', 'justice' }
Config.Federal.court.defenseJobs = { 'lawyer', 'attorney', 'publicdefender' }
```

Roles are judge, prosecution, defense, defendant, bailiff, juror and witness.
**Any role nobody takes is filled by an NPC**, so a case is never blocked
waiting for someone to log in:

- **No judge online** → an NPC judge is appointed and runs the case on a timer,
  entering a not-guilty plea for a defendant who never appeared and passing
  sentence from the charge catalog. A real judge is never on a timer — they
  move the case themselves, and taking the bench displaces the NPC.
- **Short jury** → NPC jurors top it up to `jury.size`. They vote on the
  **strength of the case**, which rises with admitted evidence (analysed
  evidence counts for more, and an analysed item matching the defendant counts
  for more again) and falls when a real player defends. Real jurors vote for
  themselves; a real juror who never voted is not voted for.

Sentencing comes from `Config.Federal.Charges`, keyed by the same charge text
the CAD already stores, so a charge an officer wrote flows into sentencing
without a second catalog to keep in sync. A judge may depart from the
recommendation only within `sentencing.judgeDiscretion` — discretionary, not
arbitrary. Unlisted charges fall back to `court.defaultCharge`.

**Bail** is priced from the charges and set by the judge at arraignment.
Posting it releases the defendant until trial; failing to appear forfeits the
money and draws a bench warrant, because skipping bail has to cost more than it
saves. The gravest charges (`bail.denyFor`) are not bailable.

**Plea bargaining** lets the prosecution offer a reduced sentence for a guilty
plea, bounded by `plea.minimumFactor`/`maximumFactor` so a bargain is a discount
rather than an acquittal. Accepting convicts on the agreed terms without
troubling the jury, and an agreed sentence is exempt from the discretion band —
it was bargained, not imposed.

**Continuances** let a judge put a case back when a party is missing, limited so
a defendant with a patient lawyer never simply avoids trial.

Arrests file a case automatically (`autoFileOnArrest`). Closing a case notes the
citizen record, collects the fine, pays the players who took a role, and raises
`federal:sentenced`.

Set `Config.Federal.court.enabled = false` to turn the whole court off; arrests
still book cleanly.

### The jail

A sentence puts the defendant in custody. Time is counted against a release
timestamp in wall-clock seconds rather than ticked down, so it survives a restart
and keeps running while the inmate is offline — otherwise the obvious play is to
disconnect for the length of the sentence (`jail.serveOffline` if you disagree).
A second conviction while inside runs consecutively.

Contraband is held on booking and returned on release, which makes taking it a
consequence rather than a punishment. Inmates take work details to shorten the
sentence (`/<resource>:custody`), officers get a custody roster they can release
from, and wandering out is teleported back rather than punished — most escapes
from a GTA interior are a physics accident.

**Already running a jail resource?** Set `Config.Federal.jail.enabled = false`.
`federal:sentenced` fires either way, so yours consumes it without this one
competing:

```lua
AddEventHandler(('%s:dag:federal:sentenced'):format(GetCurrentResourceName()), function(sentence)
    -- sentence: number, identifier, name, source, verdict, months, fine, charges
end)
```

### Commands

| Command | Who | Does |
| --- | --- | --- |
| `/<resource>:fed` | Members | Open the main menu |
| `/<resource>:fedcad` | `cad.view` | Open the MDT |
| `/<resource>:fedcourt` | Anyone | Open the court docket |
| `/<resource>:report` | Anyone | Call something in |
| `/<resource>:panic` | On-duty members | Panic button (bindable) |
| `/<resource>:custody` | Inmates | Time remaining and work details |
| `/<resource>:fed:duty` | Members | Toggle duty |
| `/<resource>:fed:dispatch <agency> [template]` | `callout.manage` | Dispatch a callout |
| `/<resource>:fed:status` | `federal.admin` | Agencies and who is on duty |
| `/<resource>:fed:reload` | `federal.admin` | Rebuild registry and templates |

Names are derived from the resource name, so two resources built from this
template never fight over one.

### Configuration map

| Where | What |
| --- | --- |
| `config.lua` → `Config.Federal` | Global knobs: duty, distances, contraband, fines, callouts, court, motor pool |
| `federal/config/agencies.lua` | The four agencies: stations, rooms, ranks, uniforms, armory |
| `federal/config/callouts.lua` | Investigation templates and their stages |
| `federal/config/court.lua` | Courthouses, courtroom seats and the charge catalog |

Notable knobs inside `Config.Federal`: `timings` (how long each action takes),
`hud`, `units` (tracking and panic), `reports` (911 and the escalation
keywords), `dispatch` (which provider), `equipment`, `jail`, and
`callouts.suspect` (how likely a suspect is to run, fight or be armed).

All four are **defaults**. The in-game editor overrides every one of them, and
those overrides win.

### Layout

```text
federal/
├── shared/
│   ├── constants.lua      zone kinds, permissions, court roles, evidence kinds
│   ├── util.lua           pure helpers: slugs, coords, clamping, deep merge
│   └── schema.lua         normalizing validators for every editable record
├── config/
│   ├── agencies.lua       the four default agencies
│   ├── callouts.lua       investigation templates
│   └── court.lua          courthouses and the charge catalog
├── server/
│   ├── core.lua           registry, ranks, permission gates, duty, units, panic
│   ├── cad.lua            incidents, warrants, BOLOs, records, evidence
│   ├── personnel.lua      hire, promote, dismiss, audit log
│   ├── uniforms.lua       uniform CRUD and wearing
│   ├── armory.lua         stock, drawing and the motor pool
│   ├── actions.lua        every LEO action, authorized server-side
│   ├── editor.lua         in-game editor endpoints
│   ├── dispatch.lua       one alert layer over every dispatch resource
│   ├── equipment.lua      deployable field equipment ledger
│   ├── reports.lua        911 and tip-offs from the public
│   ├── leads.lua          what analysed evidence tells you
│   ├── callouts.lua       the investigation engine
│   ├── court.lua          case lifecycle, bail, pleas, NPC judge and jury
│   ├── jail.lua           serving the sentence
│   └── commands.lua       server commands
└── client/
    ├── state.lua          cached context (never authority)
    ├── progress.lua       timed actions, animations, skill checks
    ├── uniforms.lua       outfit capture and apply
    ├── actions.lua        targeting, restraint, action menus
    ├── suspects.lua       flee, fight, surrender
    ├── cad.lua            the quick CAD screens
    ├── armory.lua         locker, armory, motor pool
    ├── dispatch.lua       built-in alert blips
    ├── equipment.lua      deploying and picking up
    ├── units.lua          colleague blips and the panic beacon
    ├── reports.lua        calling it in, and the board
    ├── leads.lua          working leads, address markers
    ├── callouts.lua       scene hosting, NPCs, objectives
    ├── court.lua          courtroom, roles, NPC judge and jury
    ├── jail.lua           being inside
    ├── personnel.lua      the boss's staff screens
    ├── editor.lua         the in-game editor
    ├── mdt.lua            the full terminal
    ├── hud.lua            the duty HUD
    ├── menus.lua          main menu, boss office, zone dispatch
    ├── zones.lua          blips and interactions from the registry
    └── bootstrap.lua      client entry point
```

Client files are listed explicitly in the manifest rather than globbed: a
globbed directory loads alphabetically, which would put `actions` before
`state` and `court` before `core`. A structural test enforces the order.

## What building alongside a framework looks like

### A job resource

Use the framework job as the authority, then add only the gameplay owned by
your resource:

```lua
RegisterNetEvent('mechanic:server:repairVehicle', function(networkId)
    local source = source
    local job = DAG.Framework.GetJob(source)
    if not job or job.name ~= 'mechanic' or job.grade < 1 then return end
    if not DAG.Framework.RemoveItem(source, 'repairkit', 1) then return end

    -- Validate the entity and distance here, then perform the repair workflow.
end)
```

The same pattern can support any framework job or role. Keep the job name,
grades, locations, menus, equipment, and gameplay rules in the resource you
build; the template only provides the normalized primitives.

### A banking app

Read and mutate the framework account through the bridge. Store only app-owned
data such as transfer descriptions or user preferences in your repository:

```lua
local balance = DAG.Framework.GetMoney(source, 'bank')
if not balance then return end   -- this framework cannot report accounts

local moved, reason = DAG.Framework.TransferMoney(source, target, 'bank', amount, 'bank-transfer')
```

Real transfers require a database transaction, idempotency key, rate limiting,
and an audit ledger; the JSON example store is not a financial ledger.

### A stock market

Keep orders, executions, and portfolios in transactional resource-owned tables.
Use `DAG.Framework.GetIdentifier` for the character key and bridge money
methods only at validated deposit/withdrawal boundaries. The framework
continues to own the player's bank balance; the stock resource owns market
state.

## Layout

```text
ui/                        bundled NUI menu (index.html, style.css, app.js)
bridge/
├── shared.lua             detection, job normalization, event namespacing
├── client.lua             normalized client API and callback transport
├── client/<framework>.lua client adapters
├── server.lua             validation and normalized server API
└── server/<framework>.lua server adapters
modules/
├── access/                record authorization policies
├── commands/              command registration and permissions
├── interactions/          world markers and prompts
├── menu/                  normalized menus across providers
├── repository/            named CRUD repositories
└── storage/               JSON-backed persistence
```

## Tests

Behaviour is tested by loading the real resource files against a FiveM native
stub, so the tests exercise the code the server runs rather than matching
source text:

```bash
lua5.4 tests/lua/run.lua              # 507 behavioural tests
python3 -m unittest discover -s tests # manifest/adapter/config invariants
luacheck .                            # lint
find . -name '*.lua' -not -path './.git/*' -print0 | xargs -0 -n1 luac5.4 -p
```

`tests/lua/harness.lua` stubs the natives the resource touches (resource state,
events, state bags, exports, storage files, markers, controls, NUI messages and
focus, plus ped appearance, blips, entities and vehicles for the federal
client). `harness.fixRandom` pins the dice so NPC juror votes are deterministic
rather than flaky. For the menu's appearance, open `tests/ui/preview.html` in a
browser. Add a `tests/lua/spec_*.lua` file and register it in
`tests/lua/run.lua` to cover new behaviour. All four commands run in CI on
every push.

The federal specs cover the parts where a mistake is expensive: permission and
duty gates, that a shared CAD grant stays read-only, that zone checks use the
server's position rather than the client's claim, that evidence hides its
subject until the lab runs it, that a callout stage cannot be skipped, and that
the court reaches a verdict with an NPC judge and a part-NPC jury.
`spec_federal_client.lua` loads the whole client stack in manifest order, which
is what catches a file touching a native at load time.

## License

MIT — see [LICENSE](LICENSE).
