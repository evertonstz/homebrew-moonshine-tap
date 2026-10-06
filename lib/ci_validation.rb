module MoonshineCI
  extend self
  JOBS = %w[checks].freeze
  REQUIRED_CHECK = 'Moonshine required validation'.freeze

  def successful?(needs)
    needs.is_a?(Hash) && needs.keys.sort == JOBS &&
      JOBS.all? { |job| needs[job].is_a?(Hash) && needs[job]['result'] == 'success' }
  end
end
