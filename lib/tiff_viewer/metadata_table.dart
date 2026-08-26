part of '../tiff_viewer_page.dart';

class _MetadataTable extends StatelessWidget {
  final TiffImageMetadata metadata;
  const _MetadataTable({required this.metadata});

  @override
  Widget build(BuildContext context) {
    final scale = _PixelScale.from(metadata);
    final rows = <(String, String)>[
      ('Dimensions', '${metadata.width} x ${metadata.height}'),
      ('Samples/pixel', '${metadata.samplesPerPixel}'),
      ('Bits/sample', '${metadata.bitsPerSample}'),
      ('Compression', '${metadata.compression} (${_compressionName(metadata.compression)})'),
      ('Photometric', metadata.photometric?.name ?? '(missing)'),
      ('Predictor', '${metadata.predictor}'),
      ('Layout', metadata.isTiled ? 'tiled (${metadata.tileWidth}x${metadata.tileLength})' : 'strips (${metadata.rowsPerStrip} rows/strip)'),
      (
        'Physical scale',
        scale.isPhysical ? '${scale.unitsPerPixelX} x ${scale.unitsPerPixelY} ${scale.unitLabel}/px' : '(none — pixels only)',
      ),
      if (metadata.colorMap != null) ('ColorMap', '${metadata.colorMap!.length} entries'),
      if (metadata.geoTiff != null) ('GeoTIFF', 'present (${metadata.geoTiff!.geoKeys.length} GeoKeys)'),
      if (metadata.exifTags != null) ('EXIF', '${metadata.exifTags!.length} tags'),
      if (metadata.gpsTags != null) ('GPS', '${metadata.gpsTags!.length} tags'),
    ];
    return Table(
      columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
      children: [
        for (final (label, value) in rows)
          TableRow(
            children: [
              Padding(padding: const EdgeInsets.only(right: 12, bottom: 4), child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
              Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(value)),
            ],
          ),
      ],
    );
  }

  static String _compressionName(int code) => switch (code) {
    1 => 'None',
    2 => 'CCITT Group 3 1D',
    3 => 'CCITT Group 3 2D',
    4 => 'CCITT Group 4',
    5 => 'LZW',
    6 => 'Old JPEG',
    7 => 'JPEG',
    8 => 'Deflate/ZIP',
    32773 => 'PackBits',
    32946 => 'Deflate/ZIP (Adobe)',
    _ => 'unknown',
  };
}
