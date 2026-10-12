// MeshCore Open TAK - ATAK data packages (mission packages): a zip with
// MANIFEST/manifest.xml and one CoT file per item. Export the team's map for
// ATAK/WinTAK/iTAK; import packages made there.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'cot.dart';

/// Builds a data package from (uid, CoT XML) items.
Uint8List buildTakDataPackage({
  required String packageUid,
  required String name,
  required List<(String, String)> items,
}) {
  final archive = Archive();
  final b = XmlBuilder();
  b.element(
    'MissionPackageManifest',
    attributes: {'version': '2'},
    nest: () {
      b.element(
        'Configuration',
        nest: () {
          b.element(
            'Parameter',
            attributes: {'name': 'uid', 'value': packageUid},
          );
          b.element('Parameter', attributes: {'name': 'name', 'value': name});
        },
      );
      b.element(
        'Contents',
        nest: () {
          for (final (uid, _) in items) {
            b.element(
              'Content',
              attributes: {'ignore': 'false', 'zipEntry': '$uid/$uid.cot'},
              nest: () => b.element(
                'Parameter',
                attributes: {'name': 'uid', 'value': uid},
              ),
            );
          }
        },
      );
    },
  );
  void add(String path, String text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  add('MANIFEST/manifest.xml', b.buildDocument().toXmlString(pretty: true));
  for (final (uid, xml) in items) {
    add('$uid/$uid.cot', xml);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// What a data package holds.
class TakPackageContents {
  /// It carries a server connection (.pref): use TakService.importDataPackage.
  final bool isConnection;
  final List<CotEvent> events;
  final String? name;
  const TakPackageContents({
    required this.isConnection,
    required this.events,
    this.name,
  });
}

/// Reads a data package zip.
TakPackageContents readTakDataPackage(Uint8List zip) {
  final archive = ZipDecoder().decodeBytes(zip);
  var connection = false;
  String? name;
  final events = <CotEvent>[];
  for (final f in archive.files) {
    if (!f.isFile) continue;
    final lower = f.name.toLowerCase();
    if (lower.endsWith('.pref')) connection = true;
    final text = utf8.decode(f.content, allowMalformed: true);
    if (lower.endsWith('manifest.xml')) {
      try {
        final doc = XmlDocument.parse(text);
        for (final p in doc.findAllElements('Parameter')) {
          if (p.getAttribute('name') == 'name') name = p.getAttribute('value');
        }
      } catch (_) {}
      continue;
    }
    if (lower.endsWith('.cot') || lower.endsWith('.xml')) {
      final e = parseCot(text.trim());
      if (e != null) events.add(e);
    }
  }
  return TakPackageContents(
    isConnection: connection,
    events: events,
    name: name,
  );
}
