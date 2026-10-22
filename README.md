# California Benefits Screening API

An open-source eligibility screening engine for California public benefits. The first programmatic benefits screening tool for the state of California.

[![License: CC BY 4.0](https://img.shields.io/badge/License-CC_BY_4.0-lightgrey.svg)](https://creativecommons.org/licenses/by/4.0/)

## Why This Exists

New York City has a [Benefits Screening API](https://www.nyc.gov/site/opportunity/portfolio/nyc-screening-api.page) that screens for 40+ programs. California — 39 million residents, the largest safety net in the nation, an estimated $10 billion in unclaimed federal benefits annually — has nothing.

This project provides:

- A **rules engine** that screens 16 California benefits programs, each against the program's own income test (poverty level, a dollar table by household size, or an area-median-income table)
- A **YAML-based program definition** with a source and effective dates for every threshold
- **County-specific rules** for programs that vary by county (General Relief, CalWORKs, Housing Choice Voucher)
- **"Not screened" answers** when a limit has not been verified against an official source, instead of a guess
- **Input validation** with structured errors — rejects negative income, nil values, absurd ranges
- **FPL staleness detection** — warns when threshold year doesn't match current year
- **No PII required** — accepts household income and size, never names or SSNs
- **Open source** under CC BY 4.0

Results are estimates, never determinations. Only the administering agency decides.

## Quick Start

```ruby
require_relative "lib/benefits_screening"

result = BenefitsScreening.new(
  monthly_income: 2400,
  household_size: 3,
  has_dependents: true,
  dependent_ages: [5, 8],
  county: "los_angeles"
).screen

puts "FPL: #{result[:fpl_percentage]}%"
puts "Eligible for #{result[:eligible_count]} programs:"
result[:eligible_programs].each do |p|
  puts "  #{p[:name]}: #{p[:estimated_value]}"
  puts "    Source: #{p[:source]}"
end
result[:not_screened_programs].each do |p|
  puts "  Not screened, #{p[:name]}: #{p[:reason]}"
end
```

For this household the engine reports 105.4% of the federal poverty level, 9 eligible programs and 3 not screened (child care, SSI/CAPI and General Relief).

## Programs Covered (16)

| Program | Income test | Source |
|---|---|---|
| CalFresh / SNAP | Gross income ≤ 200% FPL; FY2027 allotments, standard deduction and $25 minimum | CDSS; USDA FNS FY2027 |
| Medi-Cal | ≤ 138% FPL | CMS; DHCS |
| Covered California | Above 138% FPL up to 400% FPL; IRS applicable percentage shown, no dollar guess | 26 USC 36B; Rev. Proc. 2026-26 |
| CalWORKs | Income under the MBSAC by region and household size, after a $450 earned income disregard; 17 Region 1 counties; maximum aid payment shown | County MBSAC and MAP schedules |
| EITC (Fed + CA) | Income under the IRS tax year 2026 completed phaseout amount; federal and CalEITC maximums shown | Rev. Proc. 2025-32; FTB |
| WIC | ≤ 185% FPL | USDA FNS; CDPH |
| LIHEAP | Monthly income table (60% of state median income) | CSD |
| CARE | Annual dollar table (200% FPL; 1 and 2 person households share one limit) | CPUC; PUC §739.1 |
| FERA | Above the CARE limit up to 250% FPL | CPUC |
| Section 8 | Very low income limit (50% of area median income), Los Angeles, San Francisco and San Diego areas | HUD FY2026 |
| Free School Meals | ≤ 130% FPL | USDA FNS |
| Reduced-Price School Meals | Above 130% up to 185% FPL | USDA FNS |
| California LifeLine | CPUC annual dollar table | CPUC |
| Childcare | 85% of state median income; not screened until verified against a state source | CDSS |
| SSI/CAPI | Federal benefit rate plus California supplement, households of 1 or 2 | SSA POMS SI 01415.058 |
| General Relief | Income under the county maximum grant; Los Angeles County only | LA County DPSS |

The poverty guidelines are the 2026 table (91 FR 1797, effective January 13, 2026). Percentages are compared unrounded: 200.1% does not pass a 200% limit.

## Not Screened

When a limit or table has not been read from an official source, the engine does not use an old or guessed number. It lists the program under `not_screened_programs` with a reason and the source, and leaves it out of `eligible_programs` and `ineligible_programs`:

```ruby
result[:not_screened_programs]
# => [{ program_id: "general_relief", name: "General Relief (County Cash Aid)",
#       reason: "General Relief grants and income rules are set by each county. ...", ... }]
```

Today these are not screened:

- General Relief outside Los Angeles County (San Francisco, San Diego, Santa Clara, Orange, Riverside, San Bernardino, Kern and every other county; Sacramento, Alameda and Fresno have a published grant but no verified income rule)
- Housing Choice Voucher outside the Los Angeles, San Francisco and San Diego areas (the reason links to the HUD lookup)
- CalWORKs without a county, because the limit depends on the county's region
- Child care, until its ceilings are confirmed against a CDSS or CDE page
- SSI/CAPI for households of 3 or more, and Housing Choice Voucher for households of 9 or more

A program or table marked `verified: false` in `config/california_programs.yml` is never screened and must carry an `unverified_reason`.

## What Changes and When

Update `config/california_programs.yml` when these publish:

- **Mid-January:** HHS poverty guidelines. Every FPL test (CalFresh, Medi-Cal, Covered California, WIC, school meals) changes with them.
- **January:** SSI federal benefit rate; FTB CalEITC amounts for the tax year. The IRS publishes federal EITC amounts in a Revenue Procedure before the tax year (Rev. Proc. 2025-32 for tax year 2026).
- **About April:** USDA notices for WIC and school meals that take effect July 1; HUD income limits for Housing Choice Vouchers (FY2026 limits took effect May 1, 2026).
- **June 1:** CARE, FERA and California LifeLine income limits.
- **July 1:** WIC and school meal guidelines; CalWORKs MBSAC cost-of-living adjustment; state child care income ceilings.
- **October 1:** CalFresh/SNAP allotments, deductions and income limits (FY2027 began October 1, 2026); CalWORKs maximum aid payment (up 1.8% on October 1, 2026); the LIHEAP income table for each federal fiscal year (the FFY2027 table was not yet published when this was written).
- **January 1, 2027:** Covered California plan year 2027 applicable percentages and the 2026 poverty table as its basis; Medi-Cal work requirements and six-month renewals begin (see below).

## Not Modeled

H.R. 1 (Public Law 119-21) Medi-Cal work and community engagement requirements (from January 1, 2027) and six-month renewals for expansion adults (redeterminations on or after January 1, 2027) are not modeled. A Medi-Cal result does not reflect either.

## Input Validation

The engine validates all inputs and raises `BenefitsScreening::ValidationError` with structured errors:

```ruby
# These all raise ValidationError:
BenefitsScreening.new(monthly_income: nil, household_size: 3)    # "monthly_income is required"
BenefitsScreening.new(monthly_income: -500, household_size: 1)   # "must be zero or positive"
BenefitsScreening.new(monthly_income: 999999, household_size: 1) # "exceeds reasonable range"
BenefitsScreening.new(monthly_income: 1000, household_size: 0)   # "must be at least 1"

# For API controllers — validate before constructing:
errors = BenefitsScreening.validate(params)
render json: { errors: errors }, status: 422 if errors.any?
```

## County-Specific Rules

General Relief, CalWORKs and Housing Choice Voucher limits vary by county:

```ruby
# LA General Relief: $221/month maximum grant (income must be under it)
BenefitsScreening.new(monthly_income: 200, household_size: 1, county: "los_angeles")

# SF General Relief: not screened (grant not verified)
BenefitsScreening.new(monthly_income: 200, household_size: 1, county: "san_francisco")

# CalWORKs Region 1 (17 counties, including LA, SF, SD, Monterey, Ventura): $1,196/month maximum aid payment for a family of 3
# CalWORKs Region 2 (all other counties): $1,135/month maximum aid payment for a family of 3
```

## FPL Staleness Warning

If the YAML file's FPL year doesn't match the current year, the engine adds a warning:

```ruby
s = BenefitsScreening.new(monthly_income: 2000, household_size: 1)
s.warnings
# => ["FPL thresholds are from 2026 but current year is 2027. Results may be inaccurate."]
```

## Privacy

- **No PII accepted.** Never names, SSNs, dates of birth, or addresses.
- **No data stored.** Stateless — inputs processed and discarded.
- **No tracking.** No cookies, analytics, or user identification.

## Adding a Program

Edit `config/california_programs.yml`. Every program requires a `source` field citing the regulatory authority and a `source_url`. Use `income_limit` for a dollar table and `max_fpl_pct` for a poverty-level test. If a number has not been read from an official source, mark the program or table `verified: false` with an `unverified_reason`. Submit a PR with the program definition and source URL.

## Engineering Methodology

Built with [Peter Mode](https://github.com/LBCplus/EmpathySystem) engineering principles and [MMASA V3.0 AMST-7](https://github.com/LBCplus/Multi-Model-Adversarial-Security-Assessment) adversarial security review:

- **No database table** — stateless rules engine
- **Input validation** — rejects nil, negative, and absurd values (AMST-7 Q7)
- **Temporal staleness** — warns when FPL year is outdated (AMST-7 Q5)
- **County-specific rules** — not one-size-fits-all defaults
- **Source citations** — every threshold traceable to its source and effective dates
- **No guessed numbers** — unverified values are "not screened", not estimated

## License

CC BY 4.0. Free to share and adapt with attribution.

## Author

**Luis Barrera Castañón, Ed.D.**
Founder & CEO, [EmpathySystem.ai](https://empathysystem.ai)

---

*Built with the conviction that knowing what you qualify for shouldn't require a social worker, a 45-minute phone call, or a trip to three different offices.*
