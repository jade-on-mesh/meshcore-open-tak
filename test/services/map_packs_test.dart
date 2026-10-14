import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshcore_open/services/map_packs.dart';

void main() {
  test('MBTiles rows count from the south', () {
    expect(mbtilesRow(0, 0), 0);
    expect(mbtilesRow(1, 0), 1);
    expect(mbtilesRow(10, 357), 1023 - 357);
  });

  test('bounds metadata is left,bottom,right,top', () {
    final b = parseMbtilesBounds('-122.8,45.3,-122.4,45.7');
    expect(b!.$1, const LatLng(45.3, -122.8));
    expect(b.$2, const LatLng(45.7, -122.4));
    expect(parseMbtilesBounds('nope'), isNull);
    expect(parseMbtilesBounds(null), isNull);
  });

  test('a pack covers its zooms and area only', () {
    const p = MapPackInfo(
      id: 'pdx.mbtiles',
      name: 'Portland',
      format: 'png',
      minZoom: 8,
      maxZoom: 14,
      sw: LatLng(45.3, -122.8),
      ne: LatLng(45.7, -122.4),
      bytes: 1,
    );
    // Portland at z12 is around x=650, y=1464.
    final n = 1 << 12;
    final x = mapPackTileX(-122.6, n), y = mapPackTileY(45.5, n);
    expect(p.covers(12, x, y), isTrue);
    expect(p.covers(15, x * 8, y * 8), isFalse); // past maxzoom
    expect(p.covers(12, x + 40, y), isFalse); // east of the pack
    expect(p.center!.latitude, closeTo(45.5, 1e-9));
  });
}
