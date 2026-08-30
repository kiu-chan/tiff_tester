part of '../tiff_viewer_page.dart';

/// One resolution rung of a page pyramid, largest (most detailed) first —
/// see [_buildPyramidLevels]. [tileWidth]/[tileLength] default to the
/// whole level's dimensions when the underlying page isn't itself tiled,
/// so callers can always treat a level as "decode by tile" without a
/// separate strip-layout code path.
class _PyramidLevel {
  final TiffImage image;
  final int width;
  final int height;
  final int tileWidth;
  final int tileLength;
  final bool isTiled;

  const _PyramidLevel({
    required this.image,
    required this.width,
    required this.height,
    required this.tileWidth,
    required this.tileLength,
    required this.isTiled,
  });
}

/// Builds the whole pyramid ladder (largest/native first) for a page: a
/// multi-page file is often a resolution *pyramid* (e.g. whole-slide-image
/// scanners like Philips's), where later pages are pre-downsampled versions
/// of page 0 — sometimes by a huge factor (seen in practice: a
/// 131072x100352 base page next to a 4096x3584 one). [_TileEngine] needs
/// every rung so it can switch between them as the user zooms in and out.
///
/// A multi-page TIFF can also carry unrelated extra images (label/macro
/// shots, fixed-size thumbnails) that aren't pyramid levels of page 0 at
/// all, so a page only counts as a candidate if its aspect ratio is close
/// to page 0's — full pyramid levels match closely; unrelated images
/// generally don't.
///
/// [extraLevelsDocument], if given, is a separate, already-opened document
/// (see [_PyramidCache]) whose pages are folded in as additional candidate
/// rungs alongside [document]'s own — used when [document] itself has no
/// native pyramid but a sidecar [_PyramidCache] built one instead. Both
/// isolates that call this (the main isolate opening the preview, and each
/// [_TileEngine] worker via [_tileWorkerEntry]) must be given the same
/// [extraLevelsDocument] (or lack of one) so every isolate computes the
/// exact same level list/order — [_TileEngine] indexes rungs positionally.
List<_PyramidLevel> _buildPyramidLevels(TiffDocument document, {TiffDocument? extraLevelsDocument}) {
  final images = [...document.images, ...?extraLevelsDocument?.images];
  final baseAspect = images.first.metadata.width / images.first.metadata.height;
  final levels = <_PyramidLevel>[];
  for (final img in images) {
    final m = img.metadata;
    final aspect = m.width / m.height;
    if ((aspect - baseAspect).abs() / baseAspect > 0.2) continue;
    levels.add(
      _PyramidLevel(
        image: img,
        width: m.width,
        height: m.height,
        tileWidth: m.isTiled ? m.tileWidth! : m.width,
        tileLength: m.isTiled ? m.tileLength! : m.height,
        isTiled: m.isTiled,
      ),
    );
  }
  levels.sort((a, b) => b.width.compareTo(a.width));
  return levels;
}

/// Raw per-pixel memory a decode band actually costs while it's alive: the
/// underlying `TiffRasterBuffer.samples` — a typed-data list picked by bit
/// depth (`Uint8List`/`Uint16List`/`Uint32List`; see package:tiff's
/// `allocateSampleBuffer`), not a flat 8-bytes-per-sample `List<int>` the
/// way it once was — plus the RGBA8 conversion of that same band (4
/// bytes/pixel), which is briefly alive alongside it. Mirrors package:tiff's
/// own `TiffChunkPlan`'s identical per-sample bucketing.
int _bandBytesPerPixel(TiffImageMetadata metadata) {
  final maxBits = metadata.bitsPerSample.isEmpty ? 8 : metadata.bitsPerSample.reduce(math.max);
  final bytesPerSample = maxBits <= 8 ? 1 : (maxBits <= 16 ? 2 : 4);
  return metadata.samplesPerPixel * bytesPerSample + 4;
}

int _tileGridArea(TiffImageMetadata m) {
  final tw = m.tileWidth!;
  final tl = m.tileLength!;
  return ((m.width + tw - 1) ~/ tw) * ((m.height + tl - 1) ~/ tl);
}

/// Decodes [page] to RGBA8, downsampling to at most [_maxPreviewDim] on
/// the longest side. For an oversized image this never holds more than
/// one horizontal band (capped at [_maxBandBytes], sized using the raw
/// decode buffer's real per-pixel cost — see [_bandBytesPerPixel]) plus
/// the (much smaller) output buffer at once — never the full-resolution
/// image. A tiled page with an impractical number of tiles (no smaller
/// pyramid rung to fall back on) instead goes through [_decodeSparsePreview].
/// [onProgress], if given, is called with a fraction from 0 to 1 as each
/// band/tile completes.
(Uint8List, int, int) _decodePreviewRgba(TiffImage page, {void Function(double)? onProgress}) {
  final metadata = page.metadata;
  final srcWidth = metadata.width;
  final srcHeight = metadata.height;
  final longest = math.max(srcWidth, srcHeight);
  if (longest <= _maxPreviewDim) {
    onProgress?.call(0);
    final rgba = page.decodeRegionRgba8(TiffRegion.fullImage(metadata));
    onProgress?.call(1);
    return (rgba, srcWidth, srcHeight);
  }

  if (metadata.isTiled && _tileGridArea(metadata) > _sparseSamplingTileThreshold) {
    return _decodeSparsePreview(page, onProgress: onProgress);
  }

  final scale = _maxPreviewDim / longest;
  final outWidth = (srcWidth * scale).round().clamp(1, srcWidth);
  final outHeight = (srcHeight * scale).round().clamp(1, srcHeight);
  final output = Uint8List(outWidth * outHeight * 4);

  final bytesPerPixel = _bandBytesPerPixel(metadata);
  final bandHeight = math.max(1, _maxBandBytes() ~/ (srcWidth * bytesPerPixel));
  for (var bandStart = 0; bandStart < srcHeight; bandStart += bandHeight) {
    final bh = math.min(bandHeight, srcHeight - bandStart);
    final band = page.decodeRegionRgba8(TiffRegion(x: 0, y: bandStart, width: srcWidth, height: bh));
    for (var oy = 0; oy < outHeight; oy++) {
      final srcY = (oy / scale).floor();
      if (srcY < bandStart || srcY >= bandStart + bh) continue;
      final bandRowBase = (srcY - bandStart) * srcWidth * 4;
      final outRowBase = oy * outWidth * 4;
      for (var ox = 0; ox < outWidth; ox++) {
        final s = bandRowBase + (ox / scale).floor() * 4;
        final d = outRowBase + ox * 4;
        output[d] = band[s];
        output[d + 1] = band[s + 1];
        output[d + 2] = band[s + 2];
        output[d + 3] = band[s + 3];
      }
    }
    onProgress?.call((bandStart + bh) / srcHeight);
  }
  return (output, outWidth, outHeight);
}

/// A cheap, approximate overview for a huge tiled page that has no smaller
/// pyramid level to fall back on: decoding every tile just to build a small
/// preview would mean decompressing the whole multi-gigapixel image, tile
/// by tile, compression block by compression block (a tile can't be
/// partially decoded). Instead this decodes only a sparse, evenly-spaced
/// sample of tiles across the grid and stretches each one across the block
/// of output pixels it stands in for — a blocky, approximate stand-in that
/// appears almost instantly. Exact detail then fills in per-viewport as the
/// user zooms in (see [_TileEngine]), so the approximation only has to hold
/// up at a glance, not under close inspection.
(Uint8List, int, int) _decodeSparsePreview(TiffImage page, {void Function(double)? onProgress}) {
  const sampleTarget = 24;
  final m = page.metadata;
  final tileWidth = m.tileWidth!;
  final tileLength = m.tileLength!;
  final tileCols = (m.width + tileWidth - 1) ~/ tileWidth;
  final tileRows = (m.height + tileLength - 1) ~/ tileLength;

  final scale = _maxPreviewDim / math.max(m.width, m.height);
  final outWidth = (m.width * scale).round().clamp(1, m.width);
  final outHeight = (m.height * scale).round().clamp(1, m.height);
  final output = Uint8List(outWidth * outHeight * 4);

  final sampleCols = math.min(tileCols, sampleTarget);
  final sampleRows = math.min(tileRows, sampleTarget);

  for (var sy = 0; sy < sampleRows; sy++) {
    final tileRow = (sy * tileRows / sampleRows).floor();
    final srcY = tileRow * tileLength;
    final th = math.min(tileLength, m.height - srcY);
    final outY0 = (sy * outHeight / sampleRows).floor();
    final outY1 = ((sy + 1) * outHeight / sampleRows).floor().clamp(outY0 + 1, outHeight);

    for (var sx = 0; sx < sampleCols; sx++) {
      final tileCol = (sx * tileCols / sampleCols).floor();
      final srcX = tileCol * tileWidth;
      final tw = math.min(tileWidth, m.width - srcX);
      final outX0 = (sx * outWidth / sampleCols).floor();
      final outX1 = ((sx + 1) * outWidth / sampleCols).floor().clamp(outX0 + 1, outWidth);

      final tile = page.decodeRegionRgba8(TiffRegion(x: srcX, y: srcY, width: tw, height: th));
      for (var oy = outY0; oy < outY1; oy++) {
        final ty = ((oy - outY0) * th / (outY1 - outY0)).floor().clamp(0, th - 1);
        final tileRowBase = ty * tw * 4;
        final outRowBase = oy * outWidth * 4;
        for (var ox = outX0; ox < outX1; ox++) {
          final tx = ((ox - outX0) * tw / (outX1 - outX0)).floor().clamp(0, tw - 1);
          final s = tileRowBase + tx * 4;
          final d = outRowBase + ox * 4;
          output[d] = tile[s];
          output[d + 1] = tile[s + 1];
          output[d + 2] = tile[s + 2];
          output[d + 3] = tile[s + 3];
        }
      }
      onProgress?.call((sy * sampleCols + sx + 1) / (sampleRows * sampleCols));
    }
  }
  return (output, outWidth, outHeight);
}
