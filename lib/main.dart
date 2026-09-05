import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:tiff/tiff_image_adapter.dart';

import 'tiff_viewer_page.dart';

void main() {
  // Needed once, up front, so any Compression 6/7 (JPEG-in-TIFF) file
  // decodes instead of throwing.
  TiffImageAdapter.enableJpegSupport();
  runApp(const TiffTesterApp());
}

class TiffTesterApp extends StatelessWidget {
  const TiffTesterApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(seedColor: Colors.indigo);
    return MaterialApp(
      title: 'TIFF Tester',
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: colorScheme.surface,
        appBarTheme: AppBarTheme(
          backgroundColor: colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(color: colorScheme.onSurface, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: colorScheme.surfaceContainerLow,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  Future<void> _pickFile(BuildContext context) async {
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['tif', 'tiff']);
    final path = file?.path;
    if (path == null || !context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => TiffViewerPage(filePath: path)));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('TIFF Tester')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(color: colorScheme.primaryContainer, shape: BoxShape.circle),
                  child: Icon(Icons.image_search_rounded, size: 48, color: colorScheme.onPrimaryContainer),
                ),
                const SizedBox(height: 24),
                Text(
                  'Open a TIFF file',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Choose a .tif or .tiff file to inspect its metadata, preview '
                  'it, and try out optimization/caching strategies for large images.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _pickFile(context),
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Choose TIFF file...'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
