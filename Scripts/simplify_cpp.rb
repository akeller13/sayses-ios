#!/usr/bin/env ruby
# Remove mumble C++ files that require protobuf, keep only audio/codec

require 'xcodeproj'

project_path = File.expand_path('../SAYses.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'SAYses' }

# Files to remove (require protobuf)
files_to_remove = [
  'mumble_client.cpp',
  'crypto.cpp',
  'udp_ping.cpp',
  'Mumble.pb.cc',
  'Mumble.pb.h',
  'MumbleClientBridge.mm',
  'MumbleClientBridge.h'
]

# Remove from project
project.files.each do |file|
  next unless file.path

  if files_to_remove.any? { |f| file.path.include?(f) }
    puts "Removing: #{file.path}"

    # Remove from target's build phases
    target.source_build_phase.files.each do |build_file|
      if build_file.file_ref == file
        build_file.remove_from_project
      end
    end

    file.remove_from_project
  end
end

project.save
puts "Project simplified!"
