// MeshCore Open TAK - coordinate formats: decimal degrees, degrees-minutes-
// seconds and MGRS (WGS84, UTM zones 80°S-84°N), with parsing for Go To.

import 'dart:math';

enum CoordFormat {
  decimal('Decimal'),
  dms('DMS'),
  mgrs('MGRS');

  const CoordFormat(this.label);
  final String label;

  CoordFormat get next => values[(index + 1) % values.length];

  static CoordFormat fromIndex(int i) =>
      i >= 0 && i < values.length ? values[i] : decimal;
}

const double _a = 6378137.0;
const double _f = 1 / 298.257223563;
const double _k0 = 0.9996;
final double _e2 = _f * (2 - _f);
final double _ep2 = _e2 / (1 - _e2);

/// UTM position.
class Utm {
  final int zone;
  final bool north;
  final double easting, northing;
  const Utm(this.zone, this.north, this.easting, this.northing);
}

int _utmZone(double lat, double lon) {
  var z = ((lon + 180) / 6).floor() + 1;
  if (z > 60) z = 60;
  // Norway and Svalbard exceptions.
  if (lat >= 56 && lat < 64 && lon >= 3 && lon < 12) z = 32;
  if (lat >= 72 && lat < 84) {
    if (lon >= 0 && lon < 9) {
      z = 31;
    } else if (lon >= 9 && lon < 21) {
      z = 33;
    } else if (lon >= 21 && lon < 33) {
      z = 35;
    } else if (lon >= 33 && lon < 42) {
      z = 37;
    }
  }
  return z;
}

double _meridianArc(double phi) {
  final e4 = _e2 * _e2, e6 = e4 * _e2;
  return _a *
      ((1 - _e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * phi -
          (3 * _e2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * sin(2 * phi) +
          (15 * e4 / 256 + 45 * e6 / 1024) * sin(4 * phi) -
          (35 * e6 / 3072) * sin(6 * phi));
}

/// Lat/lon to UTM in [zone] (default: the standard zone for the point).
Utm toUtm(double lat, double lon, {int? zone}) {
  final z = zone ?? _utmZone(lat, lon);
  final lon0 = ((z - 1) * 6 - 180 + 3) * pi / 180;
  final phi = lat * pi / 180, lam = lon * pi / 180;
  final s = sin(phi), c = cos(phi), t = tan(phi);
  final n = _a / sqrt(1 - _e2 * s * s);
  final tt = t * t;
  final cc = _ep2 * c * c;
  final aa = c * (lam - lon0);
  final m = _meridianArc(phi);
  final x =
      _k0 *
          n *
          (aa +
              (1 - tt + cc) * pow(aa, 3) / 6 +
              (5 - 18 * tt + tt * tt + 72 * cc - 58 * _ep2) *
                  pow(aa, 5) /
                  120) +
      500000;
  var y =
      _k0 *
      (m +
          n *
              t *
              (aa * aa / 2 +
                  (5 - tt + 9 * cc + 4 * cc * cc) * pow(aa, 4) / 24 +
                  (61 - 58 * tt + tt * tt + 600 * cc - 330 * _ep2) *
                      pow(aa, 6) /
                      720));
  if (lat < 0) y += 10000000;
  return Utm(z, lat >= 0, x, y);
}

/// UTM to (lat, lon).
(double, double) fromUtm(Utm u) {
  final x = u.easting - 500000;
  final y = u.north ? u.northing : u.northing - 10000000;
  final lon0 = ((u.zone - 1) * 6 - 180 + 3) * pi / 180;
  final e4 = _e2 * _e2, e6 = e4 * _e2;
  final m = y / _k0;
  final mu = m / (_a * (1 - _e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256));
  final e1 = (1 - sqrt(1 - _e2)) / (1 + sqrt(1 - _e2));
  final phi1 =
      mu +
      (3 * e1 / 2 - 27 * pow(e1, 3) / 32) * sin(2 * mu) +
      (21 * e1 * e1 / 16 - 55 * pow(e1, 4) / 32) * sin(4 * mu) +
      (151 * pow(e1, 3) / 96) * sin(6 * mu) +
      (1097 * pow(e1, 4) / 512) * sin(8 * mu);
  final s = sin(phi1), c = cos(phi1), t = tan(phi1);
  final n1 = _a / sqrt(1 - _e2 * s * s);
  final t1 = t * t;
  final c1 = _ep2 * c * c;
  final r1 = _a * (1 - _e2) / pow(1 - _e2 * s * s, 1.5);
  final d = x / (n1 * _k0);
  final lat =
      phi1 -
      (n1 * t / r1) *
          (d * d / 2 -
              (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * _ep2) * pow(d, 4) / 24 +
              (61 +
                      90 * t1 +
                      298 * c1 +
                      45 * t1 * t1 -
                      252 * _ep2 -
                      3 * c1 * c1) *
                  pow(d, 6) /
                  720);
  final lon =
      lon0 +
      (d -
              (1 + 2 * t1 + c1) * pow(d, 3) / 6 +
              (5 - 2 * c1 + 28 * t1 - 3 * c1 * c1 + 8 * _ep2 + 24 * t1 * t1) *
                  pow(d, 5) /
                  120) /
          c;
  return (lat * 180 / pi, lon * 180 / pi);
}

const String _bands = 'CDEFGHJKLMNPQRSTUVWX';
const List<String> _colSets = ['ABCDEFGH', 'JKLMNPQR', 'STUVWXYZ'];
const String _rows = 'ABCDEFGHJKLMNPQRSTUV';

String? _band(double lat) {
  if (lat < -80 || lat > 84) return null;
  final i = ((lat + 80) / 8).floor().clamp(0, _bands.length - 1);
  return _bands[i];
}

/// MGRS with 1 m precision, e.g. "18S UJ 23487 06483". Null near the poles
/// (UPS is not supported).
String? toMgrs(double lat, double lon, {int digits = 5}) {
  final band = _band(lat);
  if (band == null) return null;
  final u = toUtm(lat, lon);
  final col = _colSets[(u.zone - 1) % 3];
  final colIdx = (u.easting / 100000).floor() - 1;
  if (colIdx < 0 || colIdx >= col.length) return null;
  final rowOffset = u.zone.isEven ? 5 : 0;
  final rowIdx = ((u.northing / 100000).floor() + rowOffset) % 20;
  final scale = pow(10, 5 - digits).toInt();
  final e = ((u.easting % 100000) / scale).floor();
  final n = ((u.northing % 100000) / scale).floor();
  return '${u.zone}$band ${col[colIdx]}${_rows[rowIdx]} '
      '${e.toString().padLeft(digits, '0')} '
      '${n.toString().padLeft(digits, '0')}';
}

final RegExp _mgrsRe = RegExp(
  r'^(\d{1,2})\s*([C-HJ-NP-X])\s*([A-HJ-NP-Z])\s*([A-HJ-NP-V])\s*(\d*)\s*(\d*)$',
  caseSensitive: false,
);

/// Parses MGRS ("18SUJ2348706483", "18S UJ 23487 06483", "10T DT 4 7").
(double, double)? parseMgrs(String input) {
  final m = _mgrsRe.firstMatch(input.trim().toUpperCase());
  if (m == null) return null;
  final zone = int.parse(m.group(1)!);
  if (zone < 1 || zone > 60) return null;
  final band = m.group(2)!;
  final colL = m.group(3)!, rowL = m.group(4)!;
  var digits = '${m.group(5)}${m.group(6)}';
  if (m.group(6)!.isEmpty) digits = m.group(5)!;
  if (digits.length.isOdd || digits.length > 10) return null;
  final half = digits.length ~/ 2;
  final scale = pow(10, 5 - half).toDouble();
  final e = half == 0 ? 0.0 : int.parse(digits.substring(0, half)) * scale;
  final n = half == 0 ? 0.0 : int.parse(digits.substring(half)) * scale;
  final colIdx = _colSets[(zone - 1) % 3].indexOf(colL);
  if (colIdx < 0) return null;
  final rowOffset = zone.isEven ? 5 : 0;
  final rowIdx = (_rows.indexOf(rowL) - rowOffset + 20) % 20;
  if (!_rows.contains(rowL)) return null;
  final easting = (colIdx + 1) * 100000 + e;
  var northing = rowIdx * 100000 + n;
  // Find the 2,000 km cycle that lands inside the latitude band.
  final bandIdx = _bands.indexOf(band);
  final bandLat = -80.0 + bandIdx * 8;
  final north = bandLat >= 0;
  final lon0 = (zone - 1) * 6 - 180 + 3.0;
  final minN = toUtm(bandLat, lon0, zone: zone).northing;
  northing += (minN / 2000000).floor() * 2000000;
  if (northing < minN - 50000) northing += 2000000;
  final (lat, lon) = fromUtm(Utm(zone, north, easting, northing));
  // Use the cell centre when the precision is coarse.
  if (half < 5) {
    final c = fromUtm(
      Utm(zone, north, easting + scale / 2, northing + scale / 2),
    );
    return c;
  }
  return (lat, lon);
}

String _dms(double v, String pos, String neg) {
  final h = v >= 0 ? pos : neg;
  var a = v.abs();
  var d = a.floor();
  a = (a - d) * 60;
  var m = a.floor();
  var s = ((a - m) * 60 * 10).round() / 10;
  if (s >= 60) {
    s = 0;
    m++;
  }
  if (m >= 60) {
    m = 0;
    d++;
  }
  return "$d°${m.toString().padLeft(2, '0')}'"
      '${s.toStringAsFixed(1).padLeft(4, '0')}"$h';
}

/// Formats a position.
String teamFormatCoord(double lat, double lon, CoordFormat f) => switch (f) {
  CoordFormat.decimal => '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}',
  CoordFormat.dms => '${_dms(lat, 'N', 'S')} ${_dms(lon, 'E', 'W')}',
  CoordFormat.mgrs =>
    toMgrs(lat, lon) ?? '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}',
};

final RegExp _decRe = RegExp(
  r'^\s*([-+]?\d{1,3}(?:\.\d+)?)\s*[°]?\s*([NS])?\s*[,;\s]\s*([-+]?\d{1,3}(?:\.\d+)?)\s*[°]?\s*([EW])?\s*$',
  caseSensitive: false,
);

final RegExp _dmsPart = RegExp(
  r'''(\d{1,3})\s*[°d\s]\s*(\d{1,2})\s*['m\s]\s*(\d{1,2}(?:\.\d+)?)\s*(?:["s]|'')?\s*([NSEW])''',
  caseSensitive: false,
);

/// Parses decimal degrees ("47.6, -122.3", "47.6N 122.3W"), DMS
/// ("47°36'22"N 122°19'55"W") or MGRS. Null if it can't be read.
(double, double)? parseTeamCoord(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;
  final mg = parseMgrs(s);
  if (mg != null) return mg;
  final d = _decRe.firstMatch(s);
  if (d != null) {
    var lat = double.parse(d.group(1)!);
    var lon = double.parse(d.group(3)!);
    if ((d.group(2) ?? '').toUpperCase() == 'S') lat = -lat.abs();
    if ((d.group(4) ?? '').toUpperCase() == 'W') lon = -lon.abs();
    if (lat.abs() <= 90 && lon.abs() <= 180) return (lat, lon);
    return null;
  }
  final parts = _dmsPart.allMatches(s).toList();
  if (parts.length == 2) {
    double? lat, lon;
    for (final p in parts) {
      final v =
          int.parse(p.group(1)!) +
          int.parse(p.group(2)!) / 60 +
          double.parse(p.group(3)!) / 3600;
      switch (p.group(4)!.toUpperCase()) {
        case 'N':
          lat = v;
        case 'S':
          lat = -v;
        case 'E':
          lon = v;
        case 'W':
          lon = -v;
      }
    }
    if (lat != null && lon != null && lat.abs() <= 90 && lon.abs() <= 180) {
      return (lat, lon);
    }
  }
  return null;
}
