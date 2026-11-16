# AI sketch HD's codec for iPhone (lib/vox/aeic_hd_runner_io.dart finds
# aeic_hd_run in the process). CI builds it with tool/build_aeic_hd_ios.sh into
# ios/lib/libaeic_hd.a here; without it only stub/aeic_hd_pod.m builds and the
# app reports that AI sketch HD can't run on this device.
has_lib = File.exist?(File.join(__dir__, 'ios', 'lib', 'libaeic_hd.a'))

Pod::Spec.new do |s|
  s.name             = 'aeic_hd'
  s.version          = '1.0.0'
  s.summary          = 'AI sketch HD codec (mikecarper/AEIC on ncnn) for MeshCore Open TAK'
  s.homepage         = 'https://github.com/mikecarper/AEIC'
  s.license          = { :type => 'MIT' }
  s.author           = { 'MeshCore Open TAK' => 'noreply@example.invalid' }
  s.source           = { :path => '.' }
  s.ios.deployment_target = '12.0'
  s.preserve_paths   = 'ios/**/*', 'aeic_hd_ios.cpp'
  s.source_files     = 'stub/aeic_hd_pod.m'
  s.frameworks       = 'Foundation'
  if has_lib
    s.ios.vendored_libraries = 'ios/lib/libaeic_hd.a'
    s.libraries = 'c++', 'z'
  end
end
