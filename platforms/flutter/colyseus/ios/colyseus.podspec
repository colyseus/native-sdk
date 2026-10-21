Pod::Spec.new do |s|
  s.name             = 'colyseus'
  s.version          = '0.18.0'
  s.summary          = 'Colyseus multiplayer client - native iOS library.'
  s.homepage         = 'https://colyseus.io'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Colyseus' => 'hello@colyseus.io' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '13.0'

  # A dynamic framework the app embeds, which Dart opens by name. Linked
  # statically, nothing references the library at link time, so release
  # builds strip every symbol Dart looks up (issue #35).
  s.vendored_frameworks = 'Frameworks/colyseus_flutter.xcframework'
end
