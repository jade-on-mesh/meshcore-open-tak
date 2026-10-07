Pod::Spec.new do |s|
  s.name             = 'codec2'
  s.version          = '1.2.0'
  s.summary          = 'Codec2 voice codec'
  s.description      = 'Codec2 voice codec library (LGPL-2.1)'
  s.homepage         = 'https://www.rowetel.com/codec2.html'
  s.license          = { :type => 'LGPL-2.1', :file => 'COPYING' }
  s.author           = { 'David Rowe' => 'david@rowetel.com' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '12.0'
  s.source_files     = 'src/**/*.{c,h}'
  s.public_header_files = 'src/codec2.h'
  s.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/src" "$(PODS_TARGET_SRCROOT)/include"',
  }
  s.compiler_flags   = '-std=gnu11'
  s.libraries        = 'm'
end
