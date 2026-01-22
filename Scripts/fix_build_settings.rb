#!/usr/bin/env ruby
# Fix build settings for C++ compilation

require 'xcodeproj'

project_path = File.expand_path('../SAYses.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'SAYses' }
raise "Target 'SAYses' not found" unless target

target.build_configurations.each do |config|
  settings = config.build_settings

  # Header search paths - include all necessary pod headers
  settings['HEADER_SEARCH_PATHS'] = [
    '$(inherited)',
    '"$(SRCROOT)/Core/include"',
    '"$(PODS_ROOT)/libopus/include"',
    '"$(PODS_ROOT)/Speex-iOS/Speex-iOS/speex/Libs/libspeex"',
    '"$(PODS_ROOT)/Speex-iOS/Speex-iOS/speex/Libs/libspeex/speex"',
    '"$(PODS_ROOT)/Protobuf/objectivec"',
    '"$(PODS_ROOT)/OpenSSL-Universal/ios/include"'
  ]

  # Library search paths
  settings['LIBRARY_SEARCH_PATHS'] = [
    '$(inherited)',
    '"$(PODS_ROOT)/libopus/lib"',
    '"$(PODS_ROOT)/OpenSSL-Universal/ios/lib"'
  ]

  # C++ settings
  settings['CLANG_CXX_LANGUAGE_STANDARD'] = 'c++17'
  settings['CLANG_CXX_LIBRARY'] = 'libc++'
  settings['GCC_ENABLE_CPP_EXCEPTIONS'] = 'YES'
  settings['GCC_ENABLE_CPP_RTTI'] = 'YES'

  # Bridging header
  settings['SWIFT_OBJC_BRIDGING_HEADER'] = 'SAYses/Bridges/SAYses-Bridging-Header.h'

  # Allow non-modular includes for Objective-C++
  settings['CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES'] = 'YES'

  puts "Updated #{config.name} build settings"
end

project.save
puts "Project saved!"
