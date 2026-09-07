require 'yaml'
require 'colored'
require 'pathname'
require 'tempfile'
require 'fileutils'
require 'json'
require 'rexml/document'

def env_has_key(key)
  value = ENV[key]
  if !value.nil? && value != ''
    value.start_with?('$') ? ENV[value[1..]] : value
  else
    abort("Missing #{key}.")
  end
end

def abort_with1(message)
  puts "@@[error] #{message}"
  exit 1
end

def get_env(key)
  value = ENV[key]
  if !value.nil? && value != ''
    value.start_with?('$') ? ENV[value[1..]] : value
  end
end

def set_new_env_values(new_version_code, new_version_name)
  open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
    f.puts "AC_ANDROID_NEW_VERSION_CODE=#{new_version_code}"
    f.puts "AC_ANDROID_NEW_VERSION_NAME=#{new_version_name}"
}
end

def set_new_env_version_code(new_version_code)
  open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
    f.puts "AC_ANDROID_NEW_VERSION_CODE=#{new_version_code}"
  }
end

def set_new_env_version_name(new_version_name)
  open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
    f.puts "AC_ANDROID_NEW_VERSION_NAME=#{new_version_name}"
  }
end

def load_xml(file_path)
  REXML::Document.new(File.open(file_path))
end

def is_integer?(str)
  /(\D+)/.match(str).nil?
end

def is_integer_include_negative?(str)
  /\A-?\d+\z/.match?(str)
end

def get_gradle_path
  repository_path = env_has_key('AC_REPOSITORY_DIR')
  project_path = get_env('AC_PROJECT_PATH') || '.'
  android_module = env_has_key('AC_MODULE')
  project_path = File.expand_path(project_path, repository_path)
  gradle_dir = File.join(project_path, android_module)
  build_gradle_kts_path = File.join(gradle_dir, 'build.gradle.kts')
  build_gradle_path = File.join(gradle_dir, 'build.gradle')

  File.exist?(build_gradle_kts_path) ? build_gradle_kts_path.to_s : build_gradle_path.to_s
end

def get_pubspec_location
  repository_path = env_has_key('AC_REPOSITORY_DIR')
  project_path = get_env('AC_PROJECT_PATH') || './android'
  project_path = File.join(repository_path, project_path)
  pubspec_location = File.expand_path('../pubspec.yaml', project_path)
  raise 'No pubspec.yaml found! The pubspec.yaml file is required to set new versions.'.red unless File.exist?(pubspec_location)
  pubspec_location.to_s
end

def get_flutter_version(pubspec_location)
  begin
    pubspec = YAML.load_file(pubspec_location)
  rescue StandardError
    raise 'Reading the pubspec failed!'
  end
  pubspec['version']
end

def set_flutter_version(pubspec_location, version)
  pubspec = File.read(pubspec_location)
  pubspec_modified = pubspec.gsub(/version:.*/, "version: #{version}")
  File.write(pubspec_location, pubspec_modified)
rescue StandardError
  raise 'Writing the pubspec failed!'
end

def set_gradle_value(file_path, key, new_value, flavor)
  regex = Regexp.new(/^(?<whitespace>\s*)(?<key>\b#{key}\b\s*(=|:)?\s*)(?<left>['"]?)(?<value>[a-zA-Z0-9\-._+]*)(?<right>['"]?)(?<comment>.*)/)
  flavor_specified = !(flavor.nil? or flavor.empty?)
  regex_flavor = Regexp.new(/[ \t]#{flavor}[ \t]/)
  product_flavors_section = false
  flavor_found = false
  temp_file = Tempfile.new('versioning')
  File.open(file_path, 'r') do |file|
    file.each_line do |line|
      if flavor_specified && !product_flavors_section
        unless line.include?('productFlavors') || product_flavors_section
          temp_file.puts line
          next
        end
        product_flavors_section = true
      end

      if flavor_specified && !flavor_found
        unless line.match(regex_flavor)
          temp_file.puts line
          next
        end
        flavor_found = true
      end

      unless line.match(regex)
        temp_file.puts line
        next
      end
      line = line.gsub regex, "\\k<whitespace>\\k<key>\\k<left>#{new_value}\\k<right>"
      temp_file.puts line
    end
    file.close
  end
  temp_file.rewind
  temp_file.close
  FileUtils.mv(temp_file.path, file_path)
  temp_file.unlink
end

def get_gradle_value(file_path, key, flavor)
  flavor_specified = !(flavor.nil? or flavor.empty?)
  regex = Regexp.new(/^\s*(?<key>\b#{key}\b\s*(=|:)?\s*)(?<left>['"]?)(?<value>[a-zA-Z0-9\-._+]*)(?<right>['"]?)(?<comment>.*)/)
  regex_flavor = Regexp.new(/[ \t]#{flavor}[ \t]/)
  value = ''
  found = false
  flavor_found = false
  product_flavors_section = false
  File.open(file_path, 'r') do |file|
    file.each_line do |line|
      if flavor_specified && !product_flavors_section
        next unless line.include? 'productFlavors'

        product_flavors_section = true
      end

      if flavor_specified && !flavor_found
        next unless line.match(regex_flavor)

        flavor_found = true
      end

      next unless line.match(regex) && !found

      key, left, value, right, comment = line.match(regex).captures
      break
    end
    file.close
  end

  if value == '' || value.nil?
    error_msg = "#{key} not found in gradle file (#{file_path})."
    abort_with1(error_msg)
  end
  value
end

def calculate_version_number(current_version, strategy, omit_zero, offset)
  if offset.to_i == 0
    return current_version
  end
  version_array = current_version.split('.').map(&:to_i)
  case strategy
  when 'patch'
    version_array[2] = (version_array[2] || 0) + offset.to_i
  when 'minor'
    version_array[1] = (version_array[1] || 0) + offset.to_i
    version_array[2] = version_array[2] = 0
  when 'major'
    version_array[0] = (version_array[0] || 0) + offset.to_i
    version_array[1] = version_array[1] = 0
    version_array[1] = version_array[2] = 0
  end

  version_array.pop if omit_zero && (version_array[2]).zero?
  version_array.join('.')
end

def is_version_code_int(version_code)
  if !is_integer_include_negative?(version_code)
    error_msg = "versionCode must be integer."
    abort_with1(error_msg)
  end
end

def check_version_code(new_version_code)
  puts "New Version Code: #{new_version_code.blue}"

  if !is_integer_include_negative?(new_version_code)
    error_msg = "versionCode must be integer."
    abort_with1(error_msg)
  end
  if new_version_code.to_i > 2_100_000_000
    error_msg = "versionCode cannot be bigger than 2100000000."
    abort_with1(error_msg)
  end
  if new_version_code.to_i < 1
    error_msg = "versionCode cannot be smaller than 1."
    abort_with1(error_msg)
  end
end

def check_version_name(new_version_name)
  version_parts = new_version_name.split('.')
  valid_version = version_parts.all? { |part| is_integer_include_negative?("#{part}") }
  unless valid_version
    error_msg = "To increment the versionName, all parts of the versionName must be integers."
    abort_with1(error_msg)
  end
end

def calculate_build_number(current_build_number, offset)
  build_array = current_build_number.split('.').map(&:to_i)
  build_array[-1] = build_array[-1] + offset.to_i
  build_array.join('.')
end

if __FILE__ == $PROGRAM_NAME

platform = get_env('AC_PLATFORM_TYPE')
build_number_source = get_env('AC_BUILD_NUMBER_SOURCE')
build_offset = get_env('AC_BUILD_OFFSET') || 0
version_number_source = get_env('AC_VERSION_NUMBER_SOURCE')
version_offset = get_env('AC_VERSION_OFFSET') || 0
omit_zero = get_env('AC_OMIT_ZERO_PATCH_VERSION') == 'true'
version_strategy = get_env('AC_VERSION_STRATEGY') || 'keep'

puts "Platform: #{platform.blue}"
if build_number_source.nil? && version_number_source.nil?
  puts "No Version Code and Version Name source specified. Exiting."
  exit 0
end
case platform
when 'Flutter'
  pubspec_location = get_pubspec_location
  full_version = get_flutter_version(pubspec_location)
  puts "Flutter Version: #{full_version.blue}"
  raise 'Wrong version! Add a version to your pubspec.yaml (example: 1.0.0+1)' unless full_version.include?('+')

  splitted_version = full_version.split('+')
  version_name = splitted_version[0]
  version_code = splitted_version[1]
  puts "Current Version Name: #{version_name.blue}"
  puts "Current Version Code: #{version_code.blue}"
  if !is_integer?(version_code) || version_code.to_i > 2_100_000_000
    puts 'versionCode is not integer or bigger than 2100000000. This is not supported.'.red
    exit 0
  end
  source_version_code = version_code
  source_version_name = version_name
  source_version_code = env_has_key('AC_ANDROID_BUILD_NUMBER') if build_number_source == 'env'
  puts "Source Version Code: #{source_version_code.blue}"
  source_version_name = env_has_key('AC_ANDROID_VERSION_NUMBER') if version_number_source == 'env'
  puts "Source Version Name: #{source_version_name.blue}"
  new_version_code = calculate_build_number(source_version_code, build_offset)
  puts "New Version Code: #{new_version_code.blue}"
  new_version_name = calculate_version_number(source_version_name, version_strategy, omit_zero, version_offset)
  puts "New Version Name: #{new_version_name.blue}"
  new_full_version = "#{new_version_name}+#{new_version_code}"
  puts "New Flutter Version: #{new_full_version.blue}"
  set_new_env_values(new_version_code, new_version_name)
  set_flutter_version(pubspec_location, new_full_version)
  exit 0
when 'JavaKotlin', 'ReactNative'
  gradlew_path = get_gradle_path
  puts "Gradle Path: #{gradlew_path.blue}"
  flavor = get_env('AC_VERSION_FLAVOR')

  source_version_code = env_has_key('AC_ANDROID_BUILD_NUMBER') if build_number_source == 'env'
  source_version_name = env_has_key('AC_ANDROID_VERSION_NUMBER') if version_number_source == 'env'

  source_version_code = get_gradle_value(gradlew_path, 'versionCode', flavor) if build_number_source == 'gradle'
  if source_version_code
    puts "Current Version Code: #{source_version_code.blue}"
    is_version_code_int(source_version_code)
    new_version_code = calculate_build_number(source_version_code, build_offset)
    check_version_code(new_version_code)
    set_gradle_value(gradlew_path, 'versionCode', new_version_code, flavor)
    set_new_env_version_code(new_version_code)
  end
  
  source_version_name = get_gradle_value(gradlew_path, 'versionName', flavor) if version_number_source == 'gradle'
  if source_version_name
    puts "Current Version Name: #{source_version_name.blue}"
    check_version_name(source_version_name)
    new_version_name = calculate_version_number(source_version_name, version_strategy, omit_zero, version_offset)
    puts "New Version Name: #{new_version_name.blue}"
    check_version_name(new_version_name)
    set_gradle_value(gradlew_path, 'versionName', new_version_name, flavor)
    set_new_env_version_name(new_version_name)
  end
when 'Smartface'
  repository_path = env_has_key('AC_REPOSITORY_DIR')
  android_xml_path = File.join(repository_path, 'config', 'Android', 'AndroidManifest.xml')
  android_xml = load_xml(android_xml_path)

  version_code = android_xml.root.attribute('android:versionCode').value
  version_name = android_xml.root.attribute('android:versionName').value
  # load json file and get versıonCode and versionName
  json_path = File.join(repository_path, 'config', 'project.json')
  json = JSON.parse(File.read(json_path))
  smartface_version = json['info']['version']
  version_name = smartface_version if version_name == '${Version}'
  puts "Smartface Version from config: #{smartface_version}"
  puts "Current Version Code: #{version_code}"
  puts "Current Version Name: #{version_name}"

  source_version_code = version_code
  source_version_name = version_name
  source_version_code = env_has_key('AC_ANDROID_BUILD_NUMBER') if build_number_source == 'env'
  puts "Source Version Code: #{source_version_code.blue}"
  source_version_name = env_has_key('AC_ANDROID_VERSION_NUMBER') if version_number_source == 'env'
  puts "Source Version Name: #{source_version_name.blue}"
  new_version_code = calculate_build_number(source_version_code, build_offset)
  puts "New Version Code: #{new_version_code.blue}"
  new_version_name = calculate_version_number(source_version_name, version_strategy, omit_zero, version_offset)
  puts "New Version Name: #{new_version_name.blue}"
  android_xml.root.add_attribute('android:versionCode', new_version_code)
  android_xml.root.add_attribute('android:versionName', new_version_name)
  File.open(android_xml_path, 'w') { |f| f.write(android_xml) }
  set_new_env_values(new_version_code, new_version_name)

  exit 0
else
  puts 'Platform not supported'
  exit 1
end

end # if __FILE__ == $PROGRAM_NAME
