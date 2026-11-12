#include "video_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "video_extract.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Result = flutter::MethodResult<EncodableValue>;

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;
HWND g_window = nullptr;
std::mutex g_mutex;
std::vector<std::pair<std::shared_ptr<Result>, VideoExtractResult>> g_done;

int IntArg(const EncodableMap& args, const char* key, int fallback) {
  auto it = args.find(EncodableValue(key));
  if (it == args.end()) return fallback;
  if (const auto* v = std::get_if<int32_t>(&it->second)) return *v;
  if (const auto* v = std::get_if<int64_t>(&it->second)) return (int)*v;
  return fallback;
}

}  // namespace

void RegisterVideoChannel(flutter::BinaryMessenger* messenger, HWND window) {
  g_window = window;
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "meshcore_open/vox_video", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler([](const flutter::MethodCall<EncodableValue>& call,
                                     std::unique_ptr<Result> result) {
    if (call.method_name() != "extract") {
      result->NotImplemented();
      return;
    }
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    std::string path;
    if (args) {
      auto it = args->find(EncodableValue("path"));
      if (it != args->end()) {
        if (const auto* s = std::get_if<std::string>(&it->second)) path = *s;
      }
    }
    if (path.empty()) {
      result->Error("extract", "no path");
      return;
    }
    const int max_side = IntArg(*args, "maxSide", 256);
    const int fps = IntArg(*args, "fps", 12);
    const int max_seconds = IntArg(*args, "maxSeconds", 15);
    std::shared_ptr<Result> shared(result.release());
    std::thread([shared, path, max_side, fps, max_seconds]() {
      VideoExtractResult r = ExtractVideo(path, max_side, fps, max_seconds);
      {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_done.emplace_back(shared, std::move(r));
      }
      if (g_window) PostMessage(g_window, kVideoChannelMessage, 0, 0);
    }).detach();
  });
}

bool HandleVideoChannelMessage(UINT message) {
  if (message != kVideoChannelMessage) return false;
  std::vector<std::pair<std::shared_ptr<Result>, VideoExtractResult>> done;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    done.swap(g_done);
  }
  for (auto& item : done) {
    const VideoExtractResult& r = item.second;
    if (!r.ok) {
      item.first->Error("extract", r.error);
      continue;
    }
    EncodableMap out{
        {EncodableValue("frames"), EncodableValue(r.frames_path)},
        {EncodableValue("width"), EncodableValue(r.width)},
        {EncodableValue("height"), EncodableValue(r.height)},
        {EncodableValue("fps"), EncodableValue(r.fps)},
        {EncodableValue("count"), EncodableValue(r.count)},
        {EncodableValue("durationMs"), EncodableValue(r.duration_ms)},
        {EncodableValue("sound"),
         r.sound_path.empty() ? EncodableValue() : EncodableValue(r.sound_path)},
        {EncodableValue("samples"), EncodableValue((int64_t)r.samples)},
    };
    item.first->Success(EncodableValue(out));
  }
  return true;
}

void UnregisterVideoChannel() {
  g_channel = nullptr;
  g_window = nullptr;
}
