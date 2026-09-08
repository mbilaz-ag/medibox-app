import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as image;
import 'package:path_provider/path_provider.dart';

/// Keeps a compact local copy of a medicine package image.
class MedicineImageService {
  static const _maxBytes = 350 * 1024;

  static Future<String?> fetchAndStore({
    required String imageUrl,
    required String identity,
  }) async {
    final uri = Uri.tryParse(imageUrl);
    if (uri == null || uri.scheme != 'https' || uri.host != 'vaistai.lt') {
      return null;
    }
    try {
      final response = await http.get(uri, headers: const {
        'User-Agent': 'MediBox/1.0',
        'Accept': 'image/avif,image/webp,image/*,*/*;q=0.8',
      }).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 || response.bodyBytes.length > 5000000) {
        return null;
      }
      return _store(response.bodyBytes, identity);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> optimizeLocal(String path, String identity) async {
    try {
      return _store(await File(path).readAsBytes(), identity);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _store(Uint8List bytes, String identity) async {
    final decoded = image.decodeImage(bytes);
    if (decoded == null) return null;
    var width = decoded.width > 480 ? 480 : decoded.width;
    var quality = 72;
    List<int> encoded;
    do {
      final scaled = image.copyResize(decoded, width: width);
      encoded = image.encodeJpg(scaled, quality: quality);
      if (encoded.length <= _maxBytes || width <= 240) break;
      width = (width * 0.75).round();
      quality = quality > 58 ? quality - 7 : quality;
    } while (true);
    final directory = await getApplicationDocumentsDirectory();
    final folder = Directory('${directory.path}/medicine-images');
    if (!await folder.exists()) await folder.create(recursive: true);
    final safeId = base64Url.encode(utf8.encode(identity)).replaceAll('=', '');
    final file = File('${folder.path}/$safeId.jpg');
    await file.writeAsBytes(encoded, flush: true);
    return file.path;
  }
}
