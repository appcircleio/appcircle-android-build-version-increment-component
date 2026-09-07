# frozen_string_literal: true

# ─── Coverage ─────────────────────────────────────────────────────────────────
COVERAGE_ENABLED = begin
  require 'coverage'
  Coverage.start
  true
rescue LoadError, StandardError
  false
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'stringio'
require 'rbconfig'
require 'yaml'
require 'json'
require 'English'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

require_relative '../main.rb'

# The 'colored' gem is optional in a bare test environment, but main.rb calls
# String#blue / #red on nearly every output path. Define the colour helpers only
# when the gem is absent so the suite behaves identically either way.
class String
  %i[blue red green yellow cyan].each do |color|
    define_method(color) { self } unless method_defined?(color)
  end
end

# Subprocess runs need the same guarantee, so main.rb is spawned with a stub
# 'colored' on RUBYLIB instead of the real gem.
STUB_LIB_DIR = Dir.mktmpdir('colored_stub')
File.write(File.join(STUB_LIB_DIR, 'colored.rb'), <<~RUBY)
  class String
    %i[blue red green yellow cyan].each do |color|
      define_method(color) { self } unless method_defined?(color)
    end
  end
RUBY

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m"   # bold yellow
  ].freeze

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth.positive?
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f.positive?
    parts << "\e[33m#{s} pending\e[0m" if s.positive?

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

GRADLE_FIXTURE = <<~GRADLE
  android {
      defaultConfig {
          applicationId "io.appcircle.sample"
          versionCode 10
          versionName "1.2.3"
      }
      productFlavors {
          dev {
              versionCode 20
              versionName "2.0.0"
          }
          prod {
              versionCode 30
              versionName "3.0.0"
          }
      }
  }
GRADLE

def capture_stdout
  original = $stdout
  $stdout  = StringIO.new
  yield
  $stdout.string
ensure
  $stdout = original
end

def with_env(pairs)
  previous = {}
  pairs.each_key { |key| previous[key] = [ENV.key?(key), ENV[key]] }
  pairs.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  yield
ensure
  previous.each do |key, (had_key, old)|
    had_key ? ENV[key] = old : ENV.delete(key)
  end
end

# Run main.rb in a subprocess with a clean environment plus the stub 'colored'.
def run_main(env = {})
  clean_env = {
    'AC_PLATFORM_TYPE'            => nil,
    'AC_BUILD_NUMBER_SOURCE'      => nil,
    'AC_VERSION_NUMBER_SOURCE'    => nil,
    'AC_BUILD_OFFSET'             => nil,
    'AC_VERSION_OFFSET'           => nil,
    'AC_VERSION_STRATEGY'         => nil,
    'AC_OMIT_ZERO_PATCH_VERSION'  => nil,
    'AC_VERSION_FLAVOR'           => nil,
    'AC_REPOSITORY_DIR'           => nil,
    'AC_PROJECT_PATH'             => nil,
    'AC_MODULE'                   => nil,
    'AC_ANDROID_BUILD_NUMBER'     => nil,
    'AC_ANDROID_VERSION_NUMBER'   => nil,
    'AC_ENV_FILE_PATH'            => nil,
    'RUBYLIB'                     => STUB_LIB_DIR
  }.merge(env)
  Open3.capture3(clean_env, RbConfig.ruby, MAIN_RB)
end

def print_coverage_report
  return unless COVERAGE_ENABLED

  result = Coverage.result
  lines  = result[MAIN_RB] || result[File.realpath(MAIN_RB)]
  if lines.nil?
    puts "\n  Coverage: main.rb was not tracked"
    return
  end

  executable = lines.compact
  covered    = executable.count { |hits| hits.positive? }
  total      = executable.size
  percent    = total.zero? ? 0.0 : (covered * 100.0 / total)
  puts format("\n  Coverage: %d/%d executable lines in main.rb (%.1f%%)", covered, total, percent)
rescue StandardError => e
  puts "\n  Coverage: unavailable (#{e.class})"
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe 'Required libraries' do
  %w[yaml pathname tempfile fileutils json rexml/document].each do |lib|
    it "loads '#{lib}'" do
      expect { require lib }.not_to raise_error
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#env_has_key' do
  context 'positive paths' do
    it 'returns the value when the key is set' do
      with_env('_TEST_VAR' => 'value') { expect(env_has_key('_TEST_VAR')).to eq('value') }
    end

    it 'resolves a $-prefixed value through a second lookup' do
      with_env('_TEST_VAR' => '$_TEST_TARGET', '_TEST_TARGET' => 'resolved') do
        expect(env_has_key('_TEST_VAR')).to eq('resolved')
      end
    end

    it 'returns nil when the $-referenced variable does not exist' do
      with_env('_TEST_VAR' => '$_TEST_MISSING', '_TEST_MISSING' => nil) do
        expect(env_has_key('_TEST_VAR')).to be_nil
      end
    end
  end

  context 'negative paths' do
    it 'aborts when the key is missing' do
      with_env('_TEST_VAR' => nil) { expect { env_has_key('_TEST_VAR') }.to raise_error(SystemExit) }
    end

    it 'aborts when the value is an empty string' do
      with_env('_TEST_VAR' => '') { expect { env_has_key('_TEST_VAR') }.to raise_error(SystemExit) }
    end

    it 'exits with status 1' do
      with_env('_TEST_VAR' => nil) do
        expect { env_has_key('_TEST_VAR') }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end

    it 'names the missing key on stderr' do
      with_env('_TEST_VAR' => nil) do
        expect { env_has_key('_TEST_VAR') }.to output(/Missing _TEST_VAR\./).to_stderr
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#get_env' do
  context 'positive paths' do
    it 'returns the value when the key is set' do
      with_env('_TEST_VAR' => 'value') { expect(get_env('_TEST_VAR')).to eq('value') }
    end

    it 'resolves a $-prefixed value through a second lookup' do
      with_env('_TEST_VAR' => '$_TEST_TARGET', '_TEST_TARGET' => 'resolved') do
        expect(get_env('_TEST_VAR')).to eq('resolved')
      end
    end
  end

  context 'negative paths' do
    it 'returns nil when the key is missing' do
      with_env('_TEST_VAR' => nil) { expect(get_env('_TEST_VAR')).to be_nil }
    end

    it 'returns nil when the value is an empty string' do
      with_env('_TEST_VAR' => '') { expect(get_env('_TEST_VAR')).to be_nil }
    end

    it 'never aborts' do
      with_env('_TEST_VAR' => nil) { expect { get_env('_TEST_VAR') }.not_to raise_error }
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#abort_with1' do
  it 'exits with status 1' do
    expect { capture_stdout { abort_with1('boom') } }
      .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
  end

  it 'prints the message with the @@[error] marker on stdout' do
    output = ''
    begin
      output = capture_stdout { abort_with1('boom') }
    rescue SystemExit
      nil
    end
    expect(output).to include('@@[error] boom')
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'env file writers' do
  let(:tmpdir)   { Dir.mktmpdir('env_file') }
  let(:env_file) { File.join(tmpdir, 'env') }

  after { FileUtils.rm_rf(tmpdir) }

  describe '#set_new_env_values' do
    it 'writes both the version code and the version name' do
      with_env('AC_ENV_FILE_PATH' => env_file) { set_new_env_values('42', '1.2.3') }
      contents = File.read(env_file)
      expect(contents).to include('AC_ANDROID_NEW_VERSION_CODE=42')
      expect(contents).to include('AC_ANDROID_NEW_VERSION_NAME=1.2.3')
    end

    it 'appends instead of truncating' do
      File.write(env_file, "EXISTING=1\n")
      with_env('AC_ENV_FILE_PATH' => env_file) { set_new_env_values('42', '1.2.3') }
      expect(File.read(env_file)).to include('EXISTING=1')
    end

    it 'raises TypeError when AC_ENV_FILE_PATH is unset' do
      with_env('AC_ENV_FILE_PATH' => nil) do
        expect { set_new_env_values('42', '1.2.3') }.to raise_error(TypeError)
      end
    end

    it 'raises Errno::ENOENT when AC_ENV_FILE_PATH is empty' do
      with_env('AC_ENV_FILE_PATH' => '') do
        expect { set_new_env_values('42', '1.2.3') }.to raise_error(Errno::ENOENT)
      end
    end
  end

  describe '#set_new_env_version_code' do
    it 'writes only the version code' do
      with_env('AC_ENV_FILE_PATH' => env_file) { set_new_env_version_code('7') }
      contents = File.read(env_file)
      expect(contents).to include('AC_ANDROID_NEW_VERSION_CODE=7')
      expect(contents).not_to include('AC_ANDROID_NEW_VERSION_NAME')
    end

    it 'raises TypeError when AC_ENV_FILE_PATH is unset' do
      with_env('AC_ENV_FILE_PATH' => nil) do
        expect { set_new_env_version_code('7') }.to raise_error(TypeError)
      end
    end
  end

  describe '#set_new_env_version_name' do
    it 'writes only the version name' do
      with_env('AC_ENV_FILE_PATH' => env_file) { set_new_env_version_name('9.9.9') }
      contents = File.read(env_file)
      expect(contents).to include('AC_ANDROID_NEW_VERSION_NAME=9.9.9')
      expect(contents).not_to include('AC_ANDROID_NEW_VERSION_CODE')
    end

    it 'raises TypeError when AC_ENV_FILE_PATH is unset' do
      with_env('AC_ENV_FILE_PATH' => nil) do
        expect { set_new_env_version_name('9.9.9') }.to raise_error(TypeError)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#is_integer?' do
  context 'positive paths' do
    it 'accepts a plain integer string' do
      expect(is_integer?('123')).to be true
    end

    it 'accepts a single digit' do
      expect(is_integer?('7')).to be true
    end
  end

  context 'negative paths' do
    it 'rejects a version-like string' do
      expect(is_integer?('1.2.3')).to be false
    end

    it 'rejects a negative number (the minus sign is a non-digit)' do
      expect(is_integer?('-5')).to be false
    end

    it 'rejects letters' do
      expect(is_integer?('12a')).to be false
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#is_integer_include_negative?' do
  context 'positive paths' do
    it 'accepts a positive integer' do
      expect(is_integer_include_negative?('123')).to be true
    end

    it 'accepts a negative integer' do
      expect(is_integer_include_negative?('-5')).to be true
    end
  end

  context 'negative paths' do
    it 'rejects an empty string' do
      expect(is_integer_include_negative?('')).to be false
    end

    it 'rejects a decimal' do
      expect(is_integer_include_negative?('1.5')).to be false
    end

    it 'rejects trailing characters' do
      expect(is_integer_include_negative?('12a')).to be false
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#calculate_build_number' do
  context 'positive paths' do
    it 'adds the offset to a plain build number' do
      expect(calculate_build_number('10', '1')).to eq('11')
    end

    it 'adds the offset to the last segment of a dotted build number' do
      expect(calculate_build_number('1.2.3', '2')).to eq('1.2.5')
    end

    it 'accepts an integer offset' do
      expect(calculate_build_number('10', 5)).to eq('15')
    end

    it 'returns the same number for a zero offset' do
      expect(calculate_build_number('10', '0')).to eq('10')
    end

    it 'supports a negative offset' do
      expect(calculate_build_number('10', '-3')).to eq('7')
    end
  end

  context 'negative paths' do
    it 'treats a non-numeric offset as zero' do
      expect(calculate_build_number('10', 'abc')).to eq('10')
    end

    it 'coerces a non-numeric build number to zero' do
      expect(calculate_build_number('abc', '2')).to eq('2')
    end

    it 'raises NoMethodError for a nil build number' do
      expect { calculate_build_number(nil, '1') }.to raise_error(NoMethodError)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#calculate_version_number' do
  context 'when the offset is zero' do
    it 'returns the version untouched' do
      expect(calculate_version_number('1.2.3', 'patch', false, '0')).to eq('1.2.3')
    end

    it 'ignores the strategy entirely' do
      expect(calculate_version_number('1.2.3', 'major', true, 0)).to eq('1.2.3')
    end
  end

  context 'patch strategy' do
    it 'increments the patch segment' do
      expect(calculate_version_number('1.2.3', 'patch', false, '1')).to eq('1.2.4')
    end

    it 'leaves major and minor untouched' do
      expect(calculate_version_number('1.2.3', 'patch', false, '2')).to eq('1.2.5')
    end
  end

  context 'minor strategy' do
    it 'increments minor and resets patch to zero' do
      expect(calculate_version_number('1.2.3', 'minor', false, '1')).to eq('1.3.0')
    end
  end

  context 'major strategy' do
    it 'increments major and resets minor and patch to zero' do
      expect(calculate_version_number('1.2.3', 'major', false, '1')).to eq('2.0.0')
    end
  end

  context 'omit_zero' do
    it 'drops a trailing zero patch segment' do
      expect(calculate_version_number('1.2.3', 'minor', true, '1')).to eq('1.3')
    end

    it 'keeps a non-zero patch segment' do
      expect(calculate_version_number('1.2.3', 'patch', true, '1')).to eq('1.2.4')
    end
  end

  context 'negative paths' do
    it 'returns the version unchanged for an unknown strategy' do
      expect(calculate_version_number('1.2.3', 'nonsense', false, '1')).to eq('1.2.3')
    end

    it 'treats a non-numeric offset as zero and returns the version unchanged' do
      expect(calculate_version_number('1.2.3', 'patch', false, 'abc')).to eq('1.2.3')
    end

    it 'fills in a missing patch segment for the patch strategy' do
      expect(calculate_version_number('1.2', 'patch', false, '1')).to eq('1.2.1')
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#is_version_code_int' do
  context 'positive paths' do
    it 'accepts a positive integer' do
      expect { capture_stdout { is_version_code_int('12') } }.not_to raise_error
    end

    it 'accepts a negative integer' do
      expect { capture_stdout { is_version_code_int('-3') } }.not_to raise_error
    end
  end

  context 'negative paths' do
    it 'aborts on a decimal version code' do
      expect { capture_stdout { is_version_code_int('1.2') } }.to raise_error(SystemExit)
    end

    it 'aborts on an empty version code' do
      expect { capture_stdout { is_version_code_int('') } }.to raise_error(SystemExit)
    end

    it 'reports the reason with the @@[error] marker' do
      output = ''
      begin
        output = capture_stdout { is_version_code_int('abc') }
      rescue SystemExit
        nil
      end
      expect(output).to include('@@[error] versionCode must be integer.')
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#check_version_code' do
  context 'positive paths' do
    it 'accepts a valid version code' do
      expect { capture_stdout { check_version_code('11') } }.not_to raise_error
    end

    it 'accepts the lower bound of 1' do
      expect { capture_stdout { check_version_code('1') } }.not_to raise_error
    end

    it 'accepts the upper bound of 2100000000' do
      expect { capture_stdout { check_version_code('2100000000') } }.not_to raise_error
    end

    it 'prints the new version code' do
      expect(capture_stdout { check_version_code('11') }).to include('New Version Code: 11')
    end
  end

  context 'negative paths' do
    it 'aborts on a non-integer version code' do
      expect { capture_stdout { check_version_code('1.2') } }.to raise_error(SystemExit)
    end

    it 'aborts above 2100000000' do
      expect { capture_stdout { check_version_code('2100000001') } }.to raise_error(SystemExit)
    end

    it 'aborts below 1' do
      expect { capture_stdout { check_version_code('0') } }.to raise_error(SystemExit)
    end

    it 'aborts on a negative version code' do
      expect { capture_stdout { check_version_code('-1') } }.to raise_error(SystemExit)
    end

    it 'explains the upper bound' do
      output = ''
      begin
        output = capture_stdout { check_version_code('2100000001') }
      rescue SystemExit
        nil
      end
      expect(output).to include('versionCode cannot be bigger than 2100000000.')
    end

    it 'explains the lower bound' do
      output = ''
      begin
        output = capture_stdout { check_version_code('0') }
      rescue SystemExit
        nil
      end
      expect(output).to include('versionCode cannot be smaller than 1.')
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#check_version_name' do
  context 'positive paths' do
    it 'accepts a three-part numeric version' do
      expect { capture_stdout { check_version_name('1.2.3') } }.not_to raise_error
    end

    it 'accepts a single number' do
      expect { capture_stdout { check_version_name('7') } }.not_to raise_error
    end
  end

  context 'negative paths' do
    it 'aborts when a part is not an integer' do
      expect { capture_stdout { check_version_name('1.2.3-beta') } }.to raise_error(SystemExit)
    end

    it 'aborts on a fully alphabetic version name' do
      expect { capture_stdout { check_version_name('alpha') } }.to raise_error(SystemExit)
    end

    it 'explains that every part must be an integer' do
      output = ''
      begin
        output = capture_stdout { check_version_name('1.0.0-rc1') }
      rescue SystemExit
        nil
      end
      expect(output).to include('all parts of the versionName must be integers')
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'gradle file helpers' do
  let(:tmpdir)      { Dir.mktmpdir('gradle') }
  let(:gradle_file) { File.join(tmpdir, 'build.gradle') }

  before { File.write(gradle_file, GRADLE_FIXTURE) }
  after  { FileUtils.rm_rf(tmpdir) }

  describe '#get_gradle_value' do
    context 'positive paths' do
      it 'reads the defaultConfig versionCode when no flavor is given' do
        expect(get_gradle_value(gradle_file, 'versionCode', nil)).to eq('10')
      end

      it 'reads the defaultConfig versionName when no flavor is given' do
        expect(get_gradle_value(gradle_file, 'versionName', '')).to eq('1.2.3')
      end

      it 'reads a flavor specific versionCode' do
        expect(get_gradle_value(gradle_file, 'versionCode', 'dev')).to eq('20')
      end

      it 'reads a flavor specific versionName' do
        expect(get_gradle_value(gradle_file, 'versionName', 'prod')).to eq('3.0.0')
      end

      it 'stops at the first match rather than the last' do
        expect(get_gradle_value(gradle_file, 'versionCode', nil)).not_to eq('30')
      end
    end

    context 'negative paths' do
      it 'aborts when the key is absent' do
        expect { capture_stdout { get_gradle_value(gradle_file, 'buildToolsVersion', nil) } }
          .to raise_error(SystemExit)
      end

      it 'reports the gradle file path in the error' do
        output = ''
        begin
          output = capture_stdout { get_gradle_value(gradle_file, 'buildToolsVersion', nil) }
        rescue SystemExit
          nil
        end
        expect(output).to include(gradle_file)
      end

      it 'aborts when the requested flavor does not exist' do
        expect { capture_stdout { get_gradle_value(gradle_file, 'versionCode', 'staging') } }
          .to raise_error(SystemExit)
      end

      it 'raises Errno::ENOENT for a missing gradle file' do
        expect { get_gradle_value(File.join(tmpdir, 'nope.gradle'), 'versionCode', nil) }
          .to raise_error(Errno::ENOENT)
      end
    end
  end

  describe '#set_gradle_value' do
    context 'positive paths' do
      it 'rewrites the defaultConfig versionCode when no flavor is given' do
        set_gradle_value(gradle_file, 'versionCode', '11', nil)
        expect(File.read(gradle_file)).to include('versionCode 11')
      end

      it 'rewrites the defaultConfig versionName keeping the quotes' do
        set_gradle_value(gradle_file, 'versionName', '1.2.4', nil)
        expect(File.read(gradle_file)).to include('versionName "1.2.4"')
      end

      it 'preserves the surrounding file content' do
        set_gradle_value(gradle_file, 'versionCode', '11', nil)
        expect(File.read(gradle_file)).to include('applicationId "io.appcircle.sample"')
      end

      it 'preserves the original indentation' do
        set_gradle_value(gradle_file, 'versionCode', '11', nil)
        expect(File.read(gradle_file)).to include('        versionCode 11')
      end

      it 'rewrites a flavor specific value' do
        set_gradle_value(gradle_file, 'versionCode', '21', 'dev')
        expect(File.read(gradle_file)).to include('versionCode 21')
      end

      it 'leaves defaultConfig untouched when a flavor is targeted' do
        set_gradle_value(gradle_file, 'versionCode', '21', 'dev')
        expect(File.read(gradle_file)).to include('versionCode 10')
      end
    end

    context 'known behaviours worth pinning' do
      # These two are current behaviour, not necessarily desired behaviour.
      it 'also rewrites later flavor blocks once the target flavor matched' do
        set_gradle_value(gradle_file, 'versionCode', '21', 'dev')
        expect(File.read(gradle_file)).not_to include('versionCode 30')
      end

      it 'drops a trailing comment on the rewritten line' do
        File.write(gradle_file, "        versionCode 10 // keep me\n")
        set_gradle_value(gradle_file, 'versionCode', '11', nil)
        expect(File.read(gradle_file)).not_to include('// keep me')
      end
    end

    context 'negative paths' do
      it 'leaves the file unchanged when the key is absent' do
        set_gradle_value(gradle_file, 'buildToolsVersion', '34.0.0', nil)
        expect(File.read(gradle_file)).to eq(GRADLE_FIXTURE)
      end

      it 'raises Errno::ENOENT for a missing gradle file' do
        expect { set_gradle_value(File.join(tmpdir, 'nope.gradle'), 'versionCode', '11', nil) }
          .to raise_error(Errno::ENOENT)
      end
    end
  end

  describe '#get_gradle_path' do
    let(:repo) { Dir.mktmpdir('repo') }

    after { FileUtils.rm_rf(repo) }

    it 'returns the build.gradle path of the module' do
      FileUtils.mkdir_p(File.join(repo, 'app'))
      File.write(File.join(repo, 'app', 'build.gradle'), GRADLE_FIXTURE)
      with_env('AC_REPOSITORY_DIR' => repo, 'AC_MODULE' => 'app', 'AC_PROJECT_PATH' => nil) do
        expect(get_gradle_path).to eq(File.join(repo, 'app', 'build.gradle'))
      end
    end

    it 'prefers build.gradle.kts when both exist' do
      FileUtils.mkdir_p(File.join(repo, 'app'))
      File.write(File.join(repo, 'app', 'build.gradle'), GRADLE_FIXTURE)
      File.write(File.join(repo, 'app', 'build.gradle.kts'), GRADLE_FIXTURE)
      with_env('AC_REPOSITORY_DIR' => repo, 'AC_MODULE' => 'app', 'AC_PROJECT_PATH' => nil) do
        expect(get_gradle_path).to end_with('build.gradle.kts')
      end
    end

    it 'honours AC_PROJECT_PATH' do
      FileUtils.mkdir_p(File.join(repo, 'android', 'app'))
      File.write(File.join(repo, 'android', 'app', 'build.gradle'), GRADLE_FIXTURE)
      with_env('AC_REPOSITORY_DIR' => repo, 'AC_MODULE' => 'app', 'AC_PROJECT_PATH' => './android') do
        expect(get_gradle_path).to eq(File.join(repo, 'android', 'app', 'build.gradle'))
      end
    end

    it 'returns the plain build.gradle path even when neither file exists' do
      with_env('AC_REPOSITORY_DIR' => repo, 'AC_MODULE' => 'app', 'AC_PROJECT_PATH' => nil) do
        expect(get_gradle_path).to end_with('build.gradle')
      end
    end

    it 'aborts when AC_REPOSITORY_DIR is missing' do
      with_env('AC_REPOSITORY_DIR' => nil, 'AC_MODULE' => 'app') do
        expect { get_gradle_path }.to raise_error(SystemExit)
      end
    end

    it 'aborts when AC_MODULE is missing' do
      with_env('AC_REPOSITORY_DIR' => repo, 'AC_MODULE' => nil) do
        expect { get_gradle_path }.to raise_error(SystemExit)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'flutter helpers' do
  let(:repo)     { Dir.mktmpdir('flutter_repo') }
  let(:android)  { File.join(repo, 'android') }
  let(:pubspec)  { File.join(repo, 'pubspec.yaml') }

  before do
    FileUtils.mkdir_p(android)
    File.write(pubspec, "name: sample\nversion: 1.2.3+10\n")
  end

  after { FileUtils.rm_rf(repo) }

  describe '#get_pubspec_location' do
    it 'finds pubspec.yaml next to the android directory' do
      with_env('AC_REPOSITORY_DIR' => repo, 'AC_PROJECT_PATH' => nil) do
        expect(get_pubspec_location).to eq(pubspec)
      end
    end

    it 'raises when no pubspec.yaml exists' do
      FileUtils.rm_f(pubspec)
      with_env('AC_REPOSITORY_DIR' => repo, 'AC_PROJECT_PATH' => nil) do
        expect { get_pubspec_location }.to raise_error(RuntimeError, /No pubspec.yaml found/)
      end
    end

    it 'aborts when AC_REPOSITORY_DIR is missing' do
      with_env('AC_REPOSITORY_DIR' => nil) do
        expect { get_pubspec_location }.to raise_error(SystemExit)
      end
    end
  end

  describe '#get_flutter_version' do
    it 'returns the version string from the pubspec' do
      expect(get_flutter_version(pubspec)).to eq('1.2.3+10')
    end

    it 'returns nil when the pubspec has no version key' do
      File.write(pubspec, "name: sample\n")
      expect(get_flutter_version(pubspec)).to be_nil
    end

    it 'raises when the pubspec cannot be read' do
      expect { get_flutter_version(File.join(repo, 'missing.yaml')) }
        .to raise_error(RuntimeError, /Reading the pubspec failed!/)
    end
  end

  describe '#set_flutter_version' do
    it 'writes the new version into the pubspec' do
      set_flutter_version(pubspec, '2.0.0+11')
      expect(File.read(pubspec)).to include('version: 2.0.0+11')
    end

    it 'keeps the rest of the pubspec intact' do
      set_flutter_version(pubspec, '2.0.0+11')
      expect(File.read(pubspec)).to include('name: sample')
    end

    it 'raises when the pubspec does not exist' do
      expect { set_flutter_version(File.join(repo, 'missing.yaml'), '2.0.0+11') }
        .to raise_error(RuntimeError, /Writing the pubspec failed!/)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#load_xml' do
  let(:tmpdir) { Dir.mktmpdir('xml') }
  let(:xml)    { File.join(tmpdir, 'AndroidManifest.xml') }

  after { FileUtils.rm_rf(tmpdir) }

  it 'parses a manifest and exposes its attributes' do
    File.write(xml, '<manifest android:versionCode="10" android:versionName="1.2.3"/>')
    document = load_xml(xml)
    expect(document.root.attribute('android:versionCode').value).to eq('10')
  end

  it 'raises Errno::ENOENT for a missing file' do
    expect { load_xml(File.join(tmpdir, 'nope.xml')) }.to raise_error(Errno::ENOENT)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'main.rb as a script' do
  let(:tmpdir)   { Dir.mktmpdir('script') }
  let(:env_file) { File.join(tmpdir, 'env') }

  after { FileUtils.rm_rf(tmpdir) }

  describe 'platform handling' do
    it 'exits 1 for an unsupported platform' do
      out, _err, status = run_main('AC_PLATFORM_TYPE' => 'Windows', 'AC_BUILD_NUMBER_SOURCE' => 'gradle')
      expect(status.exitstatus).to eq(1)
      expect(out).to include('Platform not supported')
    end

    it 'exits 0 when neither a version code nor a version name source is set' do
      out, _err, status = run_main('AC_PLATFORM_TYPE' => 'JavaKotlin')
      expect(status.exitstatus).to eq(0)
      expect(out).to include('No Version Code and Version Name source specified. Exiting.')
    end

    it 'fails when AC_PLATFORM_TYPE is unset (nil is printed before any validation)' do
      _out, _err, status = run_main('AC_BUILD_NUMBER_SOURCE' => 'gradle')
      expect(status.exitstatus).not_to eq(0)
    end
  end

  describe 'required environment variables on the gradle path' do
    it 'aborts when AC_REPOSITORY_DIR is missing' do
      _out, err, status = run_main(
        'AC_PLATFORM_TYPE'       => 'JavaKotlin',
        'AC_BUILD_NUMBER_SOURCE' => 'gradle',
        'AC_MODULE'              => 'app'
      )
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Missing AC_REPOSITORY_DIR.')
    end

    it 'aborts when AC_REPOSITORY_DIR is empty' do
      _out, err, status = run_main(
        'AC_PLATFORM_TYPE'       => 'JavaKotlin',
        'AC_BUILD_NUMBER_SOURCE' => 'gradle',
        'AC_REPOSITORY_DIR'      => '',
        'AC_MODULE'              => 'app'
      )
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Missing AC_REPOSITORY_DIR.')
    end

    it 'aborts when AC_MODULE is missing' do
      _out, err, status = run_main(
        'AC_PLATFORM_TYPE'       => 'JavaKotlin',
        'AC_BUILD_NUMBER_SOURCE' => 'gradle',
        'AC_REPOSITORY_DIR'      => tmpdir
      )
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Missing AC_MODULE.')
    end

    it 'aborts when AC_MODULE is empty' do
      _out, err, status = run_main(
        'AC_PLATFORM_TYPE'       => 'JavaKotlin',
        'AC_BUILD_NUMBER_SOURCE' => 'gradle',
        'AC_REPOSITORY_DIR'      => tmpdir,
        'AC_MODULE'              => ''
      )
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Missing AC_MODULE.')
    end

    it 'aborts when AC_ANDROID_BUILD_NUMBER is missing for the env source' do
      _out, err, status = run_main(
        'AC_PLATFORM_TYPE'       => 'JavaKotlin',
        'AC_BUILD_NUMBER_SOURCE' => 'env',
        'AC_REPOSITORY_DIR'      => tmpdir,
        'AC_MODULE'              => 'app'
      )
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Missing AC_ANDROID_BUILD_NUMBER.')
    end

    it 'aborts when AC_ANDROID_VERSION_NUMBER is missing for the env source' do
      _out, err, status = run_main(
        'AC_PLATFORM_TYPE'         => 'JavaKotlin',
        'AC_VERSION_NUMBER_SOURCE' => 'env',
        'AC_REPOSITORY_DIR'        => tmpdir,
        'AC_MODULE'                => 'app'
      )
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Missing AC_ANDROID_VERSION_NUMBER.')
    end
  end

  describe 'JavaKotlin end to end against a gradle fixture' do
    let(:module_dir) { File.join(tmpdir, 'app') }

    before do
      FileUtils.mkdir_p(module_dir)
      File.write(File.join(module_dir, 'build.gradle'), GRADLE_FIXTURE)
      FileUtils.touch(env_file)
    end

    def run_gradle_flow(extra = {})
      run_main({
        'AC_PLATFORM_TYPE'         => 'JavaKotlin',
        'AC_BUILD_NUMBER_SOURCE'   => 'gradle',
        'AC_VERSION_NUMBER_SOURCE' => 'gradle',
        'AC_BUILD_OFFSET'          => '1',
        'AC_VERSION_OFFSET'        => '1',
        'AC_VERSION_STRATEGY'      => 'patch',
        'AC_REPOSITORY_DIR'        => tmpdir,
        'AC_MODULE'                => 'app',
        'AC_ENV_FILE_PATH'         => env_file
      }.merge(extra))
    end

    it 'exits successfully' do
      _out, _err, status = run_gradle_flow
      expect(status.exitstatus).to eq(0)
    end

    it 'increments the versionCode in the gradle file' do
      run_gradle_flow
      expect(File.read(File.join(module_dir, 'build.gradle'))).to include('versionCode 11')
    end

    it 'increments the versionName in the gradle file' do
      run_gradle_flow
      expect(File.read(File.join(module_dir, 'build.gradle'))).to include('versionName "1.2.4"')
    end

    it 'exports the new version code to the env file' do
      run_gradle_flow
      expect(File.read(env_file)).to include('AC_ANDROID_NEW_VERSION_CODE=11')
    end

    it 'exports the new version name to the env file' do
      run_gradle_flow
      expect(File.read(env_file)).to include('AC_ANDROID_NEW_VERSION_NAME=1.2.4')
    end

    it 'keeps the versions unchanged for a zero offset' do
      run_gradle_flow('AC_BUILD_OFFSET' => '0', 'AC_VERSION_OFFSET' => '0')
      contents = File.read(File.join(module_dir, 'build.gradle'))
      expect(contents).to include('versionCode 10')
      expect(contents).to include('versionName "1.2.3"')
    end

    it 'reports the current version code on stdout' do
      out, _err, _status = run_gradle_flow
      expect(out).to include('Current Version Code: 10')
    end
  end

  describe 'loading main.rb as a library' do
    it 'does not execute the script body when required' do
      out, _err, status = Open3.capture3(
        { 'AC_PLATFORM_TYPE' => nil, 'RUBYLIB' => STUB_LIB_DIR },
        RbConfig.ruby, '-e', "require '#{MAIN_RB}'; puts 'loaded'"
      )
      expect(status.exitstatus).to eq(0)
      expect(out).to include('loaded')
      expect(out).not_to include('Platform:')
    end

    it 'defines the helper functions when required' do
      out, _err, _status = Open3.capture3(
        { 'RUBYLIB' => STUB_LIB_DIR },
        RbConfig.ruby, '-e',
        "require '#{MAIN_RB}'; puts %w[env_has_key get_env calculate_build_number calculate_version_number].all? { |m| respond_to?(m, true) }"
      )
      expect(out).to include('true')
    end
  end
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color = true
    config.order = :defined
    config.mock_with :rspec do |mocks|
      mocks.verify_partial_doubles = false
    end
    config.after(:suite) { FileUtils.rm_rf(STUB_LIB_DIR) }
  end

  status = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit status
end
