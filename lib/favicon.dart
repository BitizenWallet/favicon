import 'dart:typed_data';

import 'package:html/parser.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart';

// Signatures from https://en.wikipedia.org/wiki/List_of_file_signatures
const ICO_SIG = [0, 0, 1, 0];
const PNG_SIG = [137, 80, 78, 71, 13, 10, 26, 10];

class Icon implements Comparable<Icon> {
  String url;
  int width;
  int height;

  Icon(this.url, {this.width = 0, this.height = 0});

  @override
  int compareTo(Icon other) {
    // If both are vector graphics, use URL length as tie-breaker
    if (url.endsWith('.svg') && other.url.endsWith('.svg')) {
      return url.length < other.url.length ? -1 : 1;
    }

    // Sort vector graphics before bitmaps
    if (url.endsWith('.svg')) return -1;
    if (other.url.endsWith('.svg')) return 1;

    // If bitmap size is the same, use URL length as tie-breaker
    if (width * height == other.width * other.height) {
      return url.length < other.url.length ? -1 : 1;
    }

    // Sort on bitmap size
    return (width * height > other.width * other.height) ? -1 : 1;
  }

  @override
  String toString() {
    return '{Url: $url, width: $width, height: $height}';
  }
}

class Favicon {
  static Future<List<Icon>> getAll(String url,
      {String? body, List<String>? suffixes}) async {
    Map<Uri, http.Response?> cache = {};
    var favicons = <Icon>[];
    var iconUrls = <String>[];

    var uri = Uri.parse(url);
    if (body == null) {
      final resp = await httpGetWithCache(uri, cache);
      body = resp?.body;
    }
    var document = parse(body!);

    // Look for icons in tags
    for (var rel in ['icon', 'shortcut icon']) {
      for (var iconTag in document.querySelectorAll("link[rel='$rel']")) {
        if (iconTag.attributes['href'] != null) {
          var iconUrl = iconTag.attributes['href']!.trim();

          // Fix scheme relative URLs
          if (iconUrl.startsWith('//')) {
            iconUrl = uri.scheme + ':' + iconUrl;
          }

          // Fix relative URLs
          if (iconUrl.startsWith('/')) {
            iconUrl = uri.scheme + '://' + uri.host + iconUrl;
          }

          // Fix naked URLs
          if (!iconUrl.startsWith('http')) {
            iconUrl = uri.scheme + '://' + uri.host + '/' + iconUrl;
          }

          // Remove query strings
          iconUrl = iconUrl.split('?').first;

          // Verify so the icon actually exists
          if (await _verifyImage(iconUrl, cache)) {
            iconUrls.add(iconUrl);
          }
        }
      }
    }

    // Look for icon by predefined URL
    var iconUrl = uri.scheme + '://' + uri.host + '/favicon.ico';
    if (await _verifyImage(iconUrl, cache)) {
      iconUrls.add(iconUrl);
    }

    // Deduplicate
    iconUrls = iconUrls.toSet().toList();

    // Filter on suffixes
    if (suffixes != null) {
      iconUrls.removeWhere((url) => !suffixes.contains(url.split('.').last));
    }

    // Fetch dimensions
    for (var iconUrl in iconUrls) {
      // No need for size calculation on vector images
      if (iconUrl.endsWith('.svg')) {
        favicons.add(Icon(iconUrl));
        continue;
      }

      // Image library lacks read support for Ico, assume standard size
      // https://github.com/brendan-duncan/image/issues/212
      if (iconUrl.endsWith('.ico')) {
        favicons.add(Icon(iconUrl, width: 16, height: 16));
        continue;
      }

      final resp = await httpGetWithCache(Uri.parse(iconUrl), cache);

      if (resp != null) {
        var image = decodeImage(resp.bodyBytes);
        if (image != null) {
          favicons.add(Icon(iconUrl, width: image.width, height: image.height));
        }
      }
    }

    return favicons..sort();
  }

  static Future<Icon?> getBest(String url,
      {String? body, List<String>? suffixes}) async {
    List<Icon> favicons = await getAll(url, suffixes: suffixes, body: body);
    return favicons.isNotEmpty ? favicons.first : null;
  }

  static Future<bool> _verifyImage(
      String url, Map<Uri, http.Response?> cache) async {
    var response = await httpGetWithCache(Uri.parse(url), cache);
    if (response == null) {
      return false;
    }

    var contentType = response.headers['content-type'];
    if (contentType == null || !contentType.contains('image')) return false;

    // Take extra care with ico's since they might be constructed manually
    if (url.endsWith('.ico')) {
      if (response.bodyBytes.length < 4) return false;

      // Check if ico file contains a valid image signature
      if (!_verifySignature(response.bodyBytes, ICO_SIG) &&
          !_verifySignature(response.bodyBytes, PNG_SIG)) {
        return false;
      }
    }

    return response.statusCode == 200 &&
        (response.contentLength ?? 0) > 0 &&
        contentType.contains('image');
  }

  static bool _verifySignature(Uint8List bodyBytes, List<int> signature) {
    var fileSignature = bodyBytes.sublist(0, signature.length);
    for (var i = 0; i < fileSignature.length; i++) {
      if (fileSignature[i] != signature[i]) return false;
    }
    return true;
  }

  static Future<http.Response?> httpGetWithCache(
      Uri uri, Map<Uri, http.Response?> cache) async {
    if (!cache.containsKey(uri)) {
      try {
        final resp = await http.get(uri);
        cache[uri] = resp;
      } catch (e) {
        cache[uri] = null;
      }
    }
    return cache[uri];
  }
}
