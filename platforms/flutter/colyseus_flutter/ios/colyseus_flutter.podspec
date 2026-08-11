Pod::Spec.new do |s|
  s.name             = 'colyseus_flutter'
  s.version          = '0.17.0'
  s.summary          = 'Colyseus multiplayer client - native iOS library.'
  s.homepage         = 'https://colyseus.io'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Colyseus' => 'hello@colyseus.io' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '13.0'

  # Static library built by Zig
  s.vendored_libraries = 'Libraries/libcolyseus_flutter.a'
  s.frameworks       = 'CoreFoundation', 'Security'

  # Tell CocoaPods this is a static framework
  s.static_framework = true
end
