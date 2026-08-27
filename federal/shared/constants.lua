-- Vocabulary shared by the client editor, the server gates, and the tests.
-- Everything the resource validates against lives here so a typo in a zone
-- kind or a permission name fails loudly at the edit that introduced it
-- rather than silently denying every player later.
DAG = DAG or {}
DAG.Federal = DAG.Federal or {}

local Federal = DAG.Federal
local Const = {}
Federal.Constants = Const

-- Net event and callback names are derived from the resource name so two
-- resources built from this template never share a channel.
function Federal.Net(name)
    return DAG.Framework.Event('federal:' .. name)
end

-- Zone kinds a station may contain. `boss` gates the management menu, `cad`
-- the terminal, `evidence` the lab. Adding a kind here makes it selectable in
-- the in-game editor without touching the editor itself.
Const.ZoneKinds = {
    duty     = { label = 'Duty point',   icon = 'user',   description = 'Clock on and off, set your callsign' },
    locker   = { label = 'Locker room',  icon = 'box',    description = 'Change into a configured uniform' },
    armory   = { label = 'Armory',       icon = 'lock',   description = 'Draw issued equipment' },
    evidence = { label = 'Evidence lab', icon = 'info',   description = 'Log, analyse and release evidence' },
    boss     = { label = 'Boss office',  icon = 'wrench', description = 'Manage uniforms, armory, ranks and roster' },
    cad      = { label = 'CAD terminal', icon = 'info',   description = 'Incidents, warrants, BOLOs and records' },
    cells    = { label = 'Holding cell', icon = 'lock',   description = 'Book and release detainees' },
    garage   = { label = 'Motor pool',   icon = 'car',    description = 'Agency vehicle spawn point' }
}

Const.ZoneKindOrder = { 'duty', 'locker', 'armory', 'evidence', 'cad', 'boss', 'cells', 'garage' }

-- Every permission a rank can carry. `Core.Can` only accepts a name from this
-- table, so a rank granting 'cad.wrtie' is rejected when it is saved instead
-- of quietly never matching.
Const.Permissions = {
    ['cad.view']        = 'Read the CAD',
    ['cad.write']       = 'File and update incidents',
    ['cad.warrant']     = 'Issue and serve warrants',
    ['cad.expunge']     = 'Delete CAD records',
    ['armory.use']      = 'Draw equipment from the armory',
    ['armory.manage']   = 'Change what the armory stocks',
    ['uniform.manage']  = 'Create and edit uniforms',
    ['roster.manage']   = 'Manage ranks and the duty roster',
    ['editor.manage']   = 'Edit agencies, stations and zones in game',
    ['callout.manage']  = 'Start, reassign and cancel callouts',
    ['actions.detain']  = 'Cuff, escort and detain suspects',
    ['actions.search']  = 'Search suspects and vehicles',
    ['actions.arrest']  = 'Book arrests and issue fines',
    ['actions.evidence'] = 'Collect evidence at a scene'
}

Const.PermissionOrder = {
    'cad.view', 'cad.write', 'cad.warrant', 'cad.expunge',
    'armory.use', 'armory.manage', 'uniform.manage', 'roster.manage',
    'editor.manage', 'callout.manage',
    'actions.detain', 'actions.search', 'actions.arrest', 'actions.evidence'
}

-- Unit status shown on the CAD roster.
Const.UnitStatus = {
    available = { label = 'Available',   tone = 'success' },
    enroute   = { label = 'En route',    tone = 'accent' },
    onscene   = { label = 'On scene',    tone = 'accent' },
    busy      = { label = 'Busy',        tone = 'danger' },
    panic     = { label = 'Panic',       tone = 'danger' }
}

Const.UnitStatusOrder = { 'available', 'enroute', 'onscene', 'busy', 'panic' }

Const.IncidentStatus = { 'open', 'active', 'closed' }
Const.WarrantStatus = { 'active', 'served', 'void', 'expired' }
Const.BoloKinds = { 'person', 'vehicle' }

-- Evidence kinds. `analysable` decides whether the lab can produce a result;
-- a seized weapon is logged but nothing is learned from running it.
Const.EvidenceKinds = {
    dna       = { label = 'DNA swab',      analysable = true,  identifies = true },
    print     = { label = 'Fingerprint',   analysable = true,  identifies = true },
    casing    = { label = 'Shell casing',  analysable = true,  identifies = false },
    document  = { label = 'Document',      analysable = true,  identifies = false },
    substance = { label = 'Substance',     analysable = true,  identifies = false },
    weapon    = { label = 'Seized weapon', analysable = false, identifies = false },
    property  = { label = 'Seized property', analysable = false, identifies = false }
}

Const.EvidenceKindOrder = { 'dna', 'print', 'casing', 'document', 'substance', 'weapon', 'property' }

-- Objective kinds a callout stage may use. The server validates progress
-- reports against the stage's kind, so a client cannot skip to the arrest.
Const.ObjectiveKinds = {
    arrive   = 'Reach the scene',
    interview = 'Interview a person of interest',
    evidence = 'Collect evidence',
    search   = 'Search a suspect or vehicle',
    arrest   = 'Detain the suspect',
    report   = 'File the incident report'
}

-- Numbering series. Each agency keeps its own counter per series.
Const.Series = { incident = 'INC', warrant = 'WNT', bolo = 'BLO', evidence = 'EVD', callout = 'CAD', court = 'CR' }

-- Court ---------------------------------------------------------------------

-- Case stages, in order. A case only ever moves forward through this list.
Const.CourtStages = { 'filed', 'arraignment', 'trial', 'deliberation', 'verdict', 'closed' }

-- Roles a person (or an NPC stand-in) can hold in a case. `seats` names the
-- courthouse seat role each one sits in.
Const.CourtRoles = {
    judge      = { label = 'Judge',       seat = 'judge',      npc = true,  unique = true },
    prosecutor = { label = 'Prosecution', seat = 'prosecutor', npc = true,  unique = true },
    defense    = { label = 'Defense',     seat = 'defense',    npc = true,  unique = true },
    defendant  = { label = 'Defendant',   seat = 'defendant',  npc = false, unique = true },
    bailiff    = { label = 'Bailiff',     seat = 'gallery',    npc = false, unique = true },
    juror      = { label = 'Juror',       seat = 'jury',       npc = true,  unique = false },
    witness    = { label = 'Witness',     seat = 'witness',    npc = true,  unique = false }
}

Const.CourtRoleOrder = { 'judge', 'prosecutor', 'defense', 'defendant', 'bailiff', 'juror', 'witness' }

-- Seat roles a courthouse may place. `jury` and `gallery` may be placed more
-- than once; the rest are single positions.
Const.SeatRoles = {
    judge     = { label = 'Bench',            multiple = false },
    clerk     = { label = 'Clerk desk',       multiple = false },
    prosecutor = { label = 'Prosecution table', multiple = false },
    defense   = { label = 'Defense table',    multiple = false },
    defendant = { label = 'Dock',             multiple = false },
    witness   = { label = 'Witness stand',    multiple = false },
    jury      = { label = 'Jury seat',        multiple = true },
    gallery   = { label = 'Gallery seat',     multiple = true }
}

Const.SeatRoleOrder = { 'judge', 'clerk', 'prosecutor', 'defense', 'defendant', 'witness', 'jury', 'gallery' }

Const.Pleas = { 'guilty', 'not_guilty', 'no_contest' }
Const.Verdicts = { 'guilty', 'not_guilty', 'hung' }

-- Ped component and prop slots captured when a boss saves an outfit. Listed
-- explicitly rather than looped 0..n so the capture and the apply can never
-- disagree about which slots a uniform owns.
Const.UniformComponents = { 1, 3, 4, 5, 6, 7, 8, 9, 10, 11 }
Const.UniformProps = { 0, 1, 2, 6, 7 }
Const.UniformVariants = { 'any', 'male', 'female' }

return Const
