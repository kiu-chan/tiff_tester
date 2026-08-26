part of '../tiff_viewer_page.dart';

/// How many real-world units one image pixel represents, derived from
/// whichever the file provides: GeoTIFF's ModelPixelScale (georeferenced
/// rasters) or the baseline XResolution/YResolution/ResolutionUnit tags
/// (282/283/296). Falls back to plain pixels when neither is present or
/// ResolutionUnit says "no absolute unit" (value 1).
class _PixelScale {
  final double unitsPerPixelX;
  final double unitsPerPixelY;
  final String unitLabel;

  const _PixelScale({required this.unitsPerPixelX, required this.unitsPerPixelY, required this.unitLabel});

  static const pixelsOnly = _PixelScale(unitsPerPixelX: 1, unitsPerPixelY: 1, unitLabel: 'px');

  factory _PixelScale.from(TiffImageMetadata metadata) {
    final pixelScale = metadata.geoTiff?.modelPixelScale;
    if (pixelScale != null && pixelScale.length >= 2 && pixelScale[0] > 0 && pixelScale[1] > 0) {
      final unitCode = metadata.geoTiff!.geoKeys[GeoTiffKeyId.projLinearUnits] ?? metadata.geoTiff!.geoKeys[GeoTiffKeyId.geogAngularUnits];
      return _PixelScale(unitsPerPixelX: pixelScale[0], unitsPerPixelY: pixelScale[1], unitLabel: _geoUnitName(unitCode));
    }

    final xRes = metadata.rawTags[TiffTagId.xResolution]?.asDouble();
    final yRes = metadata.rawTags[TiffTagId.yResolution]?.asDouble();
    final resUnit = metadata.rawTags[TiffTagId.resolutionUnit]?.asInt() ?? 2;
    if (xRes != null && xRes > 0 && resUnit != 1) {
      final label = resUnit == 3 ? 'cm' : 'in';
      return _PixelScale(unitsPerPixelX: 1 / xRes, unitsPerPixelY: (yRes != null && yRes > 0) ? 1 / yRes : 1 / xRes, unitLabel: label);
    }

    return pixelsOnly;
  }

  bool get isPhysical => unitLabel != 'px';

  static String _geoUnitName(Object? code) {
    final intCode = (code is num) ? code.toInt() : null;
    return switch (intCode) {
      9001 => 'm',
      9002 => 'ft',
      9003 => 'ft (US)',
      9036 => 'km',
      9102 => '°',
      null => 'map units',
      _ => 'units($intCode)',
    };
  }
}
