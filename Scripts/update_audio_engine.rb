#!/usr/bin/env ruby
# Update audio_engine file reference from .cpp to .mm

require 'xcodeproj'

project_path = File.expand_path('../SAYses.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

# Find the old file reference and remove it
project.files.each do |file|
  if file.path && file.path.include?('audio_engine.cpp')
    puts "Removing old reference: #{file.path}"
    file.remove_from_project
  end
end

# Find the target
target = project.targets.find { |t| t.name == 'SAYses' }

# Find the audio group
main_group = project.main_group
sayses_group = main_group.find_subpath('SAYses', false)
core_group = sayses_group.find_subpath('Core', false)
audio_group = core_group.find_subpath('audio', false) if core_group

# Add the new .mm file
new_file_path = File.expand_path('../Core/src/audio/audio_engine.mm', __dir__)
if audio_group
  file_ref = audio_group.new_file(new_file_path)
  target.add_file_references([file_ref])
  puts "Added: #{new_file_path}"
end

project.save
puts "Project saved!"
