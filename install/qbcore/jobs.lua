-- DAG Federal Agencies — QBCore jobs.
--
-- Paste the four blocks below inside `QBCore.Shared.Jobs = { ... }` in
-- qb-core/shared/jobs.lua. Grade labels match the default rank ladders in
-- federal/config/agencies.lua; if you rename ranks in the in-game editor the
-- agency rank is what players see, so these only need to stay 0-5.
--
-- bossGrade is 4 in the agency config, so grades 4 and 5 are marked isboss
-- for qb-management/bossmenu compatibility.

fib = {
	label = 'Federal Investigation Bureau',
	type = 'leo',
	defaultDuty = false,
	offDutyPay = true,
	grades = {
		['0'] = { name = 'Probationary Agent', payment = 500 },
		['1'] = { name = 'Special Agent', payment = 750 },
		['2'] = { name = 'Senior Special Agent', payment = 900 },
		['3'] = { name = 'Supervisory Agent', payment = 1100 },
		['4'] = { name = 'Assistant Director', isboss = true, payment = 1400 },
		['5'] = { name = 'Director', isboss = true, payment = 1800 },
	},
},

iaa = {
	label = 'International Affairs Agency',
	type = 'leo',
	defaultDuty = false,
	offDutyPay = true,
	grades = {
		['0'] = { name = 'Operations Officer', payment = 500 },
		['1'] = { name = 'Field Officer', payment = 750 },
		['2'] = { name = 'Case Officer', payment = 900 },
		['3'] = { name = 'Station Chief', payment = 1100 },
		['4'] = { name = 'Deputy Director', isboss = true, payment = 1400 },
		['5'] = { name = 'Director', isboss = true, payment = 1800 },
	},
},

doa = {
	label = 'Department of Alcohol & Firearms',
	type = 'leo',
	defaultDuty = false,
	offDutyPay = true,
	grades = {
		['0'] = { name = 'Inspector', payment = 500 },
		['1'] = { name = 'Field Inspector', payment = 750 },
		['2'] = { name = 'Senior Inspector', payment = 900 },
		['3'] = { name = 'Group Supervisor', payment = 1100 },
		['4'] = { name = 'Assistant Director', isboss = true, payment = 1400 },
		['5'] = { name = 'Director', isboss = true, payment = 1800 },
	},
},

usss = {
	label = 'United States Secret Service',
	type = 'leo',
	defaultDuty = false,
	offDutyPay = true,
	grades = {
		['0'] = { name = 'Special Officer', payment = 500 },
		['1'] = { name = 'Special Agent', payment = 750 },
		['2'] = { name = 'Senior Agent', payment = 900 },
		['3'] = { name = 'Detail Leader', payment = 1100 },
		['4'] = { name = 'Deputy Director', isboss = true, payment = 1400 },
		['5'] = { name = 'Director', isboss = true, payment = 1800 },
	},
},
