Pod::Spec.new do |s|
  s.name             = 'ggwave'
  s.version          = '0.4.2'
  s.summary          = 'Data over sound'
  s.description      = 'ggwave: tiny data-over-sound library (MIT). Used for share by sound.'
  s.homepage         = 'https://github.com/ggerganov/ggwave'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Georgi Gerganov' => 'ggerganov@gmail.com' }
  s.source           = { :path => '.' }
  s.ios.deployment_target = '12.0'
  s.osx.deployment_target = '10.15'
  s.source_files     = 'src/ggwave.cpp', 'src/fft.h', 'src/reed-solomon/*.hpp', 'include/ggwave/ggwave.h'
  s.public_header_files = 'include/ggwave/ggwave.h'
  s.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/include" "$(PODS_TARGET_SRCROOT)/src"',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'GCC_PREPROCESSOR_DEFINITIONS' => 'GGWAVE_SHARED=1 GGWAVE_BUILD=1',
  }
  s.libraries        = 'c++'
end
