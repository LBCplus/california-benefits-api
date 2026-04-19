# California Benefits Screening API

An open-source eligibility screening engine for California public benefits. The first programmatic benefits screening tool for the state of California.

[![License: CC BY 4.0](https://img.shields.io/badge/License-CC_BY_4.0-lightgrey.svg)](https://creativecommons.org/licenses/by/4.0/)

## Why This Exists

New York City has a [Benefits Screening API](https://www.nyc.gov/site/opportunity/portfolio/nyc-screening-api.page) that screens for 40+ programs. California — 39 million residents, the largest safety net in the nation, an estimated $10 billion in unclaimed federal benefits annually — has nothing.

This project provides:

- A **rules engine** that calculates eligibility for 15 California benefits programs
- A **YAML-based program definition** with regulatory source citations for every threshold
- **County-specific rules** for programs that vary by county (General Relief, CalWORKs)
- **Input validation** with structured errors — rejects negative income, nil values, absurd ranges
- **FPL staleness detection** — warns when threshold year doesn't match current year
- **No PII required** — accepts household income and size, never names or SSNs
- **Open source** under CC BY 4.0

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
```

## Programs Covered (15)

| Program | FPL Limit | Source Citation |
|---|---|---|
| CalFresh / SNAP | ≤ 200% | CDSS ACL 24-01; USDA SNAP FY2026 |
| Medi-Cal | ≤ 138% | DHCS MAGI; 42 CFR 435.603 |
| ACA Subsidy | 139-400% | 26 USC 36B |
| CalWORKs | ≤ 130% | W&I Code §11452 |
| EITC (Fed + CA) | ≤ 300% | IRS Pub 596; R&TC §17052.1 |
| WIC | ≤ 185% | 7 CFR 246.7 |
| LIHEAP | ≤ 200% | 42 USC 8624 |
| CARE | ≤ 200% | PUC §739.1 |
| Section 8 | ≤ 80% | 24 CFR 982 |
| Free Lunch | ≤ 130% | 7 CFR 245 |
| Reduced Lunch | 131-185% | 7 CFR 245 |
| Lifeline | ≤ 135% | FCC 47 CFR 54 |
| Childcare | ≤ 185% | H&S Code §8220 |
| SSI/CAPI | ≤ 100% | 42 USC 1382 |
| General Relief | ≤ 100% | W&I Code §17000 |

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

General Relief and CalWORKs amounts vary by county:

```ruby
# SF General Relief: $588/month
BenefitsScreening.new(monthly_income: 500, household_size: 1, county: "san_francisco")

# LA General Relief: $336/month
BenefitsScreening.new(monthly_income: 500, household_size: 1, county: "los_angeles")

# CalWORKs Region 1 (LA, SF, SD, etc.): $925/month for family of 3
# CalWORKs Region 2 (other counties): $868/month for family of 3
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

Edit `config/california_programs.yml`. Every program requires a `source` field citing the regulatory authority. Submit a PR with the program definition and source URL.

## Engineering Methodology

Built with [Peter Mode](https://github.com/LBCplus/EmpathySystem) engineering principles and [MMASA V3.0 AMST-7](https://github.com/LBCplus/Multi-Model-Adversarial-Security-Assessment) adversarial security review:

- **No database table** — stateless rules engine
- **Input validation** — rejects nil, negative, and absurd values (AMST-7 Q7)
- **Temporal staleness** — warns when FPL year is outdated (AMST-7 Q5)
- **County-specific rules** — not one-size-fits-all defaults
- **Source citations** — every threshold traceable to regulatory authority

## License

CC BY 4.0. Free to share and adapt with attribution.

## Author

**Luis Barrera Castañón, Ed.D.**
Founder & CEO, [EmpathySystem.ai](https://empathysystem.ai)

---

*Built with the conviction that knowing what you qualify for shouldn't require a social worker, a 45-minute phone call, or a trip to three different offices.*
