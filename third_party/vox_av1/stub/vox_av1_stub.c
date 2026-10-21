// Built when libaom isn't there (a local build without CI's aom-apple/): the
// pod still links, and lib/vox/av1_ffi.dart finds no vox_av1_encode, so the
// app says photos aren't in this build.
int vox_av1_stub_marker = 0;
