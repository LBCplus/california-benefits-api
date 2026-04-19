#!/bin/bash
# Screen a family of 3 earning $2,400/month in LA County
curl -X POST https://empathysystem.ai/api/v1/benefits/screen \
  -H "Content-Type: application/json" \
  -d '{
    "monthly_income": 2400,
    "household_size": 3,
    "has_dependents": true,
    "dependent_ages": [5, 8],
    "county": "los_angeles"
  }' | python3 -m json.tool
