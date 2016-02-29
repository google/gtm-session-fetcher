# This file specifies the Pod setup for GTMSessionFetcher. It enables developers 
# to import GTMSessionFetcher via the CocoaPods dependency Manager.
Pod::Spec.new do |s|
  s.name        = 'GTMSessionFetcher'
  s.version     = '1.1.0'
  s.authors     = 'Google Toolbox for Mac - Session Fetcher Controllers'
  s.license     = { :type => 'Apache', :file => 'LICENSE' }
  s.homepage    = 'https://github.com/google/gtm-session-fetcher'
  s.source      = { :git => 'https://github.com/google/gtm-session-fetcher.git',
                     :tag => 'v#{s.version}' }
  s.summary     = 'Google Toolbox for Mac - Session Fetcher.'
  s.description = <<-DESC

  GTMSessionFetcher makes it easy for Cocoa applications 
  to perform http operations. The fetcher is implemented 
  as a wrapper on NSURLSession, so its behavior is asynchronous 
  and uses operating-system settings on iOS and Mac OS X.

  DESC

  s.source_files = 'Source/*.{h,m}'
  s.frameworks   = 'Security'
  
  s.ios.deployment_target = '7.0'
  s.ios.framework = 'UIKit'

  s.osx.deployment_target = '10.8'
  s.osx.exclude_files = 'Source/GTMSessionFetcherLogViewController.{h,m}'
  s.osx.framework = 'Cocoa'
end
