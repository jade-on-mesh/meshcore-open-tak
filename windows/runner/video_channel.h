// MeshCore Open TAK - "meshcore_open/vox_video" on Windows: "extract"
// {path, maxSide, fps, maxSeconds} -> {frames, width, height, fps, count,
// durationMs, sound, samples} (lib/vox/video_source.dart), read on a worker
// thread with video_extract.h and answered back on the platform thread.

#ifndef RUNNER_VIDEO_CHANNEL_H_
#define RUNNER_VIDEO_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

// The window message that carries a finished extract back to the platform
// thread; FlutterWindow::MessageHandler passes it to HandleVideoChannelMessage.
constexpr UINT kVideoChannelMessage = WM_APP + 0x3A1;

void RegisterVideoChannel(flutter::BinaryMessenger* messenger, HWND window);

// Answers the extracts that have finished. True if `message` was ours.
bool HandleVideoChannelMessage(UINT message);

void UnregisterVideoChannel();

#endif  // RUNNER_VIDEO_CHANNEL_H_
