part of '../tiff_viewer_page.dart';

/// Entry point for the long-lived band-decoding isolate behind
/// [_RegionEngine], for a non-tiled (strip-organized) page. Unlike
/// [_TileEngine]'s 2D tile grid, requests here are always full-width
/// horizontal bands: a strip can't be partially decoded, so cropping
/// columns out of it would mean redecoding (decompressing) the same strip
/// once per column-tile instead of once per row-band. Bands line up with
/// how strip data actually works, at whatever granularity keeps one band's
/// raw decode under [_RegionEngine._bandTargetBytes].
///
/// Same handshake/request shape as [_tileWorkerEntry]: sends its own
/// [SendPort] back first (or a `String` error), then processes
/// `(requestId, kind, y, height, brightness, contrast, gamma)` — `kind` 0
/// decodes that row-range as RGBA8 with the given adjustments baked in
/// (see [ImageAdjustments]); `kind` 1 ignores the rest and produces a
/// capped-size overview via [_decodePreviewRgba]. Replies are
/// `(requestId, rgba, width, height)` or `(requestId, error)`.
void _regionWorkerEntry((SendPort, String) args) {
  final (mainSendPort, filePath) = args;
  TiffImageAdapter.enableJpegSupport();

  final TiffDocument document;
  final TiffImage page;
  try {
    document = decodeTiffFile(File(filePath));
    page = document.images.first;
  } catch (e) {
    mainSendPort.send('$e');
    return;
  }

  final requestPort = ReceivePort();
  mainSendPort.send(requestPort.sendPort);

  requestPort.listen((message) {
    final (requestId, kind, y, height, brightness, contrast, gamma) =
        message as (int, int, int, int, double, double, double);
    try {
      if (kind == 1) {
        final (rgba, w, h) = _decodePreviewRgba(page);
        mainSendPort.send((requestId, rgba, w, h));
        return;
      }
      final width = page.metadata.width;
      final rgba = ImageAdjustments.apply(
        page.decodeRegionRgba8(TiffRegion(x: 0, y: y, width: width, height: height)),
        brightness: brightness,
        contrast: contrast,
        gamma: gamma,
      );
      mainSendPort.send((requestId, rgba, width, height));
    } catch (e) {
      mainSendPort.send((requestId, '$e'));
    }
  });
}

/// One in-flight or completed request: which band it was for (or `-1` for
/// the overview) and which [_RegionEngine._adjustmentVersion] it was made
/// under — a result that arrives after adjustments have since changed
/// again is discarded rather than cached, so a stale-brightness band never
/// overwrites a fresher request already in flight for the same band.
typedef _RegionRequest = ({String kind, int bandIndex, int version});

/// Drives viewport-based progressive loading for a non-tiled page: an
/// overview appears almost immediately (see [_decodePreviewRgba]), then
/// only the horizontal bands that intersect whatever [requestVisible] was
/// last called with are decoded, one at a time, by a persistent worker
/// isolate — never the full page at once. Bands are cached (bounded,
/// LRU-evicted) so panning back over already-seen ground is instant.
///
/// Deliberately simpler than [_TileEngine]: one worker (band decode is
/// already cheap relative to a multi-gigapixel tiled page, and there's no
/// pyramid to pick a rung from), and requests are 1D (row-range only) since
/// a band always spans the full page width.
class _RegionEngine extends ChangeNotifier {
  /// How many decoded bands this instance's cache holds before evicting —
  /// unlike [_bandTargetBytes] (which bounds *one* band's raw decode), this
  /// bounds the retained RGBA cost of the whole persistent cache together,
  /// so it needs this instance's actual band dimensions rather than a
  /// context-free constant. Recomputed on every call (cheap: one RSS read
  /// plus arithmetic) so it tracks the app's current memory pressure rather
  /// than freezing whatever was true when the page opened.
  int get _maxCachedBands {
    final bytesPerBand = metadata.width * bandHeight * 4;
    final budget = _MemoryMonitor.budgetFor(
      fraction: 0.25, // up to a quarter of the budget for this persistent cache
      minBytes: 4 * 1024 * 1024,
      maxBytes: 128 * 1024 * 1024,
    );
    return math.max(4, budget ~/ math.max(1, bytesPerBand));
  }

  /// How many bands beyond the visible edge to prefetch, in units of one
  /// band — small enough to stay cheap, big enough that a modest vertical
  /// pan doesn't show a bare edge while the next band decodes.
  static const _prefetchMarginBands = 1;

  /// Target raw decode size for one band — much smaller than
  /// [_maxBandBytes], which bounds a single *transient* band during a
  /// one-shot overview decode. This bounds each band in a *persistent*,
  /// multi-band cache instead, so [_maxCachedBands] of them stay reasonable
  /// in memory together. Scales with [_MemoryMonitor.availableBudgetBytes]
  /// the same way [_maxBandBytes] does, just at a smaller share.
  static int _bandTargetBytes() => _MemoryMonitor.budgetFor(
    fraction: 0.0078125, // 4 MiB out of the 512 MiB default budget
    minBytes: 512 * 1024,
    maxBytes: 8 * 1024 * 1024,
  );

  final String filePath;
  final TiffImageMetadata metadata;
  final int bandHeight;

  /// A previously-built [_DisplayCache] for this exact file (see
  /// [_DisplayCache.open]), or `null` to decode live via [_regionWorkerEntry]
  /// as usual. When set, every band/overview fetch is a plain file read
  /// (see [_loadBandFromCache]/[_loadOverviewFromCache]) instead of a
  /// round trip to the decode isolate — no isolate is even spawned.
  final _DisplayCache? cache;

  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _sendPort;
  bool _busy = false;
  bool _disposed = false;

  Object? _fatalError;
  ui.Image? overview;

  final _cache = <int, ui.Image>{};
  final _pending = <int>{};
  final _requests = <int, _RegionRequest>{};
  int _nextRequestId = 0;
  int _adjustmentVersion = 0;
  double _brightness = 0;
  double _contrast = 1;
  double _gamma = 1;

  Rect? _lastVisibleRect;

  _RegionEngine({required this.filePath, required this.metadata, this.cache})
    : bandHeight = cache?.bandHeight ?? _computeBandHeight(metadata);

  static int _computeBandHeight(TiffImageMetadata m) {
    final bytesPerPixel = _bandBytesPerPixel(m);
    return math.max(1, math.min(m.height, _bandTargetBytes() ~/ (m.width * bytesPerPixel)));
  }

  int get baseWidth => metadata.width;
  int get baseHeight => metadata.height;
  Object? get fatalError => _fatalError;
  bool get isWorking => _busy || _pending.isNotEmpty;

  Future<void> start() async {
    if (cache != null) {
      await _loadOverviewFromCache();
      return;
    }

    final receivePort = ReceivePort();
    _receivePort = receivePort;
    final handshake = Completer<void>();
    receivePort.listen((message) => _onMessage(message, handshake));
    try {
      _isolate = await Isolate.spawn(_regionWorkerEntry, (receivePort.sendPort, filePath));
    } catch (e) {
      _fatalError = e;
      notifyListeners();
      if (!handshake.isCompleted) handshake.complete();
    }
    await handshake.future;
    if (_disposed) return;
    _requestOverview();
  }

  void requestVisible(Rect baseVisibleRect) {
    _lastVisibleRect = baseVisibleRect;
    if (cache != null) {
      _loadBandsFromCache();
    } else {
      _pump();
    }
  }

  /// Sets new brightness/contrast/gamma values and clears the band cache —
  /// currently-visible bands get redecoded (with the new adjustments baked
  /// in, see [_regionWorkerEntry]/[_loadBandFromCache]) via the normal
  /// fetch flow; off-screen bands simply redecode next time they're panned
  /// into view instead of paying for an upfront redecode of the whole
  /// cache.
  void setAdjustments({required double brightness, required double contrast, required double gamma}) {
    _brightness = brightness;
    _contrast = contrast;
    _gamma = gamma;
    _adjustmentVersion++;
    for (final image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
    notifyListeners();
    if (cache != null) {
      _loadBandsFromCache();
    } else {
      _pump();
    }
  }

  Future<void> _loadOverviewFromCache() async {
    final cache = this.cache;
    if (cache == null) return;
    try {
      final raw = await cache.readOverview();
      final (w, h) = await cache.readOverviewSize();
      if (_disposed) return;
      final image = await _decodeUiImage(raw, w, h);
      if (_disposed) {
        image.dispose();
        return;
      }
      overview = image;
      notifyListeners();
    } catch (_) {
      // Leave overview null — the painter falls back to its placeholder
      // background, and a broken/missing cache file otherwise doesn't stop
      // bands from loading.
    }
  }

  void _loadBandsFromCache() {
    final cache = this.cache;
    final rect = _lastVisibleRect;
    if (cache == null || rect == null) return;
    for (final band in _bandsForRect(rect)) {
      if (_cache.containsKey(band) || _pending.contains(band)) continue;
      _loadBandFromCache(cache, band);
    }
  }

  Future<void> _loadBandFromCache(_DisplayCache cache, int bandIndex) async {
    _pending.add(bandIndex);
    final loadVersion = _adjustmentVersion;
    try {
      final raw = await cache.readBand(bandIndex);
      if (_disposed) return;
      final adjusted = (_brightness == 0 && _contrast == 1 && _gamma == 1)
          ? raw
          : ImageAdjustments.apply(raw, brightness: _brightness, contrast: _contrast, gamma: _gamma);
      // Adjustments changed since this read started — its pixels are
      // already stale, so drop it; the cleared cache already re-requested
      // this band (or didn't, if it's no longer visible).
      if (loadVersion != _adjustmentVersion) return;
      final y = bandIndex * bandHeight;
      final height = math.min(bandHeight, baseHeight - y);
      final image = await _decodeUiImage(adjusted, baseWidth, height);
      if (_disposed) {
        image.dispose();
        return;
      }
      _cacheBand(bandIndex, image);
      notifyListeners();
    } catch (_) {
      // Leave it uncached — the next requestVisible() that still wants this
      // band retries the read.
    } finally {
      _pending.remove(bandIndex);
    }
  }

  void _onMessage(dynamic message, Completer<void> handshake) {
    if (_disposed) return;
    if (message is SendPort) {
      _sendPort = message;
      if (!handshake.isCompleted) handshake.complete();
      return;
    }
    if (message is String) {
      _fatalError = message;
      notifyListeners();
      if (!handshake.isCompleted) handshake.complete();
      return;
    }
    if (message is (int, Uint8List, int, int)) {
      final (requestId, rgba, width, height) = message;
      _handleResult(requestId, rgba, width, height);
      return;
    }
    if (message is (int, String)) {
      final (requestId, _) = message;
      _handleFailure(requestId);
    }
  }

  int get _totalBands => (baseHeight + bandHeight - 1) ~/ bandHeight;

  List<int> _bandsForRect(Rect rect) {
    final marginY = bandHeight * _prefetchMarginBands;
    final top = (rect.top - marginY).clamp(0, baseHeight.toDouble());
    final bottom = (rect.bottom + marginY).clamp(0, baseHeight.toDouble());
    if (bottom <= top) return const [];
    final firstBand = (top / bandHeight).floor();
    final lastBand = math.min(_totalBands - 1, ((bottom - 1) / bandHeight).floor());
    if (lastBand < firstBand) return const [];

    final centerY = rect.center.dy;
    final bands = [for (var b = firstBand; b <= lastBand; b++) b];
    bands.sort((a, b) {
      final ay = ((a + 0.5) * bandHeight - centerY).abs();
      final by = ((b + 0.5) * bandHeight - centerY).abs();
      return ay.compareTo(by);
    });
    return bands;
  }

  void _pump() {
    if (_busy || _sendPort == null) return;
    final rect = _lastVisibleRect;
    if (rect == null) return;
    for (final band in _bandsForRect(rect)) {
      if (_cache.containsKey(band) || _pending.contains(band)) continue;
      _dispatchBand(band);
      return;
    }
  }

  void _dispatchBand(int bandIndex) {
    final port = _sendPort;
    if (port == null) return;
    final y = bandIndex * bandHeight;
    final height = math.min(bandHeight, baseHeight - y);
    final id = _nextRequestId++;
    _busy = true;
    _pending.add(bandIndex);
    _requests[id] = (kind: 'band', bandIndex: bandIndex, version: _adjustmentVersion);
    port.send((id, 0, y, height, _brightness, _contrast, _gamma));
  }

  void _requestOverview() {
    final port = _sendPort;
    if (port == null) return;
    final id = _nextRequestId++;
    _busy = true;
    _requests[id] = (kind: 'overview', bandIndex: -1, version: _adjustmentVersion);
    port.send((id, 1, 0, 0, 0.0, 1.0, 1.0));
  }

  Future<void> _handleResult(int requestId, Uint8List rgba, int width, int height) async {
    final request = _requests.remove(requestId);
    _busy = false;
    if (request == null) {
      _pump();
      return;
    }
    if (request.kind == 'band') _pending.remove(request.bandIndex);

    // Adjustments changed since this request went out — its pixels are
    // already stale, so drop it and let the now-cleared cache re-request
    // this band (or not, if it's no longer visible) instead.
    if (request.version == _adjustmentVersion) {
      final image = await _decodeUiImage(rgba, width, height);
      // dispose() (widget torn down mid-decode) can land while the above
      // await is in flight — the engine and its ChangeNotifier are gone by
      // the time we get here, so just release this now-orphaned image
      // instead of touching disposed state.
      if (_disposed) {
        image.dispose();
        return;
      }
      if (request.kind == 'overview') {
        overview?.dispose();
        overview = image;
      } else {
        _cacheBand(request.bandIndex, image);
      }
      notifyListeners();
    }
    _pump();
  }

  void _handleFailure(int requestId) {
    if (_disposed) return;
    final request = _requests.remove(requestId);
    _busy = false;
    if (request != null && request.kind == 'band') _pending.remove(request.bandIndex);
    _pump();
  }

  Future<ui.Image> _decodeUiImage(Uint8List rgba, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  void _cacheBand(int bandIndex, ui.Image image) {
    if (_cache.length >= _maxCachedBands) {
      final rect = _lastVisibleRect;
      final needed = rect == null ? const <int>{} : _bandsForRect(rect).toSet();
      final victim = _cache.keys.firstWhere((k) => !needed.contains(k), orElse: () => _cache.keys.first);
      _cache.remove(victim)?.dispose();
    }
    _cache[bandIndex] = image;
  }

  List<(int, ui.Image)> cachedBandEntries() => [for (final entry in _cache.entries) (entry.key, entry.value)];

  @override
  void dispose() {
    _disposed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _receivePort?.close();
    overview?.dispose();
    for (final image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
    super.dispose();
  }
}
