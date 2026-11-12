// Checks windows/runner/video_extract.cpp on real clips (CI:
// .github/workflows/windows-video.yml).
//
//   video_extract_test CLIP WANT_PORTRAIT(0|1) WANT_SOUND(0|1)
//
// The clip must give frames (with picture in them, not black), the upright
// shape, and sound when it has some.

#include <cstdio>
#include <string>
#include <vector>

#include "../../windows/runner/video_extract.h"

int main(int argc, char** argv) {
  if (argc != 4) {
    std::fprintf(stderr, "usage: video_extract_test CLIP WANT_PORTRAIT WANT_SOUND\n");
    return 2;
  }
  const bool want_portrait = argv[2][0] == '1';
  const bool want_sound = argv[3][0] == '1';
  const VideoExtractResult r = ExtractVideo(argv[1], 256, 8, 6);
  if (!r.ok) {
    std::printf("FAIL %s: %s\n", argv[1], r.error.c_str());
    return 1;
  }
  std::printf("%s: %dx%d, %d frames at %d fps, %d ms, %lld samples\n", argv[1], r.width,
              r.height, r.count, r.fps, r.duration_ms, (long long)r.samples);
  int failures = 0;
  auto check = [&](bool ok, const char* what) {
    if (!ok) {
      std::printf("FAIL %s: %s\n", argv[1], what);
      ++failures;
    }
  };
  check(r.count >= 8, "fewer frames than a second's worth");
  check(r.width > 0 && r.height > 0 && r.width <= 256 && r.height <= 256, "picture size");
  check(want_portrait ? r.height > r.width : r.width > r.height, "upright shape");
  check(want_sound == (r.samples > 48000 / 2), "sound");

  FILE* f = nullptr;
  if (fopen_s(&f, r.frames_path.c_str(), "rb") != 0) f = nullptr;
  check(f != nullptr, "frames file");
  if (f) {
    const size_t frame = (size_t)r.width * r.height * 3;
    std::vector<unsigned char> buf(frame);
    size_t frames = 0;
    unsigned long long sum = 0;
    while (std::fread(buf.data(), 1, frame, f) == frame) {
      for (unsigned char v : buf) sum += v;
      ++frames;
    }
    std::fclose(f);
    check(frames == (size_t)r.count, "frames file length");
    const double mean = frames ? (double)sum / (double)(frames * frame) : 0;
    std::printf("  mean level %.1f\n", mean);
    check(mean > 20, "frames are black");
  }
  return failures ? 1 : 0;
}
