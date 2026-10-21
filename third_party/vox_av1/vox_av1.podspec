# AV1 still images for VOX photo messages on macOS (lib/vox/av1_ffi.dart
# finds vox_av1_encode/decode in the process). libaom is prebuilt by CI into
# aom-apple/ (universal arm64 + x86_64; see .github/workflows/build.yml).
# Without it, a stub builds instead and photos are reported as unavailable.
aom = File.join(__dir__, 'aom-apple', 'lib', 'libaom.a')
has_aom = File.exist?(aom)

Pod::Spec.new do |s|
  s.name             = 'vox_av1'
  s.version          = '1.0.0'
  s.summary          = 'AV1 still images (libaom) for MeshCore Open TAK photo messages'
  s.homepage         = 'https://aomedia.org'
  s.license          = { :type => 'BSD-2-Clause' }
  s.author           = { 'MeshCore Open TAK' => 'noreply@example.invalid' }
  s.source           = { :path => '.' }
  s.osx.deployment_target = '10.15'
  s.ios.deployment_target = '12.0'
  s.compiler_flags   = '-std=gnu11'
  if has_aom
    s.source_files        = 'vox_av1.c'
    s.vendored_libraries  = 'aom-apple/lib/libaom.a'
    s.preserve_paths      = 'aom-apple/**/*'
    s.pod_target_xcconfig = {
      'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/aom-apple/include"',
    }
  else
    s.source_files = 'stub/vox_av1_stub.c'
  end
  s.libraries = 'm'
end
