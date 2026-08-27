import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:tiff/tiff.dart';
import 'package:tiff/tiff_image_adapter.dart';

import 'package:tiff_tester/main.dart';
import 'package:tiff_tester/tiff_viewer_page.dart';

/// `flutter test` runs with no real platform, so path_provider's method
/// channel has no implementation on the other end — the round-trip write
/// test button needs a fake to give it a real temp directory.
class _FakePathProviderPlatform extends PathProviderPlatform {
  final String tempPath;
  _FakePathProviderPlatform(this.tempPath);

  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

/// The native file-picker dialog can't be driven from a widget test, so these
/// tests exercise [TiffViewerPage] directly with a real TIFF file written to
/// a temp directory — the same code path the picker hands a path to.
String _writeSampleTiff(Directory dir, {required int width, required int height}) {
  final samples = List<int>.generate(width * height * 3, (i) => i % 256);
  final spec = TiffImageSpec(
    width: width,
    height: height,
    samplesPerPixel: 3,
    bitsPerSample: 8,
    photometric: TiffPhotometric.rgb,
    samples: samples,
  );
  final bytes = Uint8List.fromList(TiffEncoder.encode([spec]));
  final file = File('${dir.path}/sample.tiff');
  file.writeAsBytesSync(bytes);
  return file.path;
}

/// pumpAndSettle() never returns while a [CircularProgressIndicator] (an
/// indefinite animation) is in the tree, and the loading/decoding spinner is
/// exactly that — so callers must settle with a bounded number of frames
/// instead once the real async work (driven via runAsync) has finished.
Future<void> _pumpFrames(WidgetTester tester, [int count = 5]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _openViewer(WidgetTester tester, String filePath) async {
  // pumpWidget() itself must run inside runAsync(): initState() kicks off a
  // real dart:io File.readAsBytes(), and a real Future created in the
  // ambient FakeAsync test zone never resolves — even a later runAsync()
  // that waits on it — unless the Future is *created* inside runAsync too.
  await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: TiffViewerPage(filePath: filePath))));
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  await _pumpFrames(tester);
}

/// Opening a file now only loads metadata; the pixel preview is decoded
/// (in a background isolate) only once the "Xem ảnh" button is tapped.
/// The tap itself must run inside runAsync() for the same reason as the
/// real I/O above — it kicks off a real Isolate.spawn + message exchange.
Future<void> _viewImage(WidgetTester tester) async {
  await tester.runAsync(() => tester.tap(find.text('Xem ảnh')));
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  await _pumpFrames(tester);
}

/// Taps one of the three prepare-ahead-of-time buttons (by its label) and
/// waits for the real isolate work it kicks off — same runAsync() reasoning
/// as [_viewImage].
Future<void> _runOptimize(WidgetTester tester, String buttonLabel) async {
  await tester.runAsync(() => tester.tap(find.text(buttonLabel)));
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
  await _pumpFrames(tester);
  // The result text lands right below the optimize buttons — below the
  // fold in the test's fixed-size viewport once the live memory-use line
  // above pushes it down a bit further, and a ListView doesn't keep an
  // off-screen child built (same reasoning as the Gamma slider drag
  // above). Scroll it into view before a caller asserts on it; clamps
  // harmlessly at the bottom if there's nothing more to reveal.
  await tester.drag(find.byType(ListView), const Offset(0, -300));
  await tester.pump();
}

void main() {
  // pumpWidget bypasses lib/main.dart's real main(), so the JPEG hook
  // registration it does there has to happen here too.
  setUpAll(() => TiffImageAdapter.enableJpegSupport());

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('tiff_tester_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  testWidgets('home page offers a file picker button', (WidgetTester tester) async {
    await tester.pumpWidget(const TiffTesterApp());
    await tester.pumpAndSettle();

    expect(find.text('package:tiff — manual test bench'), findsOneWidget);
    expect(find.text('Chọn file TIFF...'), findsOneWidget);
  });

  testWidgets('opens and decodes a real TIFF file end-to-end', (tester) async {
    final path = _writeSampleTiff(tempDir, width: 16, height: 16);
    await _openViewer(tester, path);
    await _viewImage(tester);

    expect(find.textContaining('TiffDecoder.decode() failed'), findsNothing);
    expect(find.textContaining('Region decode failed'), findsNothing);
    // The main viewer is a CustomPaint reading live from a _RegionEngine
    // (not a single fixed RawImage) — see _RegionZoomableImage — so just
    // check it mounted and has a painter attached.
    final mainImageFinder = find.byKey(const Key('mainImage'));
    expect(mainImageFinder, findsOneWidget);
    expect(tester.widget<CustomPaint>(mainImageFinder).painter, isNotNull);
  });

  testWidgets('an oversized image opens centered on a region instead of decoding the whole page', (tester) async {
    // Wider than the app's 4096px overview cap but only 8 rows tall, so the
    // test stays fast/cheap while still exercising a page too big to just
    // decode and show whole.
    final path = _writeSampleTiff(tempDir, width: 5000, height: 8);
    await _openViewer(tester, path);
    await _viewImage(tester);

    expect(find.textContaining('failed'), findsNothing);
    final mainImageFinder = find.byKey(const Key('mainImage'));
    expect(mainImageFinder, findsOneWidget);
    expect(tester.widget<CustomPaint>(mainImageFinder).painter, isNotNull);
  });

  testWidgets('an unreadable path surfaces a decode error instead of crashing', (tester) async {
    await _openViewer(tester, '${tempDir.path}/does_not_exist.tiff');

    expect(find.textContaining('TiffDecoder.decode() failed'), findsOneWidget);
    expect(find.byKey(const Key('mainImage')), findsNothing);
  });

  testWidgets('brightness/contrast/gamma sliders re-render without error', (tester) async {
    final path = _writeSampleTiff(tempDir, width: 16, height: 16);
    await _openViewer(tester, path);
    await _viewImage(tester);
    // The sliders sit below the (now much taller, zoomable) image viewer,
    // past the viewer page ListView's initial viewport — drag until the
    // last of the three (Gamma) is visible, so the ones above it are too.
    await tester.dragUntilVisible(find.text('Gamma'), find.byType(ListView), const Offset(0, -300));

    expect(find.text('Brightness'), findsOneWidget);
    expect(find.text('Contrast'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);

    final sliders = find.byType(Slider);
    expect(sliders, findsNWidgets(3));

    // Changing an adjustment now redecodes bands (with the new brightness/
    // contrast/gamma baked in, see _RegionEngine.setAdjustments) instead of
    // recoloring an already-decoded in-memory buffer, and shows the
    // indefinite-spinner _WorkingIndicator meanwhile — pumpAndSettle() never
    // returns while that's in the tree, so drive the isolate round-trip via
    // runAsync + a real delay and settle with a bounded pump instead, same
    // as _viewImage does for the initial decode.
    await tester.runAsync(() => tester.drag(sliders.first, const Offset(40, 0)));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await _pumpFrames(tester);

    expect(find.textContaining('failed'), findsNothing);
    final mainImageFinder = find.byKey(const Key('mainImage'));
    expect(mainImageFinder, findsOneWidget);
    expect(tester.widget<CustomPaint>(mainImageFinder).painter, isNotNull);

    await tester.runAsync(() => tester.tap(find.text('Reset')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await _pumpFrames(tester);

    expect(find.textContaining('failed'), findsNothing);
    expect(find.byKey(const Key('mainImage')), findsOneWidget);
  });

  testWidgets('round-trip write test button works from a picked file', (tester) async {
    final path = _writeSampleTiff(tempDir, width: 8, height: 8);
    await _openViewer(tester, path);
    // The button sits below the RawImage and sliders, past the viewer
    // page ListView's initial viewport.
    await tester.dragUntilVisible(
      find.text('Round-trip write test (force BigTIFF, Deflate)'),
      find.byType(ListView),
      const Offset(0, -300),
    );

    // The tap must happen inside runAsync() too: it triggers _runWriteTest(),
    // which does real dart:io work (getTemporaryDirectory, File read/write)
    // that never resolves if kicked off from the ambient FakeAsync zone.
    await tester.runAsync(() => tester.tap(find.text('Round-trip write test (force BigTIFF, Deflate)')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await _pumpFrames(tester);

    expect(find.textContaining('OK —'), findsOneWidget);
  });

  testWidgets('optimize: tile + pyramid writes a new, tiled TIFF next to the source', (tester) async {
    final path = _writeSampleTiff(tempDir, width: 16, height: 16);
    await _openViewer(tester, path);

    await _runOptimize(tester, 'Tile hoá + pyramid');

    expect(find.textContaining('failed'), findsNothing);
    expect(find.textContaining('Đã lưu file tối ưu tại'), findsOneWidget);

    final outputPath = '${tempDir.path}/sample.pyramid.tiff';
    expect(File(outputPath).existsSync(), isTrue);
    final optimized = TiffDecoder.decode(File(outputPath).readAsBytesSync());
    expect(optimized.images.first.metadata.isTiled, isTrue);
  });

  testWidgets('optimize: tile-only writes a new, tiled TIFF next to the source', (tester) async {
    final path = _writeSampleTiff(tempDir, width: 16, height: 16);
    await _openViewer(tester, path);

    await _runOptimize(tester, 'Chỉ tile hoá');

    expect(find.textContaining('failed'), findsNothing);
    final outputPath = '${tempDir.path}/sample.tiled.tiff';
    expect(File(outputPath).existsSync(), isTrue);
    final optimized = TiffDecoder.decode(File(outputPath).readAsBytesSync());
    expect(optimized.images, hasLength(1));
    expect(optimized.images.first.metadata.isTiled, isTrue);
  });

  testWidgets('optimize: app cache builds no new file and a later open still works', (tester) async {
    final path = _writeSampleTiff(tempDir, width: 16, height: 16);
    await _openViewer(tester, path);

    await _runOptimize(tester, 'Cache riêng cho app này');

    expect(find.textContaining('failed'), findsNothing);
    expect(find.textContaining('Đã tạo cache hiển thị'), findsOneWidget);
    // Unlike the other two strategies, no sibling .tiff file is created.
    expect(File('${tempDir.path}/sample.tiled.tiff').existsSync(), isFalse);
    expect(File('${tempDir.path}/sample.pyramid.tiff').existsSync(), isFalse);

    // Viewing now should transparently pick up the cache and still work.
    await _viewImage(tester);
    expect(find.textContaining('failed'), findsNothing);
    final mainImageFinder = find.byKey(const Key('mainImage'));
    expect(mainImageFinder, findsOneWidget);
    expect(tester.widget<CustomPaint>(mainImageFinder).painter, isNotNull);
  });

  testWidgets('optimize: app cache handles a tile taller than one viewing band without error', (tester) async {
    // Regression test: the cache builder used to decode strictly one
    // low-memory "band" at a time, which for a tile/strip taller than that
    // band redecoded the same tile once per band it overlapped — for a
    // real whole-slide-image file (tiles far taller than one band, given
    // how wide those pages are) that's a 500x-plus redundant-decode
    // blowup. A single very wide tile (one tile spans the whole width) with
    // a tile height taller than the resulting band height reproduces the
    // shape cheaply: it forces bandHeight below tileLength without needing
    // a huge fixture, and still exercises the slicing loop that splits one
    // decoded tile-row chunk into several band files.
    const width = 60000;
    const height = 16;
    final samples = List<int>.generate(width * height * 3, (i) => i % 256);
    final spec = TiffImageSpec(
      width: width,
      height: height,
      samplesPerPixel: 3,
      bitsPerSample: 8,
      photometric: TiffPhotometric.rgb,
      samples: samples,
      tileWidth: width,
      tileLength: 8,
    );
    final bytes = Uint8List.fromList(TiffEncoder.encode([spec]));
    final path = '${tempDir.path}/tall_tile_sample.tiff';
    File(path).writeAsBytesSync(bytes);

    await _openViewer(tester, path);
    await _runOptimize(tester, 'Cache riêng cho app này');

    expect(find.textContaining('failed'), findsNothing);
    expect(find.textContaining('Đã tạo cache hiển thị'), findsOneWidget);

    await _viewImage(tester);
    expect(find.textContaining('failed'), findsNothing);
    final mainImageFinder = find.byKey(const Key('mainImage'));
    expect(mainImageFinder, findsOneWidget);
  });
}
