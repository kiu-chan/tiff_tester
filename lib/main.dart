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
    return MaterialApp(
      title: 'tiff package tester',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
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
    return Scaffold(
      appBar: AppBar(title: const Text('package:tiff — manual test bench')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_search, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('Chọn một file .tif / .tiff để xem thử'),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _pickFile(context),
              icon: const Icon(Icons.folder_open),
              label: const Text('Chọn file TIFF...'),
            ),
          ],
        ),
      ),
    );
  }
}
