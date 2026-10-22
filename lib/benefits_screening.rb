require "yaml"
require "json"
require "time"

class BenefitsScreening
  VERSION = "2.0.0"
  DISCLAIMER = "This screening provides estimates only, not determinations. Actual eligibility " \
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
    @dependent_ages = Array(dependent_ages).compact.map(&:to_i)
    @housing_status = housing_status
    @immigration_status = immigration_status
    @warnings = []

    config_path ||= File.join(__dir__, "..", "config", "california_programs.yml")
    @config = YAML.load_file(config_path)
    @meta = @config["meta"] || {}
    @fpl_config = @config["fpl_thresholds"]
    @fpl_guidelines = @fpl_config["guidelines"]
    @fpl_increment = @fpl_config["per_additional_person"]
    @fpl_year = @fpl_config["year"]
    @programs = @config["programs"]

    check_fpl_staleness!

    @fpl = calculate_fpl
    @fpl_exact = @annual_income.zero? ? 0 : (@annual_income / @fpl.to_f * 100).round(6)
    @fpl_pct = @fpl_exact.round(1)
  end

  def eligible_programs
    evaluations.filter_map do |key, config, ev|
      build_program_result(key, config, ev, eligible: true) if ev[:status] == :eligible
    end
  end

  def ineligible_programs
    evaluations.filter_map do |key, config, ev|
      next unless ev[:status] == :ineligible && ev[:show]
      build_program_result(key, config, ev, eligible: false).merge(reason: ev[:reason])
    end
  end

  def not_screened_programs
    evaluations.filter_map do |key, config, ev|
      build_not_screened(key, config, ev) if ev[:status] == :not_screened
    end
  end

  def screen
    eligible = eligible_programs
    ineligible = ineligible_programs
    not_screened = not_screened_programs

    result = {
      api_version: VERSION,
      config_version: @meta["version"],
      config_last_updated: @meta["last_updated"],
      screened_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
      fpl_year: @fpl_year,
      fpl_percentage: @fpl_pct,
      household_size: @household_size,
      county: @county,
      programs_screened: @programs.size - not_screened.size,
      eligible_count: eligible.size,
      eligible_programs: eligible,
      ineligible_programs: ineligible,
      not_screened_programs: not_screened,
      disclaimer: DISCLAIMER
    }
    result[:warnings] = @warnings if @warnings.any?
    result
  end

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
      @fpl_guidelines[size] || @fpl_guidelines.fetch(size.to_s)
    else
      base = @fpl_guidelines[8] || @fpl_guidelines.fetch("8")
      base + ((size - 8) * @fpl_increment)
    end
  end

  def evaluations
    @evaluations ||= @programs.map { |key, config| [key, config, evaluate(key, config)] }
  end

  def evaluate(key, config)
    return not_screened(config["unverified_reason"]) if config["verified"] == false

    check = config["income_limit"] ? dollar_check(config["income_limit"]) : fpl_check(key, config)
    return check unless check[:status] == :eligible

    failed = (config["conditions"] || []).reject { |c| meets_condition?(c) }
    return check if failed.empty?

    check.merge(status: :ineligible, show: true,
                reason: "Requires: #{failed.map { |c| humanize_condition(c) }.join(', ')}")
  end

  def not_screened(reason)
    { status: :not_screened, reason: reason || "No verified income limit is loaded for this household." }
  end

  def fpl_check(key, config)
    max = config["max_fpl_pct"]
    above = config["above_fpl_pct"]
    limit = { max_fpl_pct: max, above_fpl_pct: above }.compact

    if max && @fpl_exact > max
      overage = (@fpl_exact - max).round(1)
      return { status: :ineligible, limit: limit, show: @fpl_exact <= max * 1.25,
               reason: "Income exceeds #{max}% FPL limit by #{overage} percentage points (yours: #{@fpl_pct}%)" }
    end

    if above && @fpl_exact <= above
      alt = suggest_alternative(key)
      msg = "Income is not above the #{above}% FPL minimum (yours: #{@fpl_pct}%)"
      msg += ". You may qualify for #{alt}" if alt
      return { status: :ineligible, limit: limit, show: true, reason: msg }
    end

    { status: :eligible, limit: limit }
  end

  def dollar_check(limit)
    table = limit_table(limit)
    return not_screened(limit["fallback_reason"]) unless table
    return not_screened(table["unverified_reason"]) if table["verified"] == false

    size = limit["by"] == "children" ? @dependent_ages.size : @household_size
    amount = size_amount(table["by_household"], table["per_additional_person"], size)
    return not_screened(limit["fallback_reason"]) unless amount

    amount = amount.round(2)
    period = limit["period"]
    earned_disregard = @is_employed ? limit["earned_income_disregard"].to_i : 0
    income = ((period == "monthly" ? @monthly_income : @annual_income) - earned_disregard).round(2)
    shown = { income_period: period, max_income: amount, counted_income: income }

    above = table["above"] && size_amount(table["above"]["by_household"], table["above"]["per_additional_person"], size)
    if above && income <= above
      return { status: :ineligible, limit: shown.merge(above_income: above), show: false,
               reason: "Income $#{money(income)} is not above the $#{money(above)} #{period} minimum" }
    end

    over = limit["exclusive"] ? income >= amount : income > amount
    return { status: :eligible, limit: shown, amount: amount } unless over

    { status: :ineligible, limit: shown, show: income <= amount * 1.25,
      reason: "Income $#{money(income)} #{limit['exclusive'] ? 'is not under' : 'exceeds'} the $#{money(amount)} #{period} limit" }
  end

  def limit_table(limit)
    return limit unless limit["tables"]
    name = table_name(limit)
    name && limit["tables"][name]
  end

  def table_name(limit)
    return (@household_size - @dependent_ages.size >= 2 ? "married_joint" : "single") if limit["by"] == "children"
    return unless @county
    limit.dig("county_tables", @county) || (@county if limit["tables"].key?(@county)) || limit["default_table"]
  end

  def size_amount(by, per, size)
    max = by.keys.max
    return by[size] if size <= max
    per && by[max] + (size - max) * per
  end

  def money(amount)
    format("%.2f", amount).sub(/\.00\z/, "")
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

  def suggest_alternative(key)
    case key
    when "aca_subsidy" then "Medi-Cal (free coverage at or below 138% FPL)"
    when "reduced_lunch" then "Free School Meals (at or below 130% FPL)"
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

  def build_program_result(key, config, ev, eligible:)
    result = {
      program_id: key,
      name: config["name"],
      description: config["description"],
      category: config["category"],
      consent_domain: config["consent_domain"],
      eligible: eligible,
      income_limit: { your_fpl_pct: @fpl_pct, fpl_source: @fpl_config["source"] }.merge(ev[:limit]),
      how_to_apply: config["application"],
      documents_needed: config["documents_needed"],
      processing_time: config["processing_time"],
      source: config["source"],
      source_url: config["source_url"]
    }
    result[:estimated_value] = calculate_value(key, config, ev) if eligible
    result[:notes] = config["notes"] if config["notes"]
    result.compact
  end

  def build_not_screened(key, config, ev)
    {
      program_id: key,
      name: config["name"],
      category: config["category"],
      consent_domain: config["consent_domain"],
      reason: ev[:reason],
      how_to_apply: config["application"],
      source: config["source"],
      source_url: config["source_url"]
    }.compact
  end

  def calculate_value(key, config, ev)
    value = case key
    when "calfresh" then calculate_snap(config)
    when "aca_subsidy" then calculate_aca(config)
    when "calworks" then calculate_calworks(config)
    when "eitc" then calculate_eitc(config)
    when "ssi_capi" then { monthly_max: ev[:amount], unit: "$/month maximum SSI plus State Supplementary Payment" }
    when "general_relief" then { monthly: ev[:amount], unit: "$/month maximum grant (#{title(@county)} County)" }
    else (config["estimated_value"] || { description: "Varies — contact program" }).transform_keys(&:to_sym)
    end
    value.merge(source: config["estimate_source"] || config["source"],
                source_url: config["estimate_source_url"] || config["source_url"])
  end

  def title(name)
    name.split("_").map(&:capitalize).join(" ")
  end

  def calculate_snap(config)
    max = size_amount(config["snap_max_by_household"], config["snap_per_additional_person"], @household_size)
    max = [max, config["snap_max_allotment_18_plus"]].min
    net_income = [@monthly_income - size_amount(config["standard_deduction_by_household"], 0, @household_size), 0].max
    minimum = @household_size <= config["minimum_benefit_max_household_size"] ? config["minimum_benefit"] : 0
    monthly = [(max - net_income * 0.3).round, minimum].max
    { monthly: monthly, annual: monthly * 12, unit: "$/month on EBT card" }
  end

  def calculate_aca(config)
    plan_year = @fpl_year + 1
    band = config.dig("applicable_percentages", plan_year)&.select { |b| @fpl_exact >= b["from_fpl_pct"] }&.last
    value = { plan_year: plan_year, description: "Credit = benchmark plan premium minus the share of income shown" }
    band ? value.merge(share_of_income_pct: { low: band["initial"], high: band["final"] }) : value
  end

  def calculate_calworks(config)
    region = table_name(config["income_limit"])
    payments = config["max_aid_payment"][region]
    {
      monthly: size_amount(payments["non_exempt"], 0, @household_size),
      exempt_monthly: size_amount(payments["exempt"], 0, @household_size),
      unit: "$/month maximum aid payment, non-exempt (#{region.tr('_', ' ').capitalize})"
    }
  end

  def calculate_eitc(config)
    children = [@dependent_ages.size, 3].min
    california = config["california"]
    {
      federal_max: config["federal_max_credit"][children],
      california_max: @annual_income < california["max_earned_income"] ? california["max_credit"][children] : 0,
      unit: "up to $/year; federal is tax year #{config['federal_tax_year']}, California is tax year #{california['tax_year']}"
    }
  end
end
