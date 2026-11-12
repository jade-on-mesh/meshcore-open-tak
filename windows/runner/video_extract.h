// MeshCore Open TAK - reads a picked video for sending it as a video message
// (lib/vox/video_source.dart), with Media Foundation: small RGB888 frames at a
// fixed rate and 48 kHz mono PCM16 sound, each into a temporary file. The
// same contract as Android's VoxVideoChannel.kt and the iPhone/Mac
// MeshVideoReader. No Flutter types here, so it can be built and tested alone.

#ifndef RUNNER_VIDEO_EXTRACT_H_
#define RUNNER_VIDEO_EXTRACT_H_

#include <cstdint>
#include <string>

struct VideoExtractResult {
  bool ok = false;
  std::string error;          // why not, when !ok
  std::string frames_path;    // UTF-8: count frames of width*height*3 bytes, RGB
  int width = 0;
  int height = 0;
  int fps = 0;
  int count = 0;
  int duration_ms = 0;
  std::string sound_path;     // UTF-8, empty when there is no sound
  int64_t samples = 0;        // 48 kHz mono PCM16 LE samples in sound_path
};

// path: the video (UTF-8). At most max_side px on the longer side, fps frames
// a second, the first max_seconds. Call on a thread of its own: it initialises
// COM (multithreaded) and Media Foundation for itself.
VideoExtractResult ExtractVideo(const std::string& path, int max_side, int fps,
                                int max_seconds);

#endif  // RUNNER_VIDEO_EXTRACT_H_
