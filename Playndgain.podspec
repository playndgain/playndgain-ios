Pod::Spec.new do |s|
  s.name             = 'Playndgain'
  s.version          = '1.0.0'
  s.summary          = 'Native offerwall for iOS apps.'
  s.homepage         = 'https://playndgain.com/docs/mobile-sdk'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'Playndgain' => 'support@playndgain.com' }
  # The owner fills this in when the repository is published.
  s.source           = { :git => '', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.9'
  s.source_files     = 'Sources/Playndgain/**/*.swift'
  s.resource_bundles = { 'Playndgain' => ['Sources/Playndgain/Resources/*'] }
  s.frameworks       = 'UIKit', 'CoreText', 'WebKit'
end
