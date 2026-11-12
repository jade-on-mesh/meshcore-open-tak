// MeshCore Open TAK - video_extract.h with Media Foundation's Source Reader.
//
// Frames: decoded and converted to RGB32 by the Source Reader (its video
// processing), cropped to the display aperture, turned upright by the
// stream's rotation, then shrunk with a box filter to at most max_side px and
// sampled at a fixed rate (each output frame is the newest decoded frame at
// or before its time). Sound: decoded to float, mixed to mono and resampled
// to 48 kHz here. The decoders are Windows' own (H.264 and AAC always; HEVC
// with the HEVC extension installed).

#include "video_extract.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")

namespace {

template <typename T>
class Com {
 public:
  Com() = default;
  ~Com() { reset(); }
  Com(const Com&) = delete;
  Com& operator=(const Com&) = delete;
  T* get() const { return p_; }
  T* operator->() const { return p_; }
  T** put() {
    reset();
    return &p_;
  }
  void reset() {
    if (p_) p_->Release();
    p_ = nullptr;
  }
  explicit operator bool() const { return p_ != nullptr; }

 private:
  T* p_ = nullptr;
};

std::wstring Widen(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], n);
  return w;
}

std::string Narrow(const std::wstring& w) {
  if (w.empty()) return std::string();
  const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
  std::string s(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), &s[0], n, nullptr, nullptr);
  return s;
}

std::wstring TempFile(const wchar_t* name) {
  wchar_t dir[MAX_PATH + 1] = {0};
  const DWORD n = GetTempPathW(MAX_PATH, dir);
  std::wstring path = n ? std::wstring(dir, n) : std::wstring(L".\\");
  return path + name;
}

// _wfopen without MSVC's deprecation warning (the build treats warnings as
// errors).
FILE* OpenForWriting(const std::wstring& path) {
  FILE* file = nullptr;
  if (_wfopen_s(&file, path.c_str(), L"wb") != 0) return nullptr;
  return file;
}

int Even(double v) { return std::max(2, (int)std::lround(v / 2) * 2); }

// An upright, cropped picture in RGB, shrunk to w x h with a box filter.
// src: top row first, pitch bytes between rows, BGRX pixels.
void Shrink(const BYTE* src, LONG pitch, int crop_x, int crop_y, int crop_w, int crop_h,
            int rotation, int w, int h, std::vector<uint8_t>& out) {
  out.assign((size_t)w * h * 3, 0);
  // Upright size of the cropped picture.
  const bool sideways = rotation == 90 || rotation == 270;
  const int uw = sideways ? crop_h : crop_w;
  const int uh = sideways ? crop_w : crop_h;
  for (int oy = 0; oy < h; ++oy) {
    const int y0 = (int)((int64_t)oy * uh / h);
    const int y1 = std::max(y0 + 1, (int)((int64_t)(oy + 1) * uh / h));
    for (int ox = 0; ox < w; ++ox) {
      const int x0 = (int)((int64_t)ox * uw / w);
      const int x1 = std::max(x0 + 1, (int)((int64_t)(ox + 1) * uw / w));
      // Visit at most 4 x 4 samples of the box: plenty for a 256 px picture.
      const int sx = std::max(1, (x1 - x0) / 4), sy = std::max(1, (y1 - y0) / 4);
      uint32_t r = 0, g = 0, b = 0, n = 0;
      for (int uy = y0; uy < y1; uy += sy) {
        for (int ux = x0; ux < x1; ux += sx) {
          // Upright (ux, uy) back to the stored frame. The stream's rotation
          // R is how far the content was turned counter-clockwise; showing it
          // upright turns it R clockwise.
          int fx, fy;
          switch (rotation) {
            case 90: fx = uy; fy = crop_h - 1 - ux; break;
            case 180: fx = crop_w - 1 - ux; fy = crop_h - 1 - uy; break;
            case 270: fx = crop_w - 1 - uy; fy = ux; break;
            default: fx = ux; fy = uy; break;
          }
          const BYTE* p = src + (LONG)(crop_y + fy) * pitch + (crop_x + fx) * 4;
          b += p[0];
          g += p[1];
          r += p[2];
          ++n;
        }
      }
      uint8_t* o = &out[((size_t)oy * w + ox) * 3];
      o[0] = (uint8_t)(r / n);
      o[1] = (uint8_t)(g / n);
      o[2] = (uint8_t)(b / n);
    }
  }
}

struct Session {
  HRESULT com = E_FAIL;
  HRESULT mf = E_FAIL;
  Session() {
    com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    mf = MFStartup(MF_VERSION);
  }
  ~Session() {
    if (SUCCEEDED(mf)) MFShutdown();
    if (SUCCEEDED(com)) CoUninitialize();
  }
};

VideoExtractResult Fail(const char* why) {
  VideoExtractResult r;
  r.error = why;
  return r;
}

// The first clip_ms of the first audio stream as 48 kHz mono PCM16 in a
// file; false when there is none (or it can't be decoded).
bool ReadSound(IMFSourceReader* reader, int clip_ms, std::wstring& path, int64_t& samples) {
  const DWORD stream = (DWORD)MF_SOURCE_READER_FIRST_AUDIO_STREAM;
  reader->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
  if (FAILED(reader->SetStreamSelection(stream, TRUE))) return false;
  Com<IMFMediaType> want;
  if (FAILED(MFCreateMediaType(want.put()))) return false;
  want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  want->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
  if (FAILED(reader->SetCurrentMediaType(stream, nullptr, want.get()))) return false;
  Com<IMFMediaType> got;
  if (FAILED(reader->GetCurrentMediaType(stream, got.put()))) return false;
  const UINT32 channels = MFGetAttributeUINT32(got.get(), MF_MT_AUDIO_NUM_CHANNELS, 0);
  const UINT32 rate = MFGetAttributeUINT32(got.get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 0);
  if (!channels || !rate) return false;
  PROPVARIANT start;
  PropVariantInit(&start);
  start.vt = VT_I8;
  start.hVal.QuadPart = 0;
  reader->SetCurrentPosition(GUID_NULL, start);

  const int64_t limit_in = (int64_t)rate * clip_ms / 1000;
  std::vector<float> mono;
  mono.reserve((size_t)std::min<int64_t>(limit_in, 48000 * 60));
  for (;;) {
    DWORD flags = 0;
    LONGLONG at = 0;
    Com<IMFSample> sample;
    if (FAILED(reader->ReadSample(stream, 0, nullptr, &flags, &at, sample.put()))) break;
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    if (!sample) continue;
    Com<IMFMediaBuffer> buffer;
    if (FAILED(sample->ConvertToContiguousBuffer(buffer.put()))) break;
    BYTE* data = nullptr;
    DWORD len = 0;
    if (FAILED(buffer->Lock(&data, nullptr, &len))) break;
    const float* f = reinterpret_cast<const float*>(data);
    const size_t frames = len / (sizeof(float) * channels);
    for (size_t i = 0; i < frames && (int64_t)mono.size() < limit_in; ++i) {
      float sum = 0;
      for (UINT32 c = 0; c < channels; ++c) sum += f[i * channels + c];
      mono.push_back(sum / (float)channels);
    }
    buffer->Unlock();
    if ((int64_t)mono.size() >= limit_in) break;
  }
  if (mono.size() < 2) return false;

  // Linear resampling to 48 kHz.
  const int64_t out_n = (int64_t)((double)mono.size() * 48000.0 / rate);
  std::vector<int16_t> pcm((size_t)std::max<int64_t>(0, out_n));
  for (int64_t i = 0; i < out_n; ++i) {
    const double pos = (double)i * rate / 48000.0;
    const size_t a = (size_t)pos;
    const size_t b = std::min(a + 1, mono.size() - 1);
    const double t = pos - (double)a;
    double v = mono[std::min(a, mono.size() - 1)] * (1 - t) + mono[b] * t;
    v = std::max(-1.0, std::min(1.0, v));
    pcm[(size_t)i] = (int16_t)std::lround(v * 32767.0);
  }
  if (pcm.empty()) return false;
  path = TempFile(L"vox_video_sound.pcm");
  FILE* file = OpenForWriting(path);
  if (!file) return false;
  const size_t wrote = fwrite(pcm.data(), sizeof(int16_t), pcm.size(), file);
  fclose(file);
  if (wrote != pcm.size()) return false;
  samples = (int64_t)pcm.size();
  return true;
}

}  // namespace

VideoExtractResult ExtractVideo(const std::string& utf8_path, int max_side, int fps,
                                int max_seconds) {
  if (fps < 1) fps = 1;
  if (max_side < 2) max_side = 2;
  Session session;
  if (FAILED(session.mf)) return Fail("Media Foundation isn't available");

  Com<IMFAttributes> attributes;
  if (FAILED(MFCreateAttributes(attributes.put(), 1))) return Fail("not a video");
  attributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
  Com<IMFSourceReader> reader;
  const std::wstring path = Widen(utf8_path);
  if (FAILED(MFCreateSourceReaderFromURL(path.c_str(), attributes.get(), reader.put())))
    return Fail("not a video");

  // Length.
  PROPVARIANT duration;
  PropVariantInit(&duration);
  int64_t length_100ns = 0;
  if (SUCCEEDED(reader->GetPresentationAttribute((DWORD)MF_SOURCE_READER_MEDIASOURCE,
                                                 MF_PD_DURATION, &duration)) &&
      duration.vt == VT_UI8) {
    length_100ns = (int64_t)duration.uhVal.QuadPart;
  }
  PropVariantClear(&duration);
  if (length_100ns <= 0) return Fail("not a video");
  const int clip_ms = (int)std::min<int64_t>(length_100ns / 10000, (int64_t)max_seconds * 1000);
  const int count = std::max(1, clip_ms * fps / 1000);

  // Video: RGB32 out of the Source Reader's converter.
  const DWORD video = (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM;
  reader->SetStreamSelection((DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
  if (FAILED(reader->SetStreamSelection(video, TRUE))) return Fail("no picture track in this video");
  UINT32 rotation = 0;
  {
    Com<IMFMediaType> native;
    if (SUCCEEDED(reader->GetNativeMediaType(video, 0, native.put())))
      rotation = MFGetAttributeUINT32(native.get(), MF_MT_VIDEO_ROTATION, 0);
  }
  if (rotation != 90 && rotation != 180 && rotation != 270) rotation = 0;
  {
    Com<IMFMediaType> want;
    if (FAILED(MFCreateMediaType(want.put()))) return Fail("not a video");
    want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    want->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    if (FAILED(reader->SetCurrentMediaType(video, nullptr, want.get())))
      return Fail("Windows can't decode this video's format");
  }
  // The decoded frame's layout. Windows' decoders often settle it only with
  // the first frame (1080p H.264 decodes as 1920 x 1088, say), reporting a
  // media type change then, so it is read again whenever that happens.
  UINT32 frame_w = 0, frame_h = 0;
  LONG default_stride = 0;
  int crop_x = 0, crop_y = 0, crop_w = 0, crop_h = 0;
  auto read_layout = [&]() -> bool {
    Com<IMFMediaType> current;
    if (FAILED(reader->GetCurrentMediaType(video, current.put()))) return false;
    frame_w = frame_h = 0;
    MFGetAttributeSize(current.get(), MF_MT_FRAME_SIZE, &frame_w, &frame_h);
    if (!frame_w || !frame_h) return false;
    default_stride = (LONG)MFGetAttributeUINT32(current.get(), MF_MT_DEFAULT_STRIDE, 0);
    if (default_stride == 0) default_stride = (LONG)frame_w * 4;
    crop_x = 0;
    crop_y = 0;
    crop_w = (int)frame_w;
    crop_h = (int)frame_h;
    for (const GUID& key : {MF_MT_MINIMUM_DISPLAY_APERTURE, MF_MT_GEOMETRIC_APERTURE}) {
      MFVideoArea area;
      UINT32 size = 0;
      if (SUCCEEDED(current->GetBlob(key, reinterpret_cast<UINT8*>(&area), sizeof(area), &size)) &&
          size == sizeof(area) && area.Area.cx > 0 && area.Area.cy > 0) {
        crop_x = std::max(0, (int)area.OffsetX.value);
        crop_y = std::max(0, (int)area.OffsetY.value);
        crop_w = std::max(1, std::min((int)area.Area.cx, (int)frame_w - crop_x));
        crop_h = std::max(1, std::min((int)area.Area.cy, (int)frame_h - crop_y));
        break;
      }
    }
    return true;
  };
  if (!read_layout()) return Fail("this video's picture size isn't known");

  // The shape as shown: cropped, then turned. Worked out again if the layout
  // changes before the first frame is kept.
  int w = 2, h = 2;
  auto size_output = [&]() {
    const bool sideways = rotation == 90 || rotation == 270;
    const double shown_w = sideways ? crop_h : crop_w;
    const double shown_h = sideways ? crop_w : crop_h;
    const double aspect = shown_w / std::max(shown_h, 1.0);
    if (aspect >= 1) {
      w = Even(max_side);
      h = Even(max_side / aspect);
    } else {
      w = Even(max_side * aspect);
      h = Even(max_side);
    }
  };
  size_output();

  const std::wstring frames_path = TempFile(L"vox_video_frames.rgb");
  FILE* frames_file = OpenForWriting(frames_path);
  if (!frames_file) return Fail("couldn't write a temporary file");

  std::vector<uint8_t> last((size_t)w * h * 3, 0), next;
  bool have_last = false, any = false;
  int written = 0;
  bool ended = false;
  HRESULT read_error = S_OK;
  int64_t frame_100ns = (int64_t)10000000 / fps;
  while (written < count && !ended) {
    DWORD flags = 0;
    LONGLONG at = 0;
    Com<IMFSample> sample;
    const HRESULT hr = reader->ReadSample(video, 0, nullptr, &flags, &at, sample.put());
    if (FAILED(hr)) {
      read_error = hr;
      break;
    }
    if (flags & MF_SOURCE_READERF_ERROR) {
      read_error = E_FAIL;
      break;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) ended = true;
    if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
      // The sample that comes with it is already in the new layout.
      if (!read_layout()) break;
      if (!any) {
        size_output();
        last.assign((size_t)w * h * 3, 0);
      }
    }
    if (sample && !ended) {
      // Every output frame due before this one shows the previous frame.
      while (written < count && have_last && (int64_t)written * frame_100ns < at) {
        fwrite(last.data(), 1, last.size(), frames_file);
        ++written;
      }
      Com<IMFMediaBuffer> buffer;
      if (FAILED(sample->ConvertToContiguousBuffer(buffer.put()))) continue;
      BYTE* data = nullptr;
      DWORD len = 0;
      bool done = false;
      Com<IMF2DBuffer> two_d;
      if (SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(two_d.put())))) {
        BYTE* scan0 = nullptr;
        LONG pitch = 0;
        if (SUCCEEDED(two_d->Lock2D(&scan0, &pitch))) {
          Shrink(scan0, pitch, crop_x, crop_y, crop_w, crop_h, (int)rotation, w, h, next);
          two_d->Unlock2D();
          done = true;
        }
      }
      if (!done && SUCCEEDED(buffer->Lock(&data, nullptr, &len))) {
        const LONG abs_stride = default_stride < 0 ? -default_stride : default_stride;
        if ((DWORD)abs_stride * frame_h <= len && abs_stride >= (LONG)frame_w * 4) {
          // A negative stride is a bottom-up picture: start at its last row.
          const BYTE* top = default_stride < 0 ? data + (size_t)abs_stride * (frame_h - 1) : data;
          Shrink(top, default_stride, crop_x, crop_y, crop_w, crop_h, (int)rotation, w, h, next);
          done = true;
        }
        buffer->Unlock();
      }
      if (done) {
        last.swap(next);
        have_last = true;
        any = true;
      }
    }
  }
  // The rest of the clip holds the last picture.
  while (any && written < count) {
    fwrite(last.data(), 1, last.size(), frames_file);
    ++written;
  }
  fclose(frames_file);
  if (!any) {
    _wremove(frames_path.c_str());
    if (FAILED(read_error)) {
      char why[96];
      snprintf(why, sizeof(why), "Windows couldn't decode this video's pictures (0x%08lX)",
               (unsigned long)read_error);
      return Fail(why);
    }
    return Fail("no pictures decoded from this video");
  }

  VideoExtractResult result;
  result.ok = true;
  result.frames_path = Narrow(frames_path);
  result.width = w;
  result.height = h;
  result.fps = fps;
  result.count = written;
  result.duration_ms = clip_ms;
  std::wstring sound_path;
  int64_t samples = 0;
  if (ReadSound(reader.get(), clip_ms, sound_path, samples)) {
    result.sound_path = Narrow(sound_path);
    result.samples = samples;
  }
  return result;
}
