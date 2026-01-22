#!/usr/bin/env ruby
# Script to add C++ files to SAYses Xcode project

require 'xcodeproj'

project_path = File.expand_path('../SAYses.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

# Find the main target
target = project.targets.find { |t| t.name == 'SAYses' }
raise "Target 'SAYses' not found" unless target

# Find or create the Core group
main_group = project.main_group
sayses_group = main_group.find_subpath('SAYses', false)

# Create Core group under SAYses if it doesn't exist
core_group = sayses_group.find_subpath('Core', false)
if core_group.nil?
  core_group = sayses_group.new_group('Core', 'Core')
end

# Create subgroups
include_group = core_group.find_subpath('include', false) || core_group.new_group('include', '../Core/include')
audio_group = core_group.find_subpath('audio', false) || core_group.new_group('audio', '../Core/src/audio')
codec_group = core_group.find_subpath('codec', false) || core_group.new_group('codec', '../Core/src/codec')
mumble_group = core_group.find_subpath('mumble', false) || core_group.new_group('mumble', '../Core/src/mumble')

# Find or create Bridges group
bridges_group = sayses_group.find_subpath('Bridges', false)
if bridges_group.nil?
  bridges_group = sayses_group.new_group('Bridges', 'Bridges')
end

# Helper to add file if not already present
def add_file_to_group(group, file_path, target, compile: true)
  return if group.files.any? { |f| f.path == File.basename(file_path) }

  file_ref = group.new_file(file_path)
  if compile && (file_path.end_with?('.cpp') || file_path.end_with?('.mm') || file_path.end_with?('.m'))
    target.add_file_references([file_ref])
  end
  puts "Added: #{file_path}"
end

# Add header files (don't compile)
Dir.glob(File.expand_path('../Core/include/*.h', __dir__)).each do |path|
  add_file_to_group(include_group, path, target, compile: false)
end

# Add audio source files
Dir.glob(File.expand_path('../Core/src/audio/*.cpp', __dir__)).each do |path|
  add_file_to_group(audio_group, path, target)
end

# Add codec source files
Dir.glob(File.expand_path('../Core/src/codec/*.cpp', __dir__)).each do |path|
  add_file_to_group(codec_group, path, target)
end

# Add mumble source files
Dir.glob(File.expand_path('../Core/src/mumble/*.cpp', __dir__)).each do |path|
  add_file_to_group(mumble_group, path, target)
end

# Add bridge files
Dir.glob(File.expand_path('../SAYses/Bridges/*.{h,mm}', __dir__)).each do |path|
  compile = path.end_with?('.mm')
  add_file_to_group(bridges_group, path, target, compile: compile)
end

# Update build settings
target.build_configurations.each do |config|
  settings = config.build_settings

  # C++ standard
  settings['CLANG_CXX_LANGUAGE_STANDARD'] = 'c++17'
  settings['CLANG_CXX_LIBRARY'] = 'libc++'

  # Header search paths
  existing_paths = settings['HEADER_SEARCH_PATHS'] || ['$(inherited)']
  existing_paths = [existing_paths] if existing_paths.is_a?(String)

  new_paths = [
    '"$(SRCROOT)/Core/include"',
    '"$(SRCROOT)/Pods/libopus/include"',
    '"$(SRCROOT)/Pods/Speex-iOS/Libs/libspeex/include"',
    '"$(SRCROOT)/Pods/Protobuf/src"',
    '"$(SRCROOT)/Pods/OpenSSL-Universal/include"'
  ]

  new_paths.each do |path|
    existing_paths << path unless existing_paths.include?(path)
  end

  settings['HEADER_SEARCH_PATHS'] = existing_paths

  # Bridging header
  settings['SWIFT_OBJC_BRIDGING_HEADER'] = 'SAYses/Bridges/SAYses-Bridging-Header.h'

  # Enable Objective-C++ for .mm files
  settings['GCC_INPUT_FILETYPE'] = 'automatic'

  puts "Updated build settings for #{config.name}"
end

project.save
puts "Project saved successfully!"
