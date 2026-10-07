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
  # Only the library sources (same list as android/app/src/main/cpp/codec2_sources.cmake);
  # src/ also holds test programs and tools that must not be compiled.
  s.source_files     = 'src/{dump,lpc,nlp,postfilter,sine,codec2,codec2_fft,kiss_fft,kiss_fftr,interp,lsp,mbest,newamp1,phase,quantise,pack,codebook,codebookd,codebookjmv,codebookge,codebooknewamp1,codebooknewamp1_energy,codebooknewamp2,codebooknewamp2_energy}.c', 'src/*.h', 'include/**/*.h'
  s.public_header_files = 'src/codec2.h'
  s.preserve_paths   = 'include/**/*'
  s.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/src" "$(PODS_TARGET_SRCROOT)/include"',
  }
  s.compiler_flags   = '-std=gnu11'
  s.libraries        = 'm'
end
