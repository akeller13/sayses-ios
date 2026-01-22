# Podfile for SAYses iOS
# Third-party dependencies for audio processing

platform :ios, '17.0'

target 'SAYses' do
  use_frameworks!

  # Opus audio codec (48kHz, 64kbps for voice)
  pod 'libopus', '~> 1.1'

  # Speex for audio preprocessing (includes SpeexDSP)
  pod 'Speex-iOS', '~> 0.2.0'

end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
      # Disable bitcode
      config.build_settings['ENABLE_BITCODE'] = 'NO'
      # Suppress warnings in pods
      config.build_settings['GCC_WARN_INHIBIT_ALL_WARNINGS'] = 'YES'
      # Allow non-modular includes
      config.build_settings['CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES'] = 'YES'
    end
  end
end
