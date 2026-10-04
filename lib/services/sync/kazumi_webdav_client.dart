import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;
import 'package:xml/xml.dart';

/// A robust WebDAV client designed to support modern WebDAV implementations
/// such as ownCloud Infinite Scale (oCIS), Nextcloud, and Apache/Nginx WebDAV.
///
/// Fixes critical compatibility issues in [webdav.Client]:
/// 1. Preemptive Basic Authentication: sends HTTP Basic Auth upfront instead of
///    relying on 401 challenges where multi-value Www-Authenticate headers fail to parse.
/// 2. Tolerates HTTP 204 No Content for OPTIONS requests (standard RFC behavior in oCIS).
/// 3. Removes unnecessary and failing OPTIONS pre-flights before GET and PUT streaming.
/// 4. Robust XML parsing for PROPFIND (Depth: 1) without fragile 405 error throws.
class KazumiWebDavClient extends webdav.Client {
  KazumiWebDavClient({
    required super.uri,
    required super.c,
    required super.auth,
    super.debug,
  });

  static const String _propfindXmlStr = '''<d:propfind xmlns:d='DAV:'>
  <d:prop>
    <d:displayname/>
    <d:resourcetype/>
    <d:getcontentlength/>
    <d:getcontenttype/>
    <d:getetag/>
    <d:getlastmodified/>
  </d:prop>
</d:propfind>''';

  @override
  Future<void> ping([CancelToken? cancelToken]) async {
    final resp = await c.wdOptions(this, '/', cancelToken: cancelToken);
    final status = resp.statusCode ?? 0;
    // Accept 200 OK, 204 No Content, or any 2xx response.
    if (status < 200 || status >= 300) {
      throw webdav.newResponseError(resp);
    }
  }

  @override
  Future<void> mkdir(String path, [CancelToken? cancelToken]) async {
    final cleanPath = _fixSlashes(path);
    final resp = await c.wdMkcol(this, cleanPath, cancelToken: cancelToken);
    final status = resp.statusCode ?? 0;
    // 201 Created: newly created
    // 405 Method Not Allowed / 200 OK: already exists
    if (status != 201 && status != 405 && status != 200) {
      throw webdav.newResponseError(resp);
    }
  }

  @override
  Future<void> read2File(
    String path,
    String savePath, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final resp = await c.req<ResponseBody>(
      this,
      'GET',
      path,
      optionsHandler: (options) => options.responseType = ResponseType.stream,
      cancelToken: cancelToken,
    );
    final status = resp.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw webdav.newResponseError(resp);
    }
    final file = File(savePath);
    await file.parent.create(recursive: true);
    final raf = await file.open(mode: FileMode.write);
    try {
      final stream = resp.data!.stream;
      var received = 0;
      final contentLengthHeader =
          resp.headers.value(Headers.contentLengthHeader);
      final total = int.tryParse(contentLengthHeader ?? '-1') ?? -1;
      await for (final chunk in stream) {
        await raf.writeFrom(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> writeFromFile(
    String localFilePath,
    String path, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final file = File(localFilePath);
    final length = await file.length();
    final resp = await c.req(
      this,
      'PUT',
      path,
      data: file.openRead(),
      optionsHandler: (options) {
        options.headers?['content-length'] = length;
        options.headers?['content-type'] = 'application/octet-stream';
      },
      onSendProgress: onProgress,
      cancelToken: cancelToken,
    );
    final status = resp.statusCode ?? 0;
    if (status != 200 && status != 201 && status != 204) {
      throw webdav.newResponseError(resp);
    }
  }

  @override
  Future<List<int>> read(
    String path, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final resp = await c.req<List<int>>(
      this,
      'GET',
      path,
      optionsHandler: (options) => options.responseType = ResponseType.bytes,
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
    );
    final status = resp.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw webdav.newResponseError(resp);
    }
    return resp.data ?? <int>[];
  }

  @override
  Future<void> write(
    String path,
    Uint8List data, {
    void Function(int count, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final resp = await c.req(
      this,
      'PUT',
      path,
      data: Stream.fromIterable([data]),
      optionsHandler: (options) {
        options.headers?['content-length'] = data.length;
        options.headers?['content-type'] = 'application/octet-stream';
      },
      onSendProgress: onProgress,
      cancelToken: cancelToken,
    );
    final status = resp.statusCode ?? 0;
    if (status != 200 && status != 201 && status != 204) {
      throw webdav.newResponseError(resp);
    }
  }

  @override
  Future<List<webdav.File>> readDir(String path,
      [CancelToken? cancelToken]) async {
    final cleanPath = _fixSlashes(path);
    final resp = await c.wdPropfind(
      this,
      cleanPath,
      true,
      _propfindXmlStr,
      cancelToken: cancelToken,
    );
    final status = resp.statusCode ?? 0;
    if (status != 207) {
      throw webdav.newResponseError(resp);
    }
    return parsePropfindResponse(cleanPath, resp.data.toString());
  }

  static List<webdav.File> parsePropfindResponse(
      String requestedPath, String xmlStr) {
    final files = <webdav.File>[];
    final doc = XmlDocument.parse(xmlStr);
    final responses = doc.findAllElements('response', namespace: '*').toList();

    for (var i = 0; i < responses.length; i++) {
      final responseElem = responses[i];
      final hrefElems =
          responseElem.findElements('href', namespace: '*').toList();
      if (hrefElems.isEmpty) continue;
      final href = Uri.decodeFull(hrefElems.first.innerText.trim());

      bool isDir = false;
      int size = 0;
      String mimeType = '';
      String eTag = '';
      DateTime? mTime;

      final propstats =
          responseElem.findElements('propstat', namespace: '*').toList();
      for (final propstat in propstats) {
        final statusElem =
            propstat.findElements('status', namespace: '*').firstOrNull;
        if (statusElem == null || !statusElem.innerText.contains('200')) {
          continue;
        }

        final propElem =
            propstat.findElements('prop', namespace: '*').firstOrNull;
        if (propElem == null) continue;

        final resType =
            propElem.findElements('resourcetype', namespace: '*').firstOrNull;
        if (resType != null &&
            resType.findElements('collection', namespace: '*').isNotEmpty) {
          isDir = true;
        }

        final lenElem = propElem
            .findElements('getcontentlength', namespace: '*').firstOrNull;
        if (lenElem != null && lenElem.innerText.trim().isNotEmpty) {
          size = int.tryParse(lenElem.innerText.trim()) ?? 0;
        }

        final typeElem =
            propElem.findElements('getcontenttype', namespace: '*').firstOrNull;
        if (typeElem != null) {
          mimeType = typeElem.innerText.trim();
        }

        final etagElem =
            propElem.findElements('getetag', namespace: '*').firstOrNull;
        if (etagElem != null) {
          eTag = etagElem.innerText.trim();
        }

        final mTimeElem = propElem
            .findElements('getlastmodified', namespace: '*').firstOrNull;
        if (mTimeElem != null && mTimeElem.innerText.trim().isNotEmpty) {
          try {
            mTime = HttpDate.parse(mTimeElem.innerText.trim()).toLocal();
          } catch (_) {}
        }
      }

      final normalizedHref = href.replaceAll(RegExp(r'/+$'), '');
      final name = normalizedHref.isEmpty
          ? ''
          : normalizedHref.substring(normalizedHref.lastIndexOf('/') + 1);

      // Skip the queried collection itself (the root of PROPFIND Depth: 1).
      if (i == 0 && isDir) {
        continue;
      }
      if (name.isEmpty) {
        continue;
      }

      final filePath = '$requestedPath$name${isDir ? '/' : ''}';
      files.add(webdav.File(
        path: filePath,
        isDir: isDir,
        name: name,
        mimeType: mimeType,
        size: size,
        eTag: eTag,
        mTime: mTime,
      ));
    }
    return files;
  }
}



webdav.Client newKazumiWebDavClient(
  String uri, {
  String user = '',
  String password = '',
  bool debug = false,
}) {
  final cleanUri = _fixSlash(uri);
  final dio = webdav.WdDio(debug: debug);
  final auth = (user.isNotEmpty || password.isNotEmpty)
      ? webdav.BasicAuth(user: user, pwd: password)
      : webdav.Auth(user: user, pwd: password);
  return KazumiWebDavClient(
    uri: cleanUri,
    c: dio,
    auth: auth,
    debug: debug,
  );
}

String _fixSlash(String s) {
  if (!s.endsWith('/')) {
    return '$s/';
  }
  return s;
}

String _fixSlashes(String s) {
  if (!s.startsWith('/')) {
    s = '/$s';
  }
  return _fixSlash(s);
}
