Pod::Spec.new do |s|
  s.name             = 'colyseus'
  s.version          = '0.18.0'
  s.summary          = 'Colyseus multiplayer client - native iOS library.'
  s.homepage         = 'https://colyseus.io'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Colyseus' => 'hello@colyseus.io' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '13.0'

  # Static libraries built by Zig. Device and simulator are both arm64, which
  # no single archive can hold, so they ship as an xcframework.
  s.vendored_frameworks = 'Frameworks/colyseus_flutter.xcframework'
  s.frameworks       = 'CoreFoundation', 'Security'

  # Tell CocoaPods this is a static framework
  s.static_framework = true

  # Dart looks the symbols up at runtime via DynamicLibrary.process(), so
  # nothing references them at link time and the linker would strip the
  # archive members. force_load keeps the whole library in the binary.
  #
  # This has to be user_target_xcconfig. The app is what links the library, and
  # a pod_target_xcconfig would land on the pod target, which vendors an
  # archive and never links anything, so the flag would be silently inert and
  # the app would build fine with none of the symbols in it.
  #
  # The path is the slice CocoaPods extracts for the platform being built, not
  # anything under the pod source; there is no one archive to point at.
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '-Wl,-force_load,$(PODS_XCFRAMEWORKS_BUILD_DIR)/colyseus/libcolyseus_flutter.a'
  }
end
