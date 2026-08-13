Pod::Spec.new do |s|
  s.name             = 'colyseus_flutter'
  s.version          = '0.18.0'
  s.summary          = 'Colyseus multiplayer client - native macOS library.'
  s.homepage         = 'https://colyseus.io'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Colyseus' => 'hello@colyseus.io' }
  s.source           = { :path => '.' }
  s.platform         = :osx, '10.15'

  # Dynamic library built by Zig
  s.vendored_libraries = 'Libraries/libcolyseus_flutter.dylib'
  s.frameworks       = 'CoreFoundation', 'Security'
end
