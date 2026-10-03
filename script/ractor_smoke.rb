# Ractor smoke test for dry-configurable.
#
# Defines configurable classes in the main Ractor, then checks whether common
# operations work from a non-main Ractor.
#
# Run from the repo root:
#
#   bundle exec ruby script/ractor_smoke.rb

Warning[:experimental] = false
require "dry/configurable"

# Class-level config (extend)
class ClassConfig
  extend Dry::Configurable
  setting :name, default: "app"
  setting :db do
    setting :url, default: "sqlite://memory"
  end
end
ClassConfig.config # build config in main Ractor

# Class-level config, finalized with frozen values
class FinalizedConfig
  extend Dry::Configurable
  setting :name, default: "app"
  setting :port, default: "3000", constructor: ->(v) { Integer(v) }, reader: true
end
FinalizedConfig.config.finalize!(freeze_values: true)

# Instance-level config (include)
class InstanceConfig
  include Dry::Configurable
  setting :name, default: "instance"
end
# Instance-level config with nested settings and a constructor
class RichInstanceConfig
  include Dry::Configurable
  setting :port, default: "3000", constructor: ->(v) { Integer(v) }
  setting :db do
    setting :url, default: "sqlite://memory"
  end
end

finalized_instance = InstanceConfig.new.tap { _1.config.finalize!(freeze_values: true) }

puts "Ruby #{RUBY_VERSION}, dry-configurable #{Dry::Configurable::VERSION}, dry-core #{Gem.loaded_specs["dry-core"].version}"
puts "Main Ractor sanity: #{ClassConfig.config.name}, #{FinalizedConfig.config.port.inspect}"
puts "-" * 70

# Order matters: Ractor.make_shareable deep-freezes everything reachable,
# including the class-level Settings object. So the "out of the box" checks run
# first, and the "after make_shareable" workaround checks run last.
tests = {
  # Out of the box
  "Read class config (config.name)"             => -> { Ractor.new { ClassConfig.config.name }.value },
  "Read nested class config (db.url)"           => -> { Ractor.new { ClassConfig.config.db.url }.value },
  "Read finalized class config"                 => -> { Ractor.new { FinalizedConfig.config.name }.value },
  "Read class reader method (Klass.port)"       => -> { Ractor.new { FinalizedConfig.port }.value },
  "InstanceConfig.new in Ractor"                => -> { Ractor.new { InstanceConfig.new.config.name }.value },
  "RichInstanceConfig.new in Ractor"            => -> { Ractor.new { c = RichInstanceConfig.new.config; [c.port, c.db.url] }.value },
  "Define configurable class in Ractor"         => -> {
    Ractor.new {
      Class.new { extend Dry::Configurable; setting :x, default: 1 }.config.x
    }.value
  },
  "Read Dry::Core Undefined in Ractor"          => -> { Ractor.new { Dry::Core::Constants::Undefined.equal?(Dry::Core::Constants::Undefined) }.value },

  # Workaround: make things shareable in the main Ractor first
  "Ractor.make_shareable(finalized config)"     => -> { Ractor.make_shareable(FinalizedConfig.config); "shareable" },
  "Read finalized class config after sharing"   => -> { Ractor.new { FinalizedConfig.config.name }.value },
  "Class reader after sharing (Klass.port)"     => -> { Ractor.new { FinalizedConfig.port }.value },
  "Pass finalized config into Ractor"           => -> { Ractor.new(FinalizedConfig.config) { |c| c.name }.value },
  "Ractor.make_shareable(finalized instance)"   => -> { Ractor.make_shareable(finalized_instance); "shareable" },
  "Pass finalized instance into Ractor"         => -> { Ractor.new(finalized_instance) { |o| o.config.name }.value },
  "InstanceConfig.new after sharing settings"   => -> { Ractor.new { InstanceConfig.new.config.name }.value },
  "Write to new instance config after sharing"  => -> { Ractor.new { o = InstanceConfig.new; o.config.name = "x"; o.config.name }.value },
  "Ractor.make_shareable(RichInstance.settings)" => -> { Ractor.make_shareable(RichInstanceConfig.settings); "shareable" },
  "RichInstanceConfig.new after sharing"        => -> { Ractor.new { c = RichInstanceConfig.new.config; [c.port, c.db.url] }.value },
  "Add setting after sharing (main Ractor)"     => -> { RichInstanceConfig.setting(:later, default: 1); "added" },
}

results = tests.map do |name, test|
  print "#{name.ljust(44)} "
  begin
    out = test.call
    puts "OK (#{out.inspect})"
    [name, :ok]
  rescue Ractor::RemoteError => e
    c = e.cause
    puts "FAILED: #{c.class}: #{c.message.lines.first.strip[0, 140]}"
    [name, :fail]
  rescue => e
    puts "FAILED: #{e.class}: #{e.message.lines.first.strip[0, 140]}"
    [name, :fail]
  end
end
puts "-" * 70
puts "#{results.count { _2 == :ok }}/#{results.size} passed"
