import 'package:flutter_test/flutter_test.dart';
import 'package:lux/util/cert_trust.dart';

void main() {
  group('CertTrust Tests', () {
    test('extractCertThumbprintSha1 extracts uppercase SHA-1 thumbprint', () {
      // Dummy valid base64 payload
      const testPem = '''
-----BEGIN CERTIFICATE-----
MIIBtzCCAVygAwIBAgIUQ1234567890wDQYJKoZIhvcNAQELBQAwFzEVMBMGA1UE
AwwMTHV4IFRlc3QgQ0EwHhcNMjYxMTE1MDAwMDAwWhcNMjcxMTE1MDAwMDAwWjAX
MRUwEwYDVQQDDAxMdXggVGVzdCBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCC
AQoCggEBAL0=
-----END CERTIFICATE-----
''';
      final thumbprint = extractCertThumbprintSha1(testPem);
      expect(thumbprint, isNotNull);
      expect(thumbprint!.length, equals(40));
      expect(thumbprint, equals(thumbprint.toUpperCase()));
    });

    test('extractCertThumbprintSha1 handles empty or malformed PEM gracefully', () {
      expect(extractCertThumbprintSha1(''), isNull);
      expect(extractCertThumbprintSha1('invalid pem data'), isNull);
    });

    test('fetchRootCaPem returns null for invalid host without throwing', () async {
      final res = await fetchRootCaPem('127.0.0.1:59999');
      expect(res, isNull);
    });
  });
}
