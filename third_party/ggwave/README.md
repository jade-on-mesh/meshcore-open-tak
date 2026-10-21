# ggwave (vendored)

Data over sound by Georgi Gerganov, MIT licence (LICENSE; the bundled
Reed-Solomon code is MIT too, src/reed-solomon/LICENSE). From
https://github.com/ggerganov/ggwave at 060aec7: only the library
(src/ggwave.cpp, src/fft.h, src/reed-solomon/, include/ggwave/ggwave.h).

Used by lib/sound/ (share by sound, Wavest-compatible messages). Built as
libggwave on Android (android/app/src/main/cpp), a pod on iOS/macOS
(ggwave.podspec) and a DLL/.so in the desktop CI builds.
