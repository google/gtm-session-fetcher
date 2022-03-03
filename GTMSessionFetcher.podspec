# This file specifies the Pod setup for GTMSessionFetcher. It enables developers
# to import GTMSessionFetcher via the CocoaPods dependency Manager.
Pod::Spec.new do |s|
  s.name        = 'GTMSessionFetcher'
  s.version     = '1.7.0'
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

  ios_deployment_target = '9.0'
  osx_deployment_target = '10.12'
  tvos_deployment_target = '10.0'
  watchos_deployment_target = '6.0'

  s.ios.deployment_target = ios_deployment_target
  s.osx.deployment_target = osx_deployment_target
  s.tvos.deployment_target = tvos_deployment_target
  s.watchos.deployment_target = watchos_deployment_target

  s.default_subspec = 'Full'

  s.subspec 'Core' do |sp|
    sp.source_files =
      'Source/GTMSessionFetcher.{h,m}',
      'Source/GTMSessionFetcherLogging.{h,m}',
      'Source/GTMSessionFetcherService.{h,m}',
      'Source/GTMSessionUploadFetcher.{h,m}'
    sp.framework = 'Security'
  end

  s.subspec 'Full' do |sp|
    sp.source_files =
        'Source/GTMGatherInputStream.{h,m}',
        'Source/GTMMIMEDocument.{h,m}',
        'Source/GTMReadMonitorInputStream.{h,m}'
    sp.dependency 'GTMSessionFetcher/Core', "#{s.version}"
  end

  s.subspec 'LogView' do |sp|
    # Only relevant for iOS, files compile away on others.
    sp.source_files =
      'Source/GTMSessionFetcherLogViewController.{h,m}'
    sp.dependency 'GTMSessionFetcher/Core', "#{s.version}"
  end

  s.test_spec 'Tests' do |sp|
    sp.source_files = 'UnitTests/*.{h,m}'
    sp.resource = 'UnitTests/Data/gettysburgaddress.txt'

    sp.platforms = {
      :ios => ios_deployment_target,
      :osx => osx_deployment_target,
      :tvos => tvos_deployment_target,
      # Seem to need a higher min to get a good test runner picked/supported.
      :watchos => '7.4'
    }
  end
end
