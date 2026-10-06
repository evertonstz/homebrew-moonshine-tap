#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../lib/test_gate'

if $PROGRAM_NAME == __FILE__
  MoonshineTestGate.install! if ARGV.delete('--no-skips')
  Dir.glob(File.join(__dir__, '../tests/test_*.rb')).sort.each { |path| require path }
end
