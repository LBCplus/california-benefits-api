require "minitest/autorun"
require "tempfile"
require_relative "../lib/benefits_screening"

class BenefitsScreeningTest < Minitest::Test
  CONFIG = File.join(__dir__, "..", "config", "california_programs.yml")
  REGION_1_COUNTIES = %w[
    alameda contra_costa los_angeles marin monterey napa orange san_diego san_francisco
    san_luis_obispo san_mateo santa_barbara santa_clara santa_cruz solano sonoma ventura
  ].freeze

  def test_nil_income_raises_validation_error
    assert_raises(BenefitsScreening::ValidationError) do
      screening(monthly_income: nil, household_size: 3)
    end
  end

  def test_nil_household_raises_validation_error
    assert_raises(BenefitsScreening::ValidationError) do
      screening(monthly_income: 2000, household_size: nil)
    end
  end

  def test_negative_income_raises_validation_error
    err = assert_raises(BenefitsScreening::ValidationError) do
      screening(monthly_income: -500, household_size: 1)
    end
    assert_match(/must be zero or positive/, err.message)
  end

  def test_zero_household_raises_validation_error
    err = assert_raises(BenefitsScreening::ValidationError) do
      screening(monthly_income: 1000, household_size: 0)
    end
    assert_match(/must be at least 1/, err.message)
  end

  def test_absurd_income_raises_validation_error
    err = assert_raises(BenefitsScreening::ValidationError) do
      screening(monthly_income: 999_999, household_size: 1)
    end
    assert_match(/exceeds reasonable range/, err.message)
  end

  def test_absurd_household_raises_validation_error
    assert_raises(BenefitsScreening::ValidationError) do
      screening(monthly_income: 1000, household_size: 50)
    end
  end

  def test_dependent_age_over_17_raises
    err = assert_raises(BenefitsScreening::ValidationError) do
      screening(monthly_income: 1000, household_size: 2, dependent_ages: [25])
    end
    assert_match(/must be 0-17/, err.message)
  end

  def test_class_level_validation
    errors = BenefitsScreening.validate(monthly_income: nil, household_size: nil)
    assert_equal 2, errors.size
  end

  def test_class_level_validation_passes
    errors = BenefitsScreening.validate(monthly_income: 2000, household_size: 3)
    assert_empty errors
  end

  def test_fpl_table_is_the_2026_guidelines
    fpl = YAML.load_file(CONFIG)["fpl_thresholds"]
    assert_equal 2026, fpl["year"]
    assert_equal [15960, 21640, 27320, 33000, 38680, 44360, 50040, 55720], fpl["guidelines"].values
    assert_equal 5680, fpl["per_additional_person"]
  end

  def test_fpl_percentage_single_person
    s = screening(monthly_income: 1330, household_size: 1)
    assert_equal 100, s.fpl_pct
  end

  def test_fpl_percentage_family_of_three
    s = screening(monthly_income: 2277, household_size: 3)
    assert_equal 100, s.fpl_pct
  end

  def test_fpl_zero_income
    s = screening(monthly_income: 0, household_size: 1)
    assert_equal 0, s.fpl_pct
  end

  def test_fpl_household_above_8
    s = screening(monthly_income: 5000, household_size: 10)
    assert_in_delta 89.4, s.fpl_pct, 0.1
  end

  def test_rounded_percentage_does_not_decide_eligibility
    s = screening(monthly_income: 2661, household_size: 1)
    assert_equal 200, s.fpl_pct.round
    refute_includes eligible_ids(monthly_income: 2661, household_size: 1), "calfresh"
  end

  def test_calfresh_eligible_below_200_fpl
    programs = eligible_ids(monthly_income: 2400, household_size: 3)
    assert_includes programs, "calfresh"
  end

  def test_calfresh_ineligible_above_200_fpl
    programs = eligible_ids(monthly_income: 5000, household_size: 1)
    refute_includes programs, "calfresh"
  end

  def test_calfresh_exactly_at_200_fpl_is_eligible
    assert_includes eligible_ids(monthly_income: 2660, household_size: 1), "calfresh"
  end

  def test_calfresh_one_dollar_over_200_fpl_is_ineligible
    refute_includes eligible_ids(monthly_income: 2661, household_size: 1), "calfresh"
  end

  def test_calfresh_max_benefit_at_zero_income
    assert_equal 808, snap(monthly_income: 0, household_size: 3)[:monthly]
  end

  def test_calfresh_fy2027_maximum_allotments
    expected = [306, 562, 808, 1023, 1217, 1463, 1616, 1841]
    actual = (1..8).map { |n| snap(monthly_income: 0, household_size: n)[:monthly] }
    assert_equal expected, actual
  end

  def test_calfresh_adds_225_per_person_above_8
    assert_equal 2066, snap(monthly_income: 0, household_size: 9)[:monthly]
    assert_equal 3866, snap(monthly_income: 0, household_size: 17)[:monthly]
  end

  def test_calfresh_allotment_is_capped_at_18_plus_persons
    assert_equal 3887, snap(monthly_income: 0, household_size: 18)[:monthly]
  end

  def test_calfresh_benefit_decreases_with_income
    calfresh = snap(monthly_income: 2400, household_size: 3)
    assert_operator calfresh[:monthly], :<, 808
    assert_operator calfresh[:monthly], :>, 0
  end

  def test_calfresh_standard_deduction_by_household_size
    assert_equal 281, snap(monthly_income: 300, household_size: 1)[:monthly]
    assert_equal 792, snap(monthly_income: 1000, household_size: 4)[:monthly]
    assert_equal 1408, snap(monthly_income: 1000, household_size: 7)[:monthly]
  end

  def test_calfresh_minimum_benefit_is_25_for_households_of_1_or_2
    assert_equal 25, snap(monthly_income: 2000, household_size: 1)[:monthly]
    assert_equal 25, snap(monthly_income: 3000, household_size: 2)[:monthly]
  end

  def test_calfresh_has_no_minimum_benefit_for_households_of_3_or_more
    assert_equal 0, snap(monthly_income: 4550, household_size: 3)[:monthly]
  end

  def test_calfresh_estimate_carries_its_source
    calfresh = find_program(screening(monthly_income: 0, household_size: 3), "calfresh")
    assert_match(/FY2027/, calfresh[:estimated_value][:source])
    assert_match(/fns\.usda\.gov|fns\.usda/, calfresh[:estimated_value][:source_url])
  end

  def test_medi_cal_eligible_below_138
    programs = eligible_ids(monthly_income: 2400, household_size: 3)
    assert_includes programs, "medi_cal"
  end

  def test_medi_cal_ineligible_above_138
    programs = eligible_ids(monthly_income: 4000, household_size: 3)
    refute_includes programs, "medi_cal"
  end

  def test_medi_cal_exactly_at_138_fpl_is_eligible
    programs = eligible_ids(monthly_income: 1835.40, household_size: 1)
    assert_includes programs, "medi_cal"
    refute_includes programs, "aca_subsidy"
  end

  def test_medi_cal_one_cent_over_138_fpl_hands_off_to_aca
    programs = eligible_ids(monthly_income: 1835.41, household_size: 1)
    refute_includes programs, "medi_cal"
    assert_includes programs, "aca_subsidy"
  end

  def test_aca_eligible_between_138_and_400
    programs = eligible_ids(monthly_income: 4000, household_size: 3)
    assert_includes programs, "aca_subsidy"
  end

  def test_aca_ineligible_below_138
    programs = eligible_ids(monthly_income: 2000, household_size: 3)
    refute_includes programs, "aca_subsidy"
  end

  def test_aca_exactly_at_400_fpl_is_eligible
    assert_includes eligible_ids(monthly_income: 5320, household_size: 1), "aca_subsidy"
  end

  def test_aca_one_dollar_over_400_fpl_is_ineligible
    refute_includes eligible_ids(monthly_income: 5321, household_size: 1), "aca_subsidy"
  end

  def test_aca_gives_the_published_applicable_percentage_and_no_flat_dollar_guess
    aca = find_program(screening(monthly_income: 2327.5, household_size: 1), "aca_subsidy")
    value = aca[:estimated_value]
    assert_equal 2027, value[:plan_year]
    assert_equal({ low: 4.3, high: 6.78 }, value[:share_of_income_pct])
    refute value.key?(:monthly)
    refute value.key?(:annual)
    assert_match(/Rev\. Proc\. 2026-26/, value[:source])
  end

  def test_calworks_requires_dependents
    programs = eligible_ids(monthly_income: 2000, household_size: 3, has_dependents: false, county: "los_angeles")
    refute_includes programs, "calworks"
  end

  def test_calworks_eligible_with_dependents
    programs = eligible_ids(monthly_income: 2000, household_size: 3, has_dependents: true, county: "los_angeles")
    assert_includes programs, "calworks"
  end

  def test_calworks_county_region_1
    s = screening(monthly_income: 2000, household_size: 3, has_dependents: true, county: "los_angeles")
    calworks = find_program(s, "calworks")
    assert_equal 1196, calworks[:estimated_value][:monthly]
    assert_equal 1338, calworks[:estimated_value][:exempt_monthly]
    assert_match(/Region 1/, calworks[:estimated_value][:unit])
  end

  def test_calworks_county_region_2
    s = screening(monthly_income: 2000, household_size: 3, has_dependents: true, county: "fresno")
    calworks = find_program(s, "calworks")
    assert_equal 1135, calworks[:estimated_value][:monthly]
    assert_equal 1270, calworks[:estimated_value][:exempt_monthly]
    assert_match(/Region 2/, calworks[:estimated_value][:unit])
  end

  def test_calworks_region_1_has_17_counties
    REGION_1_COUNTIES.each do |county|
      s = screening(monthly_income: 0, household_size: 3, has_dependents: true, county: county)
      assert_match(/Region 1/, find_program(s, "calworks")[:estimated_value][:unit], county)
    end
  end

  def test_calworks_other_counties_are_region_2
    %w[fresno sacramento kern riverside].each do |county|
      s = screening(monthly_income: 0, household_size: 3, has_dependents: true, county: county)
      assert_match(/Region 2/, find_program(s, "calworks")[:estimated_value][:unit], county)
    end
  end

  def test_calworks_map_for_households_of_10_or_more_uses_the_10_plus_amount
    s = screening(monthly_income: 0, household_size: 12, has_dependents: true, county: "los_angeles")
    assert_equal 2928, find_program(s, "calworks")[:estimated_value][:monthly]
  end

  def test_calworks_uses_mbsac_not_130_percent_of_fpl
    s = screening(monthly_income: 2700, household_size: 3, has_dependents: true, county: "los_angeles")
    assert_operator s.fpl_pct, :<, 130
    refute_includes s.eligible_programs.map { |p| p[:program_id] }, "calworks"
  end

  def test_calworks_just_under_mbsac_after_450_disregard_is_eligible
    assert_includes eligible_ids(monthly_income: 2409, household_size: 3, has_dependents: true, county: "los_angeles"), "calworks"
  end

  def test_calworks_at_mbsac_after_450_disregard_is_ineligible
    refute_includes eligible_ids(monthly_income: 2410, household_size: 3, has_dependents: true, county: "los_angeles"), "calworks"
  end

  def test_calworks_without_earned_income_takes_no_disregard
    args = { household_size: 3, has_dependents: true, county: "los_angeles", is_employed: false }
    assert_includes eligible_ids(monthly_income: 1959, **args), "calworks"
    refute_includes eligible_ids(monthly_income: 1960, **args), "calworks"
  end

  def test_calworks_region_2_limit
    args = { household_size: 3, has_dependents: true, county: "fresno" }
    assert_includes eligible_ids(monthly_income: 2308, **args), "calworks"
    refute_includes eligible_ids(monthly_income: 2309, **args), "calworks"
  end

  def test_calworks_without_a_county_is_not_screened
    s = screening(monthly_income: 0, household_size: 3, has_dependents: true)
    refute_includes s.eligible_programs.map { |p| p[:program_id] }, "calworks"
    assert_match(/county/, not_screened_reason(s, "calworks"))
  end

  def test_wic_requires_young_children_or_pregnant
    programs = eligible_ids(monthly_income: 2000, household_size: 3, dependent_ages: [8, 10])
    refute_includes programs, "wic"
  end

  def test_wic_eligible_with_child_under_5
    programs = eligible_ids(monthly_income: 2000, household_size: 3, dependent_ages: [3, 8])
    assert_includes programs, "wic"
  end

  def test_wic_eligible_pregnant
    programs = eligible_ids(monthly_income: 2000, household_size: 2, is_pregnant: true)
    assert_includes programs, "wic"
  end

  def test_wic_at_185_fpl_boundary
    assert_includes eligible_ids(monthly_income: 3336.16, household_size: 2, is_pregnant: true), "wic"
    refute_includes eligible_ids(monthly_income: 3336.17, household_size: 2, is_pregnant: true), "wic"
  end

  def test_wic_eligible_with_a_newborn_only
    assert_includes eligible_ids(monthly_income: 2000, household_size: 2, dependent_ages: [0]), "wic"
  end

  def test_wic_eligible_with_a_newborn_and_an_older_child
    assert_includes eligible_ids(monthly_income: 2000, household_size: 3, dependent_ages: [0, 8]), "wic"
  end

  def test_newborn_counts_as_a_young_child
    s = screening(household_size: 2, dependent_ages: [0])
    assert s.send(:meets_condition?, "requires_young_children")
  end

  def test_newborn_is_not_a_school_age_child
    s = screening(household_size: 2, dependent_ages: [0])
    refute s.send(:meets_condition?, "requires_school_age_children")
  end

  def test_newborn_counts_toward_the_eitc_child_count
    one = find_program(screening(monthly_income: 500, household_size: 2, dependent_ages: [0]), "eitc")
    assert_equal 4427, one[:estimated_value][:federal_max]
    two = find_program(screening(monthly_income: 500, household_size: 3, dependent_ages: [0, 0]), "eitc")
    assert_equal 7316, two[:estimated_value][:federal_max]
  end

  def test_newborn_uses_the_one_child_eitc_income_limit
    args = { household_size: 2, dependent_ages: [0] }
    assert_includes eligible_ids(monthly_income: 4299.41, **args), "eitc"
    refute_includes eligible_ids(monthly_income: 4299.42, **args), "eitc"
  end

  def test_nil_age_entries_are_ignored
    s = screening(household_size: 2, dependent_ages: [nil])
    refute s.send(:meets_condition?, "requires_young_children")
  end

  def test_school_meals_split_at_130_fpl
    args = { household_size: 2, dependent_ages: [8] }
    at_limit = eligible_ids(monthly_income: 2344.33, **args)
    assert_includes at_limit, "free_lunch"
    refute_includes at_limit, "reduced_lunch"
    over = eligible_ids(monthly_income: 2344.34, **args)
    refute_includes over, "free_lunch"
    assert_includes over, "reduced_lunch"
  end

  def test_reduced_lunch_ends_at_185_fpl
    args = { household_size: 1, dependent_ages: [8] }
    assert_includes eligible_ids(monthly_income: 2460.50, **args), "reduced_lunch"
    refute_includes eligible_ids(monthly_income: 2460.51, **args), "reduced_lunch"
  end

  def test_eitc_requires_employment
    programs = eligible_ids(monthly_income: 2000, household_size: 1, is_employed: false)
    refute_includes programs, "eitc"
  end

  def test_eitc_uses_published_federal_and_california_maximums
    s = screening(monthly_income: 1500, household_size: 3, has_dependents: true, dependent_ages: [5, 8])
    value = find_program(s, "eitc")[:estimated_value]
    assert_equal 7316, value[:federal_max]
    assert_equal 3339, value[:california_max]
    assert_match(/tax year 2026/, value[:unit])
    assert_match(/Rev\. Proc\. 2025-32/, value[:source])
  end

  def test_eitc_maximums_by_number_of_children
    maximums = [[], [5], [5, 8], [5, 8, 10], [1, 2, 3, 4]].map do |ages|
      value = find_program(screening(monthly_income: 500, household_size: ages.size + 1, dependent_ages: ages), "eitc")[:estimated_value]
      [value[:federal_max], value[:california_max]]
    end
    assert_equal [[664, 302], [4427, 2016], [7316, 3339], [8231, 3756], [8231, 3756]], maximums
  end

  def test_eitc_california_credit_is_not_a_multiple_of_the_federal_credit
    s = screening(monthly_income: 1500, household_size: 3, has_dependents: true, dependent_ages: [5, 8])
    value = find_program(s, "eitc")[:estimated_value]
    refute_equal (value[:federal_max] * 0.45).round, value[:california_max]
  end

  def test_eitc_california_credit_ends_at_the_32900_cap
    args = { household_size: 2, dependent_ages: [5] }
    assert_equal 2016, find_program(screening(monthly_income: 2741.66, **args), "eitc")[:estimated_value][:california_max]
    assert_equal 0, find_program(screening(monthly_income: 2742, **args), "eitc")[:estimated_value][:california_max]
  end

  def test_eitc_childless_single_limit
    assert_includes eligible_ids(monthly_income: 1628.33, household_size: 1), "eitc"
    refute_includes eligible_ids(monthly_income: 1628.34, household_size: 1), "eitc"
  end

  def test_eitc_one_child_single_parent_limit
    args = { household_size: 2, dependent_ages: [4] }
    assert_includes eligible_ids(monthly_income: 4299.41, **args), "eitc"
    refute_includes eligible_ids(monthly_income: 4299.42, **args), "eitc"
  end

  def test_eitc_two_adults_use_the_married_joint_limit
    assert_includes eligible_ids(monthly_income: 2234.99, household_size: 2), "eitc"
    refute_includes eligible_ids(monthly_income: 2235, household_size: 2), "eitc"
  end

  def test_eitc_is_not_a_300_percent_fpl_test
    s = screening(monthly_income: 3500, household_size: 1)
    assert_operator s.fpl_pct, :<, 300
    refute_includes s.eligible_programs.map { |p| p[:program_id] }, "eitc"
  end

  def test_liheap_uses_the_income_table_not_200_percent_fpl
    s = screening(monthly_income: 3000, household_size: 1)
    assert_operator s.fpl_pct, :>, 200
    assert_includes s.eligible_programs.map { |p| p[:program_id] }, "liheap"
  end

  def test_liheap_boundary_for_one_person
    assert_includes eligible_ids(monthly_income: 3331.66, household_size: 1), "liheap"
    refute_includes eligible_ids(monthly_income: 3331.67, household_size: 1), "liheap"
  end

  def test_liheap_adds_192_21_per_person_above_10
    assert_includes eligible_ids(monthly_income: 9418.46, household_size: 11), "liheap"
    refute_includes eligible_ids(monthly_income: 9418.47, household_size: 11), "liheap"
  end

  def test_housing_voucher_los_angeles_uses_50_percent_ami
    s = screening(monthly_income: 4000, household_size: 1, county: "los_angeles")
    assert_operator s.fpl_pct, :>, 80
    assert_includes s.eligible_programs.map { |p| p[:program_id] }, "housing_voucher"
  end

  def test_housing_voucher_los_angeles_boundary
    args = { household_size: 1, county: "los_angeles" }
    assert_includes eligible_ids(monthly_income: 4858.33, **args), "housing_voucher"
    refute_includes eligible_ids(monthly_income: 4858.34, **args), "housing_voucher"
  end

  def test_housing_voucher_san_francisco_area_covers_three_counties
    %w[san_francisco marin san_mateo].each do |county|
      args = { household_size: 1, county: county }
      assert_includes eligible_ids(monthly_income: 6129.16, **args), "housing_voucher", county
      refute_includes eligible_ids(monthly_income: 6129.17, **args), "housing_voucher", county
    end
  end

  def test_housing_voucher_san_diego_boundary
    args = { household_size: 4, county: "san_diego" }
    assert_includes eligible_ids(monthly_income: 7287.50, **args), "housing_voucher"
    refute_includes eligible_ids(monthly_income: 7287.51, **args), "housing_voucher"
  end

  def test_housing_voucher_other_counties_are_not_screened_with_the_hud_link
    s = screening(monthly_income: 1000, household_size: 1, county: "fresno")
    refute_includes s.eligible_programs.map { |p| p[:program_id] }, "housing_voucher"
    assert_match(%r{https://www\.huduser\.gov/portal/datasets/il\.html}, not_screened_reason(s, "housing_voucher"))
  end

  def test_housing_voucher_without_a_county_is_not_screened
    s = screening(monthly_income: 1000, household_size: 1)
    refute_nil not_screened_reason(s, "housing_voucher")
  end

  def test_housing_voucher_household_above_8_is_not_screened
    s = screening(monthly_income: 1000, household_size: 9, county: "los_angeles")
    refute_nil not_screened_reason(s, "housing_voucher")
  end

  def test_care_one_and_two_person_households_share_one_limit
    [1, 2].each do |size|
      assert_includes eligible_ids(monthly_income: 3606.66, household_size: size), "care", size
      refute_includes eligible_ids(monthly_income: 3606.67, household_size: size), "care", size
    end
  end

  def test_care_one_person_limit_is_not_200_percent_of_the_one_person_fpl
    s = screening(monthly_income: 3500, household_size: 1)
    assert_operator s.fpl_pct, :>, 200
    assert_includes s.eligible_programs.map { |p| p[:program_id] }, "care"
  end

  def test_care_boundary_for_three_people
    assert_includes eligible_ids(monthly_income: 4553.33, household_size: 3), "care"
    refute_includes eligible_ids(monthly_income: 4553.34, household_size: 3), "care"
  end

  def test_fera_starts_where_care_ends
    below = eligible_ids(monthly_income: 3606.66, household_size: 1)
    assert_includes below, "care"
    refute_includes below, "fera"
    above = eligible_ids(monthly_income: 3607, household_size: 1)
    refute_includes above, "care"
    assert_includes above, "fera"
  end

  def test_fera_ends_at_250_percent_fpl
    assert_includes eligible_ids(monthly_income: 4508.33, household_size: 1), "fera"
    refute_includes eligible_ids(monthly_income: 4508.34, household_size: 1), "fera"
  end

  def test_lifeline_uses_the_cpuc_dollar_table_not_135_percent_fpl
    s = screening(monthly_income: 2050, household_size: 1)
    assert_operator s.fpl_pct, :>, 135
    assert_includes s.eligible_programs.map { |p| p[:program_id] }, "california_lifeline"
  end

  def test_lifeline_boundary_for_one_person
    assert_includes eligible_ids(monthly_income: 2050, household_size: 1), "california_lifeline"
    refute_includes eligible_ids(monthly_income: 2050.01, household_size: 1), "california_lifeline"
  end

  def test_lifeline_adds_8700_per_person_above_4
    assert_includes eligible_ids(monthly_income: 4958.33, household_size: 5), "california_lifeline"
    refute_includes eligible_ids(monthly_income: 4958.34, household_size: 5), "california_lifeline"
  end

  def test_childcare_is_not_screened_while_its_table_is_unverified
    s = screening(monthly_income: 1000, household_size: 3, has_dependents: true, dependent_ages: [4])
    refute_includes s.eligible_programs.map { |p| p[:program_id] }, "childcare_subsidy"
    refute_includes s.ineligible_programs.map { |p| p[:program_id] }, "childcare_subsidy"
    assert_match(/San Francisco/, not_screened_reason(s, "childcare_subsidy"))
  end

  def test_childcare_85_percent_state_median_income_table_once_verified
    path = enabled_config("childcare_subsidy")
    args = { config_path: path, has_dependents: true, dependent_ages: [4] }
    assert_includes eligible_ids(monthly_income: 7119, household_size: 2, **args), "childcare_subsidy"
    refute_includes eligible_ids(monthly_income: 7120, household_size: 2, **args), "childcare_subsidy"
    assert_includes eligible_ids(monthly_income: 8054, household_size: 3, **args), "childcare_subsidy"
    refute_includes eligible_ids(monthly_income: 8055, household_size: 3, **args), "childcare_subsidy"
  end

  def test_childcare_household_above_10_is_not_screened_even_once_verified
    s = screening(monthly_income: 1000, household_size: 11, has_dependents: true, dependent_ages: [4], config_path: enabled_config("childcare_subsidy"))
    refute_nil not_screened_reason(s, "childcare_subsidy")
  end

  def test_ssi_uses_the_federal_rate_plus_california_supplement
    s = screening(monthly_income: 1233.93, household_size: 1, has_disability: true)
    assert_equal 1233.94, find_program(s, "ssi_capi")[:estimated_value][:monthly_max]
    refute_includes eligible_ids(monthly_income: 1233.94, household_size: 1, has_disability: true), "ssi_capi"
  end

  def test_ssi_couple_level
    s = screening(monthly_income: 2098.82, household_size: 2, has_disability: true)
    assert_equal 2098.83, find_program(s, "ssi_capi")[:estimated_value][:monthly_max]
    refute_includes eligible_ids(monthly_income: 2098.83, household_size: 2, has_disability: true), "ssi_capi"
  end

  def test_ssi_is_not_a_100_percent_fpl_test
    s = screening(monthly_income: 1200, household_size: 1, has_disability: true)
    assert_operator s.fpl_pct, :>, 85
    assert_includes s.eligible_programs.map { |p| p[:program_id] }, "ssi_capi"
    s = screening(monthly_income: 1300, household_size: 1, has_disability: true)
    assert_operator s.fpl_pct, :<, 100
    refute_includes s.eligible_programs.map { |p| p[:program_id] }, "ssi_capi"
  end

  def test_ssi_requires_disability
    refute_includes eligible_ids(monthly_income: 0, household_size: 1), "ssi_capi"
  end

  def test_ssi_household_of_3_is_not_screened
    s = screening(monthly_income: 0, household_size: 3, has_disability: true)
    refute_nil not_screened_reason(s, "ssi_capi")
  end

  def test_general_relief_la_county
    s = screening(monthly_income: 200, household_size: 1, county: "los_angeles")
    gr = find_program(s, "general_relief")
    assert_equal 221, gr[:estimated_value][:monthly]
    assert_match(/Los Angeles County/, gr[:estimated_value][:unit])
  end

  def test_general_relief_la_couple
    s = screening(monthly_income: 200, household_size: 2, county: "los_angeles")
    assert_equal 375, find_program(s, "general_relief")[:estimated_value][:monthly]
  end

  def test_general_relief_income_must_be_under_the_grant
    assert_includes eligible_ids(monthly_income: 220.99, household_size: 1, county: "los_angeles"), "general_relief"
    refute_includes eligible_ids(monthly_income: 221, household_size: 1, county: "los_angeles"), "general_relief"
  end

  def test_general_relief_is_not_an_fpl_test
    s = screening(monthly_income: 500, household_size: 1, county: "los_angeles")
    assert_operator s.fpl_pct, :<, 100
    refute_includes s.eligible_programs.map { |p| p[:program_id] }, "general_relief"
  end

  def test_general_relief_unverified_counties_are_not_screened
    %w[san_francisco san_diego santa_clara orange riverside san_bernardino kern].each do |county|
      s = screening(monthly_income: 0, household_size: 1, county: county)
      refute_includes s.eligible_programs.map { |p| p[:program_id] }, "general_relief", county
      refute_nil not_screened_reason(s, "general_relief"), county
    end
  end

  def test_general_relief_without_a_county_is_not_screened
    s = screening(monthly_income: 0, household_size: 1)
    refute_includes s.eligible_programs.map { |p| p[:program_id] }, "general_relief"
    refute_nil not_screened_reason(s, "general_relief")
  end

  def test_general_relief_counties_with_an_unread_income_rule_are_not_screened
    { "sacramento" => "326.64", "alameda" => "336", "fresno" => "245" }.each do |county, grant|
      s = screening(monthly_income: 0, household_size: 1, county: county)
      refute_includes s.eligible_programs.map { |p| p[:program_id] }, "general_relief", county
      assert_includes not_screened_reason(s, "general_relief"), grant, county
    end
  end

  def test_general_relief_household_of_3_in_la_is_not_screened
    s = screening(monthly_income: 0, household_size: 3, county: "los_angeles")
    refute_nil not_screened_reason(s, "general_relief")
  end

  def test_screen_response_structure
    s = screening(monthly_income: 2400, household_size: 3, has_dependents: true, dependent_ages: [5, 8])
    result = s.screen

    assert_equal "2.0.0", result[:api_version]
    assert_equal "2.0.0", result[:config_version]
    assert_equal "2026-10-21", result[:config_last_updated]
    assert result[:screened_at]
    assert_equal 2026, result[:fpl_year]
    assert result[:fpl_percentage]
    assert_equal 3, result[:household_size]
    assert_operator result[:eligible_count], :>, 0
    assert result[:eligible_programs].is_a?(Array)
    assert result[:ineligible_programs].is_a?(Array)
    assert result[:not_screened_programs].is_a?(Array)
    assert result[:disclaimer]
  end

  def test_programs_screened_excludes_not_screened_programs
    result = screening(monthly_income: 2400, household_size: 3, has_dependents: true, dependent_ages: [5, 8]).screen
    total = YAML.load_file(CONFIG)["programs"].size
    assert_equal total, result[:programs_screened] + result[:not_screened_programs].size
  end

  def test_not_screened_programs_carry_a_reason_and_a_source
    result = screening(monthly_income: 0, household_size: 1).screen
    assert_includes result[:not_screened_programs].map { |p| p[:program_id] }, "childcare_subsidy"
    result[:not_screened_programs].each do |p|
      assert p[:reason], "#{p[:program_id]} missing reason"
      assert p[:source], "#{p[:program_id]} missing source"
    end
  end

  def test_not_screened_programs_never_appear_as_eligible_or_ineligible
    result = screening(monthly_income: 0, household_size: 1).screen
    ids = result[:not_screened_programs].map { |p| p[:program_id] }
    shown = (result[:eligible_programs] + result[:ineligible_programs]).map { |p| p[:program_id] }
    assert_empty ids & shown
  end

  def test_typical_low_income_family
    result = screening(
      monthly_income: 2400, household_size: 3,
      has_dependents: true, dependent_ages: [4, 8],
      county: "los_angeles"
    ).screen
    programs = result[:eligible_programs].map { |p| p[:program_id] }
    assert_includes programs, "calfresh"
    assert_includes programs, "medi_cal"
    assert_includes programs, "calworks"
    assert_includes programs, "eitc"
    assert_includes programs, "care"
    assert_includes programs, "liheap"
    assert_includes programs, "california_lifeline"
    assert_includes programs, "housing_voucher"
    assert_includes programs, "free_lunch"
    assert_includes programs, "wic"
    assert_includes result[:not_screened_programs].map { |p| p[:program_id] }, "childcare_subsidy"
  end

  def test_single_adult_no_dependents
    programs = eligible_ids(monthly_income: 1200, household_size: 1)
    assert_includes programs, "calfresh"
    assert_includes programs, "medi_cal"
    assert_includes programs, "eitc"
    refute_includes programs, "calworks"
    refute_includes programs, "wic"
    refute_includes programs, "childcare_subsidy"
  end

  def test_moderate_income
    programs = eligible_ids(monthly_income: 6000, household_size: 3)
    refute_includes programs, "calfresh"
    refute_includes programs, "medi_cal"
    assert_includes programs, "aca_subsidy"
  end

  def test_every_program_has_source
    s = screening(monthly_income: 0, household_size: 1)
    s.eligible_programs.each do |p|
      assert p[:source], "#{p[:program_id]} missing source citation"
    end
  end

  def test_every_configured_program_has_source_and_source_url
    YAML.load_file(CONFIG)["programs"].each do |key, config|
      assert config["source"], "#{key} missing source"
      assert config["source_url"], "#{key} missing source_url"
    end
  end

  def test_every_estimate_carries_its_source
    s = screening(monthly_income: 0, household_size: 1, has_disability: true, county: "los_angeles")
    s.eligible_programs.each do |p|
      assert p[:estimated_value][:source], "#{p[:program_id]} estimate missing source"
      assert p[:estimated_value][:source_url], "#{p[:program_id]} estimate missing source_url"
    end
  end

  def test_unverified_programs_and_tables_state_a_reason
    YAML.load_file(CONFIG)["programs"].each do |key, config|
      assert config["unverified_reason"], "#{key} unverified without a reason" if config["verified"] == false
      (config.dig("income_limit", "tables") || {}).each do |name, table|
        assert table["unverified_reason"], "#{key}/#{name} unverified without a reason" if table["verified"] == false
      end
    end
  end

  def test_programs_with_a_dollar_test_have_no_fpl_limit
    YAML.load_file(CONFIG)["programs"].each do |key, config|
      next unless config["income_limit"]
      refute config.key?("max_fpl_pct"), "#{key} has both a dollar test and an FPL limit"
    end
  end

  def test_dead_urls_are_gone
    text = File.read(CONFIG)
    %w[care-fera-702 Pages/LIHEAP.aspx hhs-poverty-guidelines].each { |dead| refute_includes text, dead }
  end

  def test_consent_domains_are_valid
    s = screening(monthly_income: 0, household_size: 1)
    valid_domains = %w[financial health housing family transportation]
    s.eligible_programs.each do |p|
      assert_includes valid_domains, p[:consent_domain],
        "#{p[:program_id]} has invalid consent_domain: #{p[:consent_domain]}"
    end
  end

  def test_income_limit_includes_fpl_source
    s = screening(monthly_income: 2000, household_size: 3)
    s.eligible_programs.each do |p|
      assert p[:income_limit][:fpl_source], "#{p[:program_id]} missing FPL source in income_limit"
    end
  end

  def test_dollar_test_programs_report_the_limit_they_were_tested_against
    care = find_program(screening(monthly_income: 2000, household_size: 1), "care")
    assert_equal "annual", care[:income_limit][:income_period]
    assert_equal 43_280, care[:income_limit][:max_income]
  end

  def test_ineligible_programs_have_reasons
    s = screening(monthly_income: 8000, household_size: 1)
    s.ineligible_programs.each do |p|
      assert p[:reason], "#{p[:program_id]} missing ineligibility reason"
    end
  end

  def test_ineligible_dollar_program_names_the_limit
    s = screening(monthly_income: 4000, household_size: 1)
    care = s.ineligible_programs.find { |p| p[:program_id] == "care" }
    assert_match(/\$43280 annual limit/, care[:reason])
  end

  def test_aca_ineligible_suggests_medi_cal
    s = screening(monthly_income: 1000, household_size: 1)
    aca = s.ineligible_programs.find { |p| p[:program_id] == "aca_subsidy" }
    assert_match(/Medi-Cal/, aca[:reason]) if aca
  end

  private

  def screening(**args)
    defaults = { monthly_income: 2000, household_size: 1, config_path: CONFIG }
    BenefitsScreening.new(**defaults.merge(args))
  end

  def eligible_ids(**args)
    screening(**args).eligible_programs.map { |p| p[:program_id] }
  end

  def find_program(s, id)
    s.eligible_programs.find { |p| p[:program_id] == id }
  end

  def snap(**args)
    find_program(screening(**args), "calfresh")[:estimated_value]
  end

  def not_screened_reason(s, id)
    s.not_screened_programs.find { |p| p[:program_id] == id }&.fetch(:reason)
  end

  def enabled_config(program)
    config = YAML.load_file(CONFIG)
    config["programs"][program].delete("verified")
    file = Tempfile.new(["programs", ".yml"])
    file.write(config.to_yaml)
    file.close
    (@tempfiles ||= []) << file
    file.path
  end
end
