require "minitest/autorun"
require_relative "../lib/benefits_screening"

class BenefitsScreeningTest < Minitest::Test
  CONFIG = File.join(__dir__, "..", "config", "california_programs.yml")

  # ── Input Validation ──

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

  # ── FPL Calculation ──

  def test_fpl_percentage_single_person
    s = screening(monthly_income: 1304, household_size: 1)
    assert_equal 100, s.fpl_pct
  end

  def test_fpl_percentage_family_of_three
    s = screening(monthly_income: 2221, household_size: 3)
    assert_equal 100, s.fpl_pct
  end

  def test_fpl_zero_income
    s = screening(monthly_income: 0, household_size: 1)
    assert_equal 0, s.fpl_pct
  end

  def test_fpl_household_above_8
    s = screening(monthly_income: 5000, household_size: 10)
    # $60,000 / $65,150 ≈ 92%
    assert_operator s.fpl_pct, :<, 100
  end

  # ── CalFresh ──

  def test_calfresh_eligible_below_200_fpl
    programs = eligible_ids(monthly_income: 2400, household_size: 3)
    assert_includes programs, "calfresh"
  end

  def test_calfresh_ineligible_above_200_fpl
    programs = eligible_ids(monthly_income: 5000, household_size: 1)
    refute_includes programs, "calfresh"
  end

  def test_calfresh_max_benefit_at_zero_income
    s = screening(monthly_income: 0, household_size: 3)
    calfresh = find_program(s, "calfresh")
    assert_equal 766, calfresh[:estimated_value][:monthly]
  end

  def test_calfresh_benefit_decreases_with_income
    s = screening(monthly_income: 2400, household_size: 3)
    calfresh = find_program(s, "calfresh")
    assert_operator calfresh[:estimated_value][:monthly], :<, 766
    assert_operator calfresh[:estimated_value][:monthly], :>, 0
  end

  # ── Medi-Cal ──

  def test_medi_cal_eligible_below_138
    programs = eligible_ids(monthly_income: 2400, household_size: 3)
    assert_includes programs, "medi_cal"
  end

  def test_medi_cal_ineligible_above_138
    programs = eligible_ids(monthly_income: 4000, household_size: 3)
    refute_includes programs, "medi_cal"
  end

  # ── ACA Subsidy ──

  def test_aca_eligible_between_139_and_400
    programs = eligible_ids(monthly_income: 4000, household_size: 3)
    assert_includes programs, "aca_subsidy"
  end

  def test_aca_ineligible_below_139
    programs = eligible_ids(monthly_income: 2000, household_size: 3)
    refute_includes programs, "aca_subsidy"
  end

  # ── CalWORKs ──

  def test_calworks_requires_dependents
    programs = eligible_ids(monthly_income: 2000, household_size: 3, has_dependents: false)
    refute_includes programs, "calworks"
  end

  def test_calworks_eligible_with_dependents
    programs = eligible_ids(monthly_income: 2000, household_size: 3, has_dependents: true)
    assert_includes programs, "calworks"
  end

  def test_calworks_county_region_1
    s = screening(monthly_income: 2000, household_size: 3, has_dependents: true, county: "los_angeles")
    calworks = find_program(s, "calworks")
    assert_equal 925, calworks[:estimated_value][:monthly]
    assert_match(/Region 1/, calworks[:estimated_value][:unit])
  end

  def test_calworks_county_region_2
    s = screening(monthly_income: 2000, household_size: 3, has_dependents: true, county: "fresno")
    calworks = find_program(s, "calworks")
    assert_equal 868, calworks[:estimated_value][:monthly]
    assert_match(/Region 2/, calworks[:estimated_value][:unit])
  end

  # ── WIC ──

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

  # ── EITC ──

  def test_eitc_requires_employment
    programs = eligible_ids(monthly_income: 2000, household_size: 1, is_employed: false)
    refute_includes programs, "eitc"
  end

  def test_eitc_includes_california_credit
    s = screening(monthly_income: 1500, household_size: 3, has_dependents: true, dependent_ages: [5, 8])
    eitc = find_program(s, "eitc")
    assert_operator eitc[:estimated_value][:california], :>, 0
    assert_equal (eitc[:estimated_value][:federal] * 0.45).round, eitc[:estimated_value][:california]
  end

  # ── General Relief (County-Specific) ──

  def test_general_relief_la_county
    s = screening(monthly_income: 500, household_size: 1, county: "los_angeles")
    gr = find_program(s, "general_relief")
    assert_equal 336, gr[:estimated_value][:monthly]
    assert_match(/Los angeles/, gr[:estimated_value][:unit])
  end

  def test_general_relief_sf_county
    s = screening(monthly_income: 500, household_size: 1, county: "san_francisco")
    gr = find_program(s, "general_relief")
    assert_equal 588, gr[:estimated_value][:monthly]
  end

  def test_general_relief_default_county
    s = screening(monthly_income: 500, household_size: 1)
    gr = find_program(s, "general_relief")
    assert_equal 336, gr[:estimated_value][:monthly]
  end

  # ── Full Screening Response ──

  def test_screen_response_structure
    s = screening(monthly_income: 2400, household_size: 3, has_dependents: true, dependent_ages: [5, 8])
    result = s.screen

    assert_equal "1.0.0", result[:api_version]
    assert_equal "1.0.0", result[:config_version]
    assert_equal "2026-04-18", result[:config_last_updated]
    assert result[:screened_at]
    assert_equal 2026, result[:fpl_year]
    assert result[:fpl_percentage]
    assert_equal 3, result[:household_size]
    assert_operator result[:eligible_count], :>, 0
    assert result[:eligible_programs].is_a?(Array)
    assert result[:ineligible_programs].is_a?(Array)
    assert result[:disclaimer]
  end

  def test_typical_low_income_family
    programs = eligible_ids(
      monthly_income: 2400, household_size: 3,
      has_dependents: true, dependent_ages: [4, 8],
      county: "los_angeles"
    )
    assert_includes programs, "calfresh"
    assert_includes programs, "medi_cal"
    assert_includes programs, "eitc"
    assert_includes programs, "care"
    assert_includes programs, "liheap"
    assert_includes programs, "california_lifeline"
    assert_includes programs, "childcare_subsidy"
    assert_includes programs, "free_lunch"
    assert_includes programs, "wic"
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

  # ── Source Citations ──

  def test_every_program_has_source
    s = screening(monthly_income: 0, household_size: 1)
    s.eligible_programs.each do |p|
      assert p[:source], "#{p[:program_id]} missing source citation"
    end
  end

  def test_every_program_has_consent_domain
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

  # ── Ineligible Programs ──

  def test_ineligible_programs_have_reasons
    s = screening(monthly_income: 8000, household_size: 1)
    s.ineligible_programs.each do |p|
      assert p[:reason], "#{p[:program_id]} missing ineligibility reason"
    end
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
end
