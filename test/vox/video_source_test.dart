import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/vox/video_source.dart';

void main() {
  group('ffmpegOutputSize', () {
    test('reads the raw video size from the Output #0 section', () {
      const log = '''
Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'clip.mp4':
  Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(progressive), 1280x720 [SAR 1:1 DAR 16:9], 30 fps
Output #0, rawvideo, to 'frames.rgb':
  Metadata:
    encoder         : Lavf60.16.100
  Stream #0:0(und): Video: rawvideo (RGB[24] / 0x18424752), rgb24(pc, gbr/unknown/unknown, progressive), 256x144 [SAR 1:1 DAR 16:9], q=2-31, 10616 kb/s, 12 fps, 12 tbn (default)
''';
      expect(ffmpegOutputSize(log), (256, 144));
    });

    test('a portrait clip ffmpeg turned upright', () {
      const log =
          'Output #0, rawvideo, to \'f.rgb\':\n'
          '  Stream #0:0: Video: rawvideo (RGB[24] / 0x18424752), rgb24, 144x256, q=2-31\n';
      expect(ffmpegOutputSize(log), (144, 256));
    });

    test('nothing without an output section', () {
      expect(ffmpegOutputSize('clip.mp4: Invalid data found'), isNull);
    });
  });
}
