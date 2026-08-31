Config = {}

-- auto selects the first started framework in priority order. You can instead
-- use: qbox, qb, esx, vrp, ox, or standalone.
Config.Framework = 'auto'

Config.FrameworkPriority = { 'qbox', 'qb', 'esx', 'vrp', 'ox', 'standalone' }
Config.Debug = false

-- Prints the active framework and any adapter methods it does not implement
-- when the resource starts. Leave this on: unsupported reads return nil, and
-- the startup line is where you find out which ones before shipping.
Config.ReportCapabilities = true

-- auto prefers ox_inventory/ox_lib when they are started, then falls back to
-- the selected framework. Set either option to 'framework' to disable this.
-- Note: on Qbox and Ox Core the framework-native inventory IS ox_inventory,
-- so 'framework' behaves identically to 'auto' on those cores.
Config.Inventory = 'auto' -- auto, ox, framework
-- 'nui' renders this resource's notifications as bottom-right toasts in the
-- bundled UI, out from under HUDs that cover the framework's notify area.
Config.Notify = 'nui' -- auto, nui, ox, framework, chat
-- auto: ox_lib, then qb-menu, then the bundled NUI menu in ui/.
-- Set 'nui' to always use the bundled menu even when ox_lib is installed.
-- 'chat' is a text-only fallback for servers that cannot run NUI.
Config.Menu = 'nui' -- auto, nui, ox, qb, chat

-- Applied to the bundled NUI menu only.
Config.MenuTheme = {
    accent = '#4c8dff',
    width = 384,          -- px
    position = 'right'    -- right, left, center, top
}

-- Name of the chat-fallback selection command, used only when no menu resource
-- is running. Defaults to '<resource-name>:select' so two resources built from
-- this template never register the same command.
Config.ChatSelectCommand = nil

Config.CallbackTimeout = 15000

-- Token bucket applied to the built-in callback transport, per player. Set to
-- false to disable. Frameworks with a native callback transport (QB, ESX) use
-- their own and are unaffected.
Config.CallbackRateLimit = { window = 10000, max = 40 }

Config.InteractionKey = 38 -- INPUT_CONTEXT / E
Config.InteractionDrawDistance = 15.0
Config.InteractionDistance = 2.0

Config.Storage = {
    file = 'data/storage.json',
    saveInterval = 5000, -- clamped to a 1000ms floor

    -- Where records live. 'auto' uses MySQL (through oxmysql) whenever it is
    -- running and falls back to the JSON file otherwise; the JSON file keeps
    -- being written as a live backup either way. On the first MySQL start an
    -- existing storage.json is imported automatically, so switching drivers
    -- never loses data. See sql/storage.sql.
    driver = 'auto', -- auto, mysql, json

    -- Database table name. nil derives it from the resource name
    -- (dag_federal_agencies_storage).
    table = nil
}

-- Ox Core keeps cash as an ox_inventory item; change this if your server
-- renamed it. Other Ox Core accounts are reported as unsupported.
Config.Ox = {
    moneyItem = 'money'
}

-- Used only by the standalone adapter. Replace these hooks with your own
-- persistence/inventory implementation for a production standalone server.
Config.Standalone = {
    startingCash = 0,
    defaultJob = { name = 'unemployed', label = 'Unemployed', grade = 0, gradeName = 'none' }
}

-- Federal agencies -------------------------------------------------------
--
-- The agency, station, uniform, armory and rank catalogs live in
-- federal/config/agencies.lua; investigation callouts live in
-- federal/config/callouts.lua. Everything in both files is a *default*: the
-- in-game editor writes overrides into the resource store and those win, so a
-- server owner never has to edit Lua to move a station or add a uniform.
Config.Federal = {
    enabled = true,

    -- ACE permission that unlocks the in-game editor and boss actions for
    -- anyone holding it, regardless of their framework job or rank. Grant it
    -- with: add_ace group.admin federal.admin allow
    adminPermission = 'federal.admin',

    -- Clocking on is required before armory, CAD writes and LEO actions are
    -- allowed. Set false on servers that treat the framework job as duty.
    requireDuty = true,

    -- Blips for every configured station.
    blips = true,

    -- Live unit tracking. Officers who cannot see each other cannot back each
    -- other up, and a roster in a menu is not the same as a blip on the map.
    units = {
        enabled = true,
        -- How often positions are broadcast to the agency, in ms. Every second
        -- is smooth and cheap; raise it on a very large server.
        interval = 3000,
        -- Show units from agencies that share records with yours.
        shared = true,
        -- Panic. The one status that has to do something: it locks the
        -- officer's blip to flashing, routes everyone to them, and holds until
        -- they clear it themselves.
        panic = { duration = 120, sound = true, route = true }
    },

    -- How close a player must be to a station zone to use it. Checked on the
    -- server against the player's real position, not the client's claim.
    zoneDistance = 4.0,

    -- Maximum distance between an officer and the player or vehicle they are
    -- acting on. Every LEO action re-checks this server-side.
    actionDistance = 4.0,

    -- Items a suspect or vehicle search looks for. Searching reports only
    -- these, so the list doubles as the contraband definition for your server.
    contraband = {
        'weapon_pistol', 'weapon_smg', 'weapon_assaultrifle', 'weapon_sniperrifle',
        'lockpick', 'thermite', 'advancedlockpick', 'cocaine', 'meth', 'heroin',
        'weed_white-widow', 'markedbills', 'goldbar'
    },

    -- Seizing moves contraband out of the suspect and files it as evidence.
    seizeOnSearch = true,

    -- Fines written from the CAD. Bounds are enforced on the server.
    fines = { account = 'bank', minimum = 50, maximum = 50000 },

    -- The radio traffic key: opens the quick call menu (show me en route /
    -- on scene / code 6 / back in service / panic). Rebindable per player
    -- under FiveM key bindings; LMENU is left Alt.
    radio = { defaultKey = 'LMENU' },

    -- Vehicle keys for motor pool spawns. Detection is automatic for
    -- qb-vehiclekeys, qbx_vehiclekeys, qs-vehiclekeys, wasabi_carlock,
    -- MrNewbVehicleKeys and mk_vehiclekeys. For anything else, wire your key
    -- script here: `clientEvent` is fired with (plate, vehicle), and/or
    -- `export = { resource = 'my_keys', method = 'GiveKeys', pass = 'plate' }`
    -- (pass = 'plate' or 'vehicle') calls a client export.
    vehicleKeys = {},

    -- In-game CAD photography. With the screenshot-basic resource running
    -- and an upload endpoint configured here (fivemanage, a Discord webhook,
    -- any host that accepts multipart uploads and answers with a URL),
    -- officers get a "take photo with the camera" option wherever the CAD
    -- accepts pictures. Leave url = '' to keep photos link-only.
    mediaUpload = { url = '', field = 'files[]' },

    -- The charge catalog the CAD's pickers search: officers choose from this
    -- list instead of free-typing charge names. Extend or replace freely.
    charges = {
        'Assault on a Federal Officer',
        'Resisting Arrest',
        'Evading a Federal Officer',
        'Obstruction of Justice',
        'Conspiracy',
        'Racketeering (RICO)',
        'Wire Fraud',
        'Bank Fraud',
        'Tax Evasion',
        'Money Laundering',
        'Counterfeiting',
        'Identity Theft',
        'Bribery of a Public Official',
        'Extortion',
        'Witness Tampering',
        'Perjury',
        'Espionage',
        'Terroristic Threats',
        'Possession of a Controlled Substance',
        'Possession with Intent to Distribute',
        'Drug Trafficking',
        'Unlawful Possession of a Firearm',
        'Firearms Trafficking',
        'Possession of an Illegal Weapon',
        'Kidnapping',
        'Human Trafficking',
        'Grand Theft Auto',
        'Armed Robbery',
        'Burglary of a Federal Facility',
        'Destruction of Government Property',
        'Cybercrime / Unauthorized Computer Access',
        'Smuggling',
        'Poaching on Federal Land',
        'Arson',
        'Homicide',
        'Attempted Homicide'
    },

    -- On-screen duty HUD: callsign, status, rank and the current callout
    -- objectives. Set enabled = false to run without it.
    hud = {
        enabled = true,
        -- Show it off duty as well. Off by default: it is clutter on the
        -- screen of somebody who has clocked out.
        offDuty = false,
        -- How many callout objectives to show around the current one.
        objectives = 4
    },

    -- The holster. Members press the holster key (default Z, rebindable in
    -- FiveM's keybind settings) to rest a hand on their holster - allowed
    -- only when one of the listed sidearms is actually in their inventory.
    -- Equipping one of them plays a draw-from-the-holster animation, and
    -- putting it away plays the re-holster.
    holster = {
        enabled = true,
        defaultKey = 'Z',
        weapons = {
            'weapon_pistol', 'weapon_pistol_mk2', 'weapon_combatpistol',
            'weapon_heavypistol', 'weapon_snspistol', 'weapon_stungun'
        }
    },

    -- Using this inventory item opens the MDT anywhere (members with
    -- cad.view only). Stock it in the armory so agents can draw one.
    tabletItem = 'fed_tablet',

    -- Where the armory storefront finds item images: your inventory
    -- resource's NUI image folder, so the shelves show the same pictures as
    -- the inventory itself. Set to '' to fall back to icon glyphs.
    itemImages = 'nui://jpr-inventory/html/images/',

    -- Ammunition issued with every weapon drawn from the armory. `count` is
    -- how many ammo items come with the gun; `map` overrides the automatic
    -- weapon-name matching per item.
    armoryAmmo = {
        enabled = true,
        count = 2,
        map = {}
    },

    -- Night vision goggles. Members wearing an NVG helmet press the toggle
    -- key (default K, rebindable in FiveM keybinds) to flip the lenses down
    -- and turn night vision on; pressing again flips them up and off.
    --
    -- Each pair maps the helmet prop drawable with the lenses UP to the one
    -- with the lenses DOWN, per freemode body. Only a pair matching the
    -- helmet actually worn does anything, so extra candidates are harmless -
    -- if your helmet toggles the wrong way, swap its up/down numbers here.
    nightVision = {
        enabled = true,
        defaultKey = 'K',
        helmets = {
            male = {
                { up = 117, down = 116 },
                { up = 125, down = 124 },
                { up = 127, down = 126 },
                { up = 148, down = 147 },
                { up = 150, down = 149 }
            },
            female = {
                { up = 116, down = 115 },
                { up = 124, down = 123 },
                { up = 126, down = 125 },
                { up = 147, down = 146 },
                { up = 149, down = 148 }
            }
        }
    },

    -- How long each timed action takes, in ms. Nothing in this resource is
    -- instant: an action that resolves the frame you press E reads as a menu
    -- click and cannot be interrupted. Set any of these to 0 to skip the bar.
    timings = {
        search = 6000,
        frisk = 3000,
        fingerprint = 5000,
        swab = 4000,
        collectEvidence = 5000,
        cuff = 2500,
        armory = 2000,
        changeUniform = 4000,
        deploy = 2000,
        writeReport = 4000
    },

    -- Evidence lab and field custody. `analysisTime` is how long the lab
    -- bench takes, in ms. Bagging evidence in the field consumes a `bagItem`
    -- and puts a sealed `baggedItem` in the officer's inventory until it is
    -- checked into an evidence locker; a `fieldTestItem` runs a presumptive
    -- roadside test on substances.
    evidence = {
        analysisTime = 12000,
        bagItem = 'evidence_bag',
        baggedItem = 'bagged_evidence',
        fieldTestItem = 'field_test_kit'
    },

    -- Reports from the public. Callouts on a timer are the same seven cases
    -- forever; a player who calls something in is the only source of work
    -- nobody could have predicted.
    reports = {
        enabled = true,
        -- Anyone can call. Set a list of job names to restrict it.
        jobs = nil,
        -- Seconds a caller must wait between reports, so the line cannot be
        -- flooded.
        cooldown = 60,
        -- Reports older than this are dropped from the board, in seconds.
        expire = 1800,
        -- An anonymous tip withholds the caller from the board. It is still
        -- recorded server-side so abuse can be traced.
        allowAnonymous = true,
        -- A report matching one of these keywords escalates to a real callout
        -- of that template, if the template applies to an agency with units on
        -- duty. This is what turns a phone call into dispatchable work.
        escalate = {
            ['fraud'] = 'wire-fraud',
            ['counterfeit'] = 'counterfeit-passing',
            ['forged'] = 'counterfeit-passing',
            ['gun'] = 'unlicensed-transfer',
            ['firearm'] = 'unlicensed-transfer',
            ['weapons'] = 'unlicensed-transfer',
            ['threat'] = 'protectee-threat',
            ['kidnap'] = 'informant-dark',
            ['missing'] = 'informant-dark',
            ['stolen'] = 'stolen-federal-property'
        }
    },

    -- Dispatch. Most servers already run a dispatch resource, and two alert
    -- systems shouting over each other is worse than either alone.
    --
    -- 'auto' uses whichever of the supported resources is started and falls
    -- back to the built-in notification when none is. Force one with its name,
    -- or 'internal' to always use the built-in.
    dispatch = {
        provider = 'auto', -- auto, internal, ps-dispatch, cd_dispatch, linden_outlawalert
        -- Also send the built-in notification when an external provider is
        -- handling the alert. Off by default: that is the double-alert.
        alsoInternal = false
    },

    -- Deployable field equipment. Each entry may require an item, which is
    -- consumed on deploy and returned when it is picked back up.
    equipment = {
        enabled = true,
        -- How many of each thing one officer may have out at once.
        limit = 8,
        -- How far away a deployed object can be picked up from.
        pickupDistance = 2.5,
        items = {
            {
                id = 'spikes', label = 'Spike strip', model = 'p_ld_stinger_s',
                item = 'spikestrip', permission = 'actions.detain', offset = 2.0
            },
            {
                id = 'cone', label = 'Traffic cone', model = 'prop_roadcone02a',
                permission = 'actions.detain', offset = 1.2
            },
            {
                id = 'barrier', label = 'Road barrier', model = 'prop_barrier_work05',
                permission = 'actions.detain', offset = 2.0
            },
            {
                id = 'marker', label = 'Evidence marker', model = 'prop_cs_evidencemarker',
                permission = 'actions.evidence', offset = 1.0
            },
            {
                id = 'camera', label = 'Surveillance camera', model = 'prop_cctv_pole_01',
                item = 'surveillance_camera', permission = 'actions.evidence', offset = 1.5
            }
        }
    },

    -- Investigation callouts. See federal/config/callouts.lua for templates.
    callouts = {
        enabled = true,
        interval = 90000,        -- how often the engine considers dispatching
        chance = 0.55,           -- roll per eligible agency per interval
        maxActive = 3,           -- concurrent callouts per agency
        minUnits = 1,            -- on-duty officers required before dispatching
        expire = 1800000,        -- unattended callouts are dropped after this
        -- When true a real player carrying an active warrant can become the
        -- suspect of an investigation instead of a spawned NPC.
        playerSuspects = true,
        -- Paid to each officer assigned when a callout is closed.
        reward = { account = 'bank', amount = 750 },

        -- How an NPC suspect behaves when officers arrive. A suspect who
        -- stands still until someone presses E is not an investigation.
        suspect = {
            -- Chance they run rather than wait to be spoken to.
            fleeChance = 0.55,
            -- Chance they fight back once cornered.
            fightChance = 0.25,
            -- Chance they are carrying a weapon. Only ever drawn if they
            -- also decide to fight.
            armedChance = 0.2,
            weapons = { 'WEAPON_PISTOL', 'WEAPON_KNIFE', 'WEAPON_SWITCHBLADE' },
            -- They give up when this many officers are within `surrenderRange`,
            -- or when someone has a gun on them at close range.
            surrenderUnits = 2,
            surrenderRange = 12.0,
            -- Accuracy and health, kept low: this is a suspect to arrest, not
            -- a boss fight.
            accuracy = 25,
            armour = 0,
            -- How far they will run before tiring and giving up.
            fleeDistance = 220.0
        }
    },

    -- The job a dismissed officer is put back on. Must exist in your
    -- framework; most cores call it 'unemployed'.
    unemployedJob = 'unemployed',

    -- Charged when a vehicle is drawn from a motor pool.
    vehiclePrice = 0,

    -- Motor pool stock, per agency id, with a `default` fallback for agencies
    -- that have no list of their own. Models must exist on your server.
    vehicles = {
        default = {
            { model = 'fbi', label = 'Unmarked sedan' },
            { model = 'fbi2', label = 'Unmarked SUV' }
        },
        fib = {
            { model = 'fbi', label = 'Bureau sedan' },
            { model = 'fbi2', label = 'Bureau SUV' },
            { model = 'riot', label = 'Tactical transport' }
        },
        iaa = {
            { model = 'fbi2', label = 'Agency SUV' },
            { model = 'schafter2', label = 'Diplomatic sedan' }
        },
        doa = {
            { model = 'fbi2', label = 'Field SUV' },
            { model = 'sheriff2', label = 'Rural unit' }
        },
        usss = {
            { model = 'fbi2', label = 'Detail SUV' },
            { model = 'stretch', label = 'Protective limousine' }
        }
    },

    -- Court process -------------------------------------------------------
    --
    -- Courthouses and the charge catalog live in federal/config/court.lua.
    -- The job lists below are the extension point: any job named in
    -- `filingJobs` can start a case, so adding 'police' or 'sheriff' is all
    -- it takes to let your police department prosecute in the same system.
    court = {
        enabled = true,

        -- Jobs allowed to file a case. Federal agency job names are included
        -- by default; add any other job here to extend the court to it.
        filingJobs = { 'fib', 'fbi', 'iaa', 'doa', 'usss', 'secretservice', 'police', 'sheriff', 'lspd', 'bcso' },

        -- Jobs whose members may preside. When nobody holding one of these is
        -- online and free, the case is presided over by an NPC judge.
        judgeJobs = { 'judge', 'justice' },

        -- Jobs that may take the prosecution and defense benches. A case can
        -- run without either: an NPC stands in.
        prosecutorJobs = { 'da', 'prosecutor', 'attorney', 'fib', 'iaa', 'doa', 'usss', 'police', 'sheriff' },
        defenseJobs = { 'lawyer', 'attorney', 'publicdefender' },

        -- Filing a case automatically when an arrest is booked. Turn this off
        -- to file by hand from the CAD instead.
        autoFileOnArrest = true,

        jury = {
            size = 6,              -- seats to fill before deliberation
            minRealJurors = 0,     -- real players required before NPCs fill in
            npcFill = true,        -- top the jury up with NPC jurors
            unanimous = false,     -- otherwise a simple majority convicts
            -- Jobs barred from the jury box. Officers of the agency that filed
            -- are excluded automatically whatever this says.
            excludeJobs = { 'judge', 'justice' }
        },

        -- How long an NPC judge waits before moving a case on, in ms. Real
        -- judges advance cases themselves and are not on a timer.
        npcJudgeDelay = 45000,

        -- Sentencing bounds. Per-charge months and fines come from the charge
        -- catalog in federal/config/court.lua; these cap the total.
        sentencing = {
            maxMonths = 240,
            maxFine = 250000,
            fineAccount = 'bank',
            -- A judge may adjust the recommended sentence by this fraction.
            judgeDiscretion = 0.5
        },

        -- Paid to a real player filling a court role when a case closes.
        stipend = { account = 'bank', amount = 500 },

        -- Bail. A defendant who posts it walks until the trial; if they never
        -- come back, it is forfeit and a warrant follows.
        bail = {
            enabled = true,
            account = 'bank',
            -- Multiplied by the recommended fine to set the amount, then
            -- clamped. A serious charge is dearer to walk away from.
            multiplier = 0.35,
            minimum = 500,
            maximum = 100000,
            -- Seconds a released defendant has to appear before bail is
            -- forfeit and the court issues a bench warrant.
            appearBy = 1800,
            -- Charges that are never bailable, matched against the catalog.
            denyFor = { 'Espionage', 'Kidnapping', 'Threatening a protected person' }
        },

        -- Plea bargaining. The prosecution offers a reduced sentence for a
        -- guilty plea; the defendant takes it or goes to trial.
        plea = {
            enabled = true,
            -- The fraction of the recommendation an accepted offer carries.
            -- Bounded so a bargain is a discount, not an acquittal.
            minimumFactor = 0.4,
            maximumFactor = 0.9
        },

        -- Continuances. A judge can put a case back for lack of a party.
        continuance = { enabled = true, limit = 2 }
    },

    -- Jail. The court decides the sentence; this is where it is served.
    --
    -- Set enabled = false if you already run a jail resource -- the
    -- `federal:sentenced` event still fires either way, so yours can consume
    -- it without this one competing.
    jail = {
        enabled = true,

        -- Bolingbroke. Move it with the in-game editor like anything else.
        cells = { x = 1691.6, y = 2565.2, z = 45.56 },
        release = { x = 1846.0, y = 2586.0, z = 45.67 },

        -- Real seconds served per sentenced month. 20 means a 36-month
        -- sentence is 12 minutes, which is long enough to matter and short
        -- enough that nobody logs off over it.
        secondsPerMonth = 20,
        -- However long the sentence, never longer than this in one sitting.
        maximumSeconds = 3600,

        -- Time keeps running while the player is offline. Without this the
        -- obvious play is to disconnect for the whole sentence.
        serveOffline = true,

        -- Wandering out of the facility is teleported back rather than
        -- punished, because most escapes are a physics accident.
        leash = 120.0,

        -- Taken on booking and returned on release.
        confiscate = true,

        -- Work an inmate can do to shorten the sentence, in seconds removed.
        labour = { enabled = true, reward = 60, cooldown = 45 }
    }
}
