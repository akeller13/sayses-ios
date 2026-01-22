#!/usr/bin/env ruby
# Add generated protobuf files to Xcode project

require 'xcodeproj'

project_path = File.expand_path('../SAYses.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'SAYses' }

# Find or create the generated group
main_group = project.main_group
sayses_group = main_group.find_subpath('SAYses', false)
core_group = sayses_group.find_subpath('Core', false) || sayses_group.new_group('Core', 'Core')
generated_group = core_group.find_subpath('generated', false) || core_group.new_group('generated', '../Core/src/generated')

# Add generated files
['Mumble.pb.cc', 'Mumble.pb.h'].each do |filename|
  file_path = File.expand_path("../Core/src/generated/#{filename}", __dir__)
  next if generated_group.files.any? { |f| f.path && f.path.include?(filename) }

  file_ref = generated_group.new_file(file_path)
  if filename.end_with?('.cc')
    target.add_file_references([file_ref])
  end
  puts "Added: #{filename}"
end

# Update header search paths
target.build_configurations.each do |config|
  paths = config.build_settings['HEADER_SEARCH_PATHS'] || ['$(inherited)']
  paths = [paths] if paths.is_a?(String)

  new_path = '"$(SRCROOT)/Core/src/generated"'
  unless paths.include?(new_path)
    paths << new_path
    config.build_settings['HEADER_SEARCH_PATHS'] = paths
    puts "Updated header search path for #{config.name}"
  end
end

project.save
puts "Project saved!"
