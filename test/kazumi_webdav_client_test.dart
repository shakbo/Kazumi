import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/sync/kazumi_webdav_client.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

void main() {
  group('KazumiWebDavClient construction and auth', () {
    test('creates client with BasicAuth when credentials are provided', () {
      final client = newKazumiWebDavClient(
        'https://ocis.shakbo.com/dav/spaces/test/_Kazumi',
        user: 'shakbo',
        password: 'password123',
      );

      expect(client, isA<KazumiWebDavClient>());
      expect(client.auth.type, equals(webdav.AuthType.BasicAuth));
      final authHeader = client.auth.authorize('GET', '/');
      expect(
        authHeader,
        equals('Basic ${base64Encode(utf8.encode('shakbo:password123'))}'),
      );
      expect(client.uri, endsWith('/'));
    });

    test('creates client with NoAuth when credentials are empty', () {
      final client = newKazumiWebDavClient(
        'https://ocis.shakbo.com/dav/spaces/test/_Kazumi',
      );

      expect(client.auth.type, equals(webdav.AuthType.NoAuth));
    });
  });

  group('oCIS PROPFIND XML response parsing', () {
    test('parses ownCloud Infinite Scale collection listing correctly', () {
      const ocisXml = '''<?xml version="1.0" encoding="UTF-8"?>
<d:multistatus xmlns:s="http://sabredav.org/ns" xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/dav/spaces/291f1317-0178-4c72-8472-fc8334ad2fc0\$84b681e1-58fc-466d-bef0-83cdc71d198b/_Kazumi/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:getetag>"root-etag"</d:getetag>
        <d:getlastmodified>Sun, 04 Oct 2026 14:51:16 GMT</d:getlastmodified>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/spaces/291f1317-0178-4c72-8472-fc8334ad2fc0\$84b681e1-58fc-466d-bef0-83cdc71d198b/_Kazumi/kazumiSync/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:getetag>"dir-etag"</d:getetag>
        <d:getlastmodified>Sun, 04 Oct 2026 14:52:00 GMT</d:getlastmodified>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/spaces/291f1317-0178-4c72-8472-fc8334ad2fc0\$84b681e1-58fc-466d-bef0-83cdc71d198b/_Kazumi/collectibles.tmp</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>collectibles.tmp</d:displayname>
        <d:resourcetype/>
        <d:getcontentlength>12345</d:getcontentlength>
        <d:getcontenttype>application/octet-stream</d:getcontenttype>
        <d:getetag>"file-etag"</d:getetag>
        <d:getlastmodified>Sun, 04 Oct 2026 14:53:00 GMT</d:getlastmodified>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>''';

      final files = KazumiWebDavClient.parsePropfindResponse(
        '/_Kazumi/',
        ocisXml,
      );

      expect(files.length, equals(2));
      // First child is kazumiSync directory
      expect(files[0].name, equals('kazumiSync'));
      expect(files[0].isDir, isTrue);
      expect(files[0].path, equals('/_Kazumi/kazumiSync/'));

      // Second child is collectibles.tmp file
      expect(files[1].name, equals('collectibles.tmp'));
      expect(files[1].isDir, isFalse);
      expect(files[1].size, equals(12345));
      expect(files[1].path, equals('/_Kazumi/collectibles.tmp'));
    });
  });
}
