require "yaml"
require "json"
require "time"

class BenefitsScreening
  VERSION = "1.0.0"
  DISCLAIMER = "This screening provides estimates only. Actual eligibility " \
    "is determined by the administering agency. This tool does not collect " \
    "or store personally identifiable information."

  class ValidationError < StandardError
    attr_reader :errors
    def initialize(errors)
      @errors = errors
      super(errors.join("; "))
    end
  end

  attr_reader :fpl_pct, :annual_income, :monthly_income, :household_size,
              :county, :warnings

  def initialize(monthly_income:, household_size:, county: nil,
                 has_dependents: false, is_pregnant: false,
                 has_disability: false, is_employed: true,
                 dependent_ages: [], housing_status: nil,
                 immigration_status: "documented",
                 config_path: nil)
    # ── Input validation ──
    errors = validate_inputs(monthly_income, household_size, dependent_ages)
    raise ValidationError.new(errors) if errors.any?

    @monthly_income = monthly_income.to_f
    @annual_income = @monthly_income * 12
    @household_size = household_size.to_i
    @county = county&.to_s&.downcase&.strip
    @has_dependents = has_dependents || (Array(dependent_ages).any? && Array(dependent_ages).any? { |a| a.to_i < 18 })
    @is_pregnant = is_pregnant
    @has_disability = has_disability
    @is_employed = is_employed
    @dependent_ages = Array(dependent_ages).map(&:to_i).reject(&:zero?)
    @housing_status = housing_status
    @immigration_status = immigration_status
    @warnings = []

    # ── Load config ──
    config_path ||= File.join(__dir__, "..", "config", "california_programs.yml")
    @config = YAML.load_file(config_path)
    @meta = @config["meta"] || {}
    @fpl_config = @config["fpl_thresholds"]
    @fpl_guidelines = @fpl_config["guidelines"]
    @fpl_increment = @fpl_config["per_additional_person"]
    @fpl_year = @fpl_config["year"]
    @county_adjustments = @config["county_adjustments"] || {}
    @programs = @config["programs"]

    # ── FPL staleness check (AMST-7 Q5) ──
    check_fpl_staleness!

    # ── Calculate FPL ──
    @fpl = calculate_fpl
    @fpl_pct = @annual_income.zero? ? 0 : (@annual_income / @fpl.to_f * 100).round(0)
  end

  def eligible_programs
    @programs.filter_map do |key, config|
      next unless eligible_for?(key, config)
      build_program_result(key, config, eligible: true)
    end
  end

  def ineligible_programs
    @programs.filter_map do |key, config|
      next if eligible_for?(key, config)
      next unless worth_showing?(key, config)
      reason = ineligibility_reason(key, config)
      build_program_result(key, config, eligible: false).merge(reason: reason)
    end
  end

  def screen
    eligible = eligible_programs
    ineligible = ineligible_programs

    result = {
      api_version: VERSION,
      config_version: @meta["version"],
      config_last_updated: @meta["last_updated"],
      screened_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
      fpl_year: @fpl_year,
      fpl_percentage: @fpl_pct,
      household_size: @household_size,
      county: @county,
      programs_screened: @programs.size,
      eligible_count: eligible.size,
      eligible_programs: eligible,
      ineligible_programs: ineligible,
      disclaimer: DISCLAIMER
    }
    result[:warnings] = @warnings if @warnings.any?
    result
  end

  # Class-level validation for API controllers
  def self.validate(params)
    errors = []
    errors << "monthly_income is required" if params[:monthly_income].nil?
    errors << "household_size is required" if params[:household_size].nil?
    if params[:monthly_income]
      income = params[:monthly_income].to_f
      errors << "monthly_income must be zero or positive" if income.negative?
      errors << "monthly_income exceeds reasonable range (max $100,000/month)" if income > 100_000
    end
    if params[:household_size]
      size = params[:household_size].to_i
      errors << "household_size must be at least 1" if size < 1
      errors << "household_size exceeds reasonable range (max 20)" if size > 20
    end
    if params[:dependent_ages].is_a?(Array)
      params[:dependent_ages].each_with_index do |age, i|
        errors << "dependent_ages[#{i}] must be 0-17" if age.to_i.negative? || age.to_i > 17
      end
    end
    errors
  end

  private

  def validate_inputs(monthly_income, household_size, dependent_ages)
    errors = []
    errors << "monthly_income is required (got nil)" if monthly_income.nil?
    errors << "household_size is required (got nil)" if household_size.nil?

    if monthly_income
      income = monthly_income.to_f
      errors << "monthly_income must be zero or positive (got #{income})" if income.negative?
      errors << "monthly_income exceeds reasonable range: #{income} (max $100,000/month)" if income > 100_000
    end

    if household_size
      size = household_size.to_i
      errors << "household_size must be at least 1 (got #{size})" if size < 1
      errors << "household_size exceeds reasonable range: #{size} (max 20)" if size > 20
    end

    if dependent_ages.is_a?(Array)
      dependent_ages.each_with_index do |age, i|
        a = age.to_i
        errors << "dependent_ages[#{i}] must be 0-17 (got #{a})" if a.negative? || a > 17
      end
    end

    errors
  end

  def check_fpl_staleness!
    current_year = Time.now.year
    if @fpl_year && @fpl_year < current_year
      @warnings << "FPL thresholds are from #{@fpl_year} but current year is #{current_year}. " \
        "Results may be inaccurate. Update california_programs.yml with #{current_year} guidelines."
    end
  end

  def calculate_fpl
    size = [@household_size, 1].max
    if size <= 8
      @fpl_guidelines[size] || @fpl_guidelines[size.to_s] || 15_650
    else
      base = @fpl_guidelines[8] || @fpl_guidelines["8"] || 54_150
      base + ((size - 8) * @fpl_increment)
    end
  end

  def eligible_for?(key, config)
    max = config["max_fpl_pct"]
    return false if max && @fpl_pct > max

    min = config["min_fpl_pct"]
    return false if min && @fpl_pct < min

    conditions = config["conditions"] || []
    conditions.all? { |c| meets_condition?(c) }
  end

  def meets_condition?(condition)
    case condition
    when "requires_dependents"
      @has_dependents || @dependent_ages.any?
    when "requires_pregnant"
      @is_pregnant
    when "requires_disability"
      @has_disability
    when "requires_employment"
      @is_employed
    when "requires_wic_eligible"
      @is_pregnant || @dependent_ages.any? { |a| a < 5 }
    when "requires_school_age_children"
      @dependent_ages.any? { |a| a >= 5 && a <= 18 }
    when "requires_young_children"
      @dependent_ages.any? { |a| a < 13 }
    when "requires_ssi_eligible"
      @has_disability
    else
      true
    end
  end

  # Show ineligible programs that are close to threshold or failed on conditions only
  def worth_showing?(key, config)
    max = config["max_fpl_pct"]
    return true if max && @fpl_pct <= (max * 1.25) # Within 25% of threshold

    conditions = config["conditions"] || []
    fpl_ok = max.nil? || @fpl_pct <= max
    fpl_ok && conditions.any? { |c| !meets_condition?(c) }
  end

  def ineligibility_reason(key, config)
    max = config["max_fpl_pct"]
    if max && @fpl_pct > max
      overage = @fpl_pct - max
      return "Income exceeds #{max}% FPL limit by #{overage} percentage points (yours: #{@fpl_pct}%)"
    end

    min = config["min_fpl_pct"]
    if min && @fpl_pct < min
      alt = suggest_alternative(key)
      msg = "Income below #{min}% FPL floor (yours: #{@fpl_pct}%)"
      msg += ". You may qualify for #{alt}" if alt
      return msg
    end

    conditions = config["conditions"] || []
    failed = conditions.reject { |c| meets_condition?(c) }
    "Requires: #{failed.map { |c| humanize_condition(c) }.join(', ')}" if failed.any?
  end

  def suggest_alternative(key)
    case key
    when "aca_subsidy" then "Medi-Cal (free coverage below 138% FPL)"
    when "reduced_lunch" then "Free School Meals (below 130% FPL)"
    end
  end

  def humanize_condition(condition)
    case condition
    when "requires_dependents" then "children under 18 in household"
    when "requires_pregnant" then "pregnant"
    when "requires_disability" then "qualifying disability"
    when "requires_employment" then "earned income from employment"
    when "requires_wic_eligible" then "pregnant, postpartum, or children under 5"
    when "requires_school_age_children" then "school-age children (5-18)"
    when "requires_young_children" then "children under 13"
    when "requires_ssi_eligible" then "age 65+ or qualifying disability"
    else condition.tr("_", " ")
    end
  end

  def build_program_result(key, config, eligible:)
    result = {
      program_id: key,
      name: config["name"],
      description: config["description"],
      category: config["category"],
      consent_domain: config["consent_domain"],
      eligible: eligible,
      estimated_value: calculate_value(key, config),
      income_limit: build_income_limit(config),
      how_to_apply: config["application"],
      documents_needed: config["documents_needed"],
      processing_time: config["processing_time"],
      source: config["source"],
      source_url: config["source_url"]
    }
    result[:notes] = config["notes"] if config["notes"]
    result.compact
  end

  def build_income_limit(config)
    limit = {}
    limit[:max_fpl_pct] = config["max_fpl_pct"] if config["max_fpl_pct"]
    limit[:min_fpl_pct] = config["min_fpl_pct"] if config["min_fpl_pct"]
    limit[:your_fpl_pct] = @fpl_pct
    limit[:fpl_source] = @fpl_config["source"]
    limit
  end

  # ── Value Calculations ──

  def calculate_value(key, config)
    case key
    when "calfresh"      then calculate_snap(config)
    when "medi_cal"      then { description: "Full coverage — no premium", annual_estimate: 7200 }
    when "aca_subsidy"   then calculate_aca
    when "calworks"      then calculate_calworks
    when "eitc"          then calculate_eitc
    when "wic"           then { description: "Monthly food package", monthly_estimate: 90 }
    when "liheap"        then { description: "$200-$1,000 one-time payment" }
    when "care"          then { description: "20% discount on gas and electric", monthly_estimate: 40 }
    when "housing_voucher" then { description: "Pays difference between 30% of income and Fair Market Rent" }
    when "free_lunch"    then { description: "Free breakfast and lunch", annual_estimate: 2500 }
    when "reduced_lunch" then { description: "Meals at $0.30 or less", annual_estimate: 1800 }
    when "california_lifeline" then { description: "Discounted phone/internet", monthly_estimate: 30 }
    when "childcare_subsidy" then { description: "$500-$1,500/month (varies by county and age)" }
    when "ssi_capi"      then { description: "Up to $1,183/month individual", monthly_max: 1183 }
    when "general_relief" then calculate_general_relief
    else
      { description: "Varies — contact program" }
    end
  end

  def calculate_snap(config)
    max_benefits = config["snap_max_by_household"] || {}
    max = max_benefits[[@household_size, max_benefits.keys.map(&:to_i).max || 8].min] || 291
    net_income = [@monthly_income - 200, 0].max
    benefit = max - (net_income * 0.3)
    monthly = [benefit.round, 0].max
    { monthly: monthly, annual: monthly * 12, unit: "$/month on EBT card" }
  end

  def calculate_aca
    monthly = case @fpl_pct
    when 139..200 then 400
    when 201..250 then 300
    when 251..300 then 200
    when 301..400 then 100
    else 0
    end
    { monthly: monthly, annual: monthly * 12, unit: "$/month premium reduction" }
  end

  def calculate_calworks
    region_1_counties = @county_adjustments["calworks_region_1_counties"] || []
    table = if @county && region_1_counties.include?(@county)
      @county_adjustments["calworks_region_1"] || {}
    else
      @county_adjustments["calworks_region_2"] || {}
    end

    amount = table[[@household_size, table.keys.map(&:to_i).max || 8].min]
    if amount
      region = region_1_counties.include?(@county) ? "Region 1" : "Region 2"
      { monthly: amount, unit: "$/month (#{region})" }
    else
      { description: "Varies by county and household size" }
    end
  end

  def calculate_eitc
    federal = calculate_federal_eitc
    state = (federal * 0.45).round
    { annual: federal + state, federal: federal, california: state, unit: "$/year tax refund" }
  end

  def calculate_federal_eitc
    children = @dependent_ages.size
    case children
    when 0
      @annual_income < 10_000 ? 600 : 300
    when 1
      case @annual_income
      when 0..20_000 then 3_995
      when 20_001..35_000 then 2_500
      when 35_001..46_000 then 1_000
      else 0
      end
    when 2
      case @annual_income
      when 0..20_000 then 6_604
      when 20_001..40_000 then 4_500
      when 40_001..52_000 then 1_500
      else 0
      end
    else # 3+
      case @annual_income
      when 0..20_000 then 7_430
      when 20_001..40_000 then 5_000
      when 40_001..55_000 then 2_000
      else 0
      end
    end
  end

  def calculate_general_relief
    gr_amounts = @county_adjustments["general_relief"] || {}
    amount = if @county && gr_amounts[@county]
      gr_amounts[@county]
    else
      gr_amounts["default"] || 336
    end
    { monthly: amount, unit: "$/month (#{(@county || 'default').gsub('_', ' ').capitalize} County)" }
  end
end
