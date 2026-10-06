require 'minitest'

module MoonshineTestGate
  REQUIRED = ['HostTest#test_official_artifact_extraction'].freeze

  class Reporter < Minitest::StatisticsReporter
    def initialize(io = $stdout, options = {})
      super
      @executed = []
      @required = options.fetch(:required_tests, REQUIRED)
    end

    def record(result)
      super
      @executed << "#{result.klass}##{result.name}"
    end

    def passed?
      count.positive? && results.empty? && (@required - @executed).empty?
    end

    def report
      super
      io.puts 'Required test gate failed: missing, skipped or failed work.' unless passed?
    end
  end

  def self.install!
    Minitest.extensions << 'moonshine_required' unless Minitest.extensions.include?('moonshine_required')
  end
end

module Minitest
  def self.plugin_moonshine_required_init(options)
    reporter << MoonshineTestGate::Reporter.new(options[:io], options)
  end
end
