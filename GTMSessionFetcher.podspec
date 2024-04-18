# This file specifies the Pod setup for GTMSessionFetcher. It enables developers
# to import GTMSessionFetcher via the CocoaPods dependency Manager.
Pod::Spec.new do |s|
  s.name        = 'GTMSessionFetcher'
  s.version     = '3.4.1'
  s.authors     = 'Google Inc.'
  s.license     = { :type => 'Apache', :file => 'LICENSE' }
  s.homepage    = 'https://github.com/google/gtm-session-fetcher'
  s.source      = { :git => 'https://github.com/google/gtm-session-fetcher.git',
                    :tag => "v#{s.version}" }
  s.summary     = 'Google Toolbox for Mac - Session Fetcher'
  s.description = <<-DESC

  GTMSessionFetcher makes it easy for Cocoa applications
  to perform http operations. The fetcher is implemented
  as a wrapper on NSURLSession, so its behavior is asynchronous
  and uses operating-system settings.
  DESC

  # Ensure developers won't hit CocoaPods/CocoaPods#11402 with the resource
  # bundle for the privacy manifest.
  s.cocoapods_version = '>= 1.12.0'

  ios_deployment_target = '10.0'
  osx_deployment_target = '10.12'
  tvos_deployment_target = '10.0'
  visionos_deployment_target = '1.0'
  watchos_deployment_target = '6.0'

  s.ios.deployment_target = ios_deployment_target
  s.osx.deployment_target = osx_deployment_target
  s.tvos.deployment_target = tvos_deployment_target
  s.visionos.deployment_target = visionos_deployment_target
  s.watchos.deployment_target = watchos_deployment_target

  s.prefix_header_file = false

  s.default_subspec = 'Full'

  s.xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  s.subspec 'Core' do |sp|
    sp.source_files = 'Sources/Core/**/*.{h,m}'
    sp.public_header_files = 'Sources/Core/Public/GTMSessionFetcher/*.h'
    sp.framework = 'Security'
    sp.resource_bundle = {
      "GTMSessionFetcher_Core_Privacy" => "Sources/Core/Resources/PrivacyInfo.xcprivacy"
    }
  end

  s.subspec 'Full' do |sp|
    sp.source_files = 'Sources/Full/**/*.{h,m}'
    sp.public_header_files = 'Sources/Full/Public/GTMSessionFetcher/*.h'
    sp.dependency 'GTMSessionFetcher/Core'
    sp.resource_bundle = {
      "GTMSessionFetcher_Full_Privacy" => "Sources/Full/Resources/PrivacyInfo.xcprivacy"
    }
  end

  s.subspec 'LogView' do |sp|
    # Only relevant for iOS, files compile away on others.
    sp.source_files = 'Sources/LogView/**/*.{h,m}'
    sp.public_header_files = 'Sources/LogView/Public/GTMSessionFetcher/*.h'
    sp.dependency 'GTMSessionFetcher/Core'
    sp.resource_bundle = {
      "GTMSessionFetcher_LogView_Privacy" => "Sources/LogView/Resources/PrivacyInfo.xcprivacy"
    }
  end

  s.test_spec 'Tests' do |sp|
    sp.source_files = 'UnitTests/*.{h,m}'

    sp.platforms = {
      :ios => ios_deployment_target,
      :osx => osx_deployment_target,
      :tvos => tvos_deployment_target,
      :visionos => visionos_deployment_target,
      # Seem to need a higher min to get a good test runner picked/supported.
      :watchos => '7.4'
    }
  end
end
