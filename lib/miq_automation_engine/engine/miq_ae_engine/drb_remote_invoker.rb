require 'drb'
module MiqAeEngine
  class DrbRemoteInvoker
    attr_accessor :api_token, :num_methods, :service_front

    def initialize(workspace)
      @workspace = workspace
      @num_methods = 0
    end

    def with_server(inputs, bodies, method_name, script_info)
puts "DrbRemoteInvoker.with_server("
puts "  inputs=#{inputs.inspect},"
puts "  bodies=#{bodies.inspect},"
puts "  method_name=#{method_name.inspect},"
puts "  script_info=#{script_info.inspect})"
      setup if num_methods.zero?
      self.num_methods += 1
      svc = MiqAeMethodService::MiqAeService.new(@workspace, inputs)
      yield build_method_content(bodies, method_name, svc.object_id, script_info)
    ensure
      svc.destroy if svc# Reset inputs to empty to avoid storing object references
      self.num_methods -= 1
      teardown if num_methods.zero?
    end

    # This method is called by the client thread that runs for each request
    # coming into the server.
    # See https://github.com/ruby/ruby/blob/trunk/lib/drb/drb.rb#L1658
    # Previously we had used DRb.front but that gets compromised when multiple
    # DRb servers are running in the same process.
    # def self.workspace
    #   if Thread.current['DRb'] && Thread.current['DRb']['server']
    #     Thread.current['DRb']['server'].front.workspace
    #   end
    # end

    private

    # invocation

    def setup
      user = User.first

      self.service_front = MiqAeMethodService::MiqAeServiceFront.new(@workspace)
      self.api_token     = Api::UserTokenService.new.generate_token(user.userid, 'api')
    end

    def teardown
    end

    # code building

    def build_method_content(bodies, method_name, miq_ae_service_token, script_info)
      [
        dynamic_preamble(method_name, miq_ae_service_token, script_info),
        RUBY_METHOD_PREAMBLE,
        bodies,
        RUBY_METHOD_POSTSCRIPT
      ].flatten.join("\n")
    end

    def dynamic_preamble(method_name, miq_ae_service_token, script_info)
      script_info_yaml = script_info.to_yaml
      <<-RUBY.chomp
MIQ_URI = '#{'localhost:3000/api'}' # FIXME
MIQ_ID = #{miq_ae_service_token}
MIQ_API_TOKEN = #{api_token.inspect}
RUBY_METHOD_NAME = '#{method_name}'
SCRIPT_INFO_YAML = '#{script_info_yaml}'
RUBY_METHOD_PREAMBLE_LINES = #{RUBY_METHOD_PREAMBLE_LINES + 6 + script_info_yaml.lines.count}
RUBY
    end

    RUBY_METHOD_PREAMBLE = <<-RUBY.chomp.freeze
class AutomateMethodException < StandardError
end

begin
  require 'date'
  require 'rubygems'
  $:.unshift("#{Gem.loaded_specs['activesupport'].full_gem_path}/lib")
  require '#{MiqAeMethodService::MiqAeServiceFront.instance_method(:find).source_location.first}'
  require 'active_support/all'
  require 'socket'
  Socket.do_not_reverse_lookup = true  # turn off reverse DNS resolution

  require 'yaml'

  Time.zone = 'UTC'

  MIQ_OK    = 0
  MIQ_WARN  = 4
  MIQ_ERROR = 8
  MIQ_STOP  = 8
  MIQ_ABORT = 16

  $evm = MiqAeMethodService::MiqAeServiceFront.connect_and_find(MIQ_URI, MIQ_API_TOKEN, MIQ_ID)
  raise AutomateMethodException,"Cannot find Service for id=\#{MIQ_ID} and uri=\#{MIQ_URI}" if $evm.nil?
  MIQ_ARGS = $evm.inputs

  # Setup stdout and stderr to go through the logger on the MiqAeService instance ($evm)
  silence_warnings { STDOUT = $stdout = $evm.stdout ; nil}
  silence_warnings { STDERR = $stderr = $evm.stderr ; nil}

rescue Exception => err
  STDERR.puts('The following error occurred during inline method preamble evaluation:')
  STDERR.puts("  \#{err.class}: \#{err.message}")
  STDERR.puts("  \#{err.backtrace.join('\n')}") unless err.kind_of?(AutomateMethodException)
  raise
end

class Exception
  def filter_backtrace(callers)
    return callers unless callers.respond_to?(:collect)

    callers.collect do |c|
      file, line, context = c.split(':')
      if file == "-"
        fqname, line = get_file_info(line.to_i - RUBY_METHOD_PREAMBLE_LINES)
        [fqname, line, context].join(':')
      else
        c
      end
    end
  end

  def backtrace_with_evm
    value = backtrace_without_evm
    value ? filter_backtrace(value) : value
  end

  def get_file_info(line)
    script_info = YAML.load(SCRIPT_INFO_YAML)
    script_info.each do |fqname, range|
      return fqname, line - range.begin if range.cover?(line)
    end
    return RUBY_METHOD_NAME, line
  end

  alias backtrace_without_evm backtrace
  alias backtrace backtrace_with_evm
end

begin
RUBY

    RUBY_METHOD_PREAMBLE_LINES = RUBY_METHOD_PREAMBLE.lines.count

    RUBY_METHOD_POSTSCRIPT = <<-RUBY.freeze
rescue Exception => err
  unless err.kind_of?(SystemExit)
    $evm.log('error', 'The following error occurred during method evaluation:')
    $evm.log('error', "  \#{err.class}: \#{err.message}")
    $evm.log('error', "  \#{err.backtrace[0..-2].join('\n')}")
  end
  raise
ensure
  $evm.disconnect_sql
end
RUBY
  end
end
