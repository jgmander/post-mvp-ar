#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#
Pod::Spec.new do |s|
  s.name             = 'arcore_flutter_plugin'
  s.version          = '0.0.1'
  s.summary          = 'ARCore Flutter Plugin with Geospatial API support.'
  s.description      = <<-DESC
Flutter plugin providing ARCore Geospatial API support on iOS via GARSession.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.dependency 'ARCore/Geospatial', '~> 1.48.0'

  s.ios.deployment_target = '15.0'
  s.frameworks = 'ARKit', 'SceneKit', 'CoreLocation'
  s.pod_target_xcconfig = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64' }
end
