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
Config.Notify = 'auto' -- auto, ox, framework, chat
-- auto: ox_lib, then qb-menu, then the bundled NUI menu in ui/.
-- Set 'nui' to always use the bundled menu even when ox_lib is installed.
-- 'chat' is a text-only fallback for servers that cannot run NUI.
Config.Menu = 'auto' -- auto, nui, ox, qb, chat

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
    saveInterval = 5000 -- clamped to a 1000ms floor
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

    -- Evidence lab. `analysisTime` is how long the lab bench takes, in ms.
    evidence = { analysisTime = 12000 },

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
        reward = { account = 'bank', amount = 750 }
    },

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
        stipend = { account = 'bank', amount = 500 }
    }
}
