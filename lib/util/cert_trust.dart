import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

class CertTrustException implements Exception {
  final String message;
  CertTrustException(this.message);
  @override
  String toString() => message;
}

/// Extracts the 40-character uppercase hexadecimal SHA-1 thumbprint of an X.509
/// certificate from its PEM representation.
String? extractCertThumbprintSha1(String pem) {
  try {
    final lines = pem
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('-----'))
        .join('');
    if (lines.isEmpty) return null;
    final bytes = base64Decode(lines);
    return sha1.convert(bytes).toString().toUpperCase();
  } catch (_) {
    return null;
  }
}

/// Directly fetches the CA certificate from the upstream proxy via plain HTTP,
/// explicitly disabling any HTTP proxy to avoid chicken-and-egg interception.
/// Primary: `http://<proxy_host>/root-ca`
/// Fallback: `http://<proxy_host>:9876/download/cas`
Future<String?> fetchRootCaPem(String proxyHost) async {
  var host = proxyHost.trim();
  if (host.contains(':')) {
    host = host.split(':').first;
  }
  if (host.isEmpty) return null;

  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..findProxy = (uri) => "DIRECT"; // Explicitly disable HTTP proxy

  final urls = [
    'http://$host/root-ca',
    'http://$host:9876/download/cas',
  ];

  for (final url in urls) {
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close().timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final bytes = await resp.fold<List<int>>([], (p, e) => p..addAll(e));
        if (bytes.isNotEmpty) {
          final str = utf8.decode(bytes, allowMalformed: true);
          if (str.contains('-----BEGIN CERTIFICATE-----')) {
            client.close(force: true);
            return str;
          }
          // Raw DER bytes — encode as PEM
          final b64 = base64Encode(bytes);
          final chunked = RegExp(r'.{1,64}').allMatches(b64).map((m) => m.group(0)).join('\n');
          client.close(force: true);
          return '-----BEGIN CERTIFICATE-----\n$chunked\n-----END CERTIFICATE-----\n';
        }
      }
    } catch (e) {
      debugPrint('[CertTrust] Fetch from $url failed: $e');
    }
  }
  client.close(force: true);
  return null;
}

/// Checks whether the certificate is already installed in the system root store:
/// - Windows: Cert:\LocalMachine\Root
/// - macOS: /Library/Keychains/System.keychain
Future<bool> isCertInSystemStore({String? pem, String? thumbprint}) async {
  final sha1Hex = thumbprint ?? (pem != null ? extractCertThumbprintSha1(pem) : null);
  if (sha1Hex == null || sha1Hex.isEmpty) return false;

  try {
    if (Platform.isWindows) {
      final res = await Process.run('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        '(Get-ChildItem Cert:\\LocalMachine\\Root | Where-Object { \$_.Thumbprint -eq "$sha1Hex" }).Count',
      ]);
      if (res.exitCode == 0) {
        final count = int.tryParse((res.stdout as String).trim()) ?? 0;
        return count > 0;
      }
    } else if (Platform.isMacOS) {
      final res = await Process.run('/usr/bin/security', [
        'find-certificate',
        '-a',
        '-Z',
        '/Library/Keychains/System.keychain',
      ]);
      if (res.exitCode == 0) {
        final out = (res.stdout as String).toUpperCase();
        return out.contains(sha1Hex.toUpperCase());
      }
    }
  } catch (e) {
    debugPrint('[CertTrust] Pre-check store error: $e');
  }
  return false;
}

/// Implements the proven CLI installer script method to trust the CA certificate
/// on Windows and macOS.
Future<void> trustProxyCertificate({
  required String proxyHost,
  String? pem,
}) async {
  var host = proxyHost.trim();
  if (host.contains(':')) {
    host = host.split(':').first;
  }

  // 1. Obtain CA PEM if not provided
  String? certPem = pem;
  if (certPem == null || certPem.trim().isEmpty) {
    certPem = await fetchRootCaPem(host);
  }
  if (certPem == null || certPem.trim().isEmpty) {
    throw CertTrustException(
      'Could not reach the proxy certificate endpoint at http://$host/root-ca. Verify your local network connection.',
    );
  }

  final thumbprint = extractCertThumbprintSha1(certPem);

  // 2. Pre-check: if already installed in system root store, nothing to do
  if (thumbprint != null && await isCertInSystemStore(thumbprint: thumbprint)) {
    debugPrint('[CertTrust] Pre-check: certificate $thumbprint already in system store');
    return;
  }

  // 3. Platform-specific trust installation
  if (Platform.isWindows) {
    // Proven CLI Installer Script Method:
    // Write a temporary .ps1 file to disk instead of inlining or piping
    final tempDir = Directory.systemTemp.path;
    final scriptFile = File('$tempDir\\lux_trust_ca_${DateTime.now().millisecondsSinceEpoch}.ps1');
    final escapedPem = certPem.replaceAll("'", "''");

    final ps1Content = '''
\$wc = New-Object System.Net.WebClient
\$wc.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
\$caUrl = "http://$host/root-ca"
\$tmpCert = "\$env:TEMP\\upstream-proxy-ca.crt"
\$pemContent = @'
$escapedPem
'@
if (\$pemContent.Trim().Length -gt 0) {
    [System.IO.File]::WriteAllText(\$tmpCert, \$pemContent)
} else {
    try {
        \$wc.DownloadFile(\$caUrl, \$tmpCert)
    } catch {
        \$caUrl = "http://$host:9876/download/cas"
        \$wc.DownloadFile(\$caUrl, \$tmpCert)
    }
}
if (Test-Path \$tmpCert) {
    try {
        Import-Certificate -FilePath \$tmpCert -CertStoreLocation "Cert:\\LocalMachine\\Root" -ErrorAction Stop
    } catch {
        certutil.exe -addstore -f "Root" \$tmpCert
    }
    Remove-Item -Force \$tmpCert
}
''';

    await scriptFile.writeAsString(ps1Content);

    try {
      final res = await Process.run('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        'Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File \\"${scriptFile.path}\\"" -Wait',
      ]);

      final stdout = (res.stdout as String? ?? '').toLowerCase();
      final stderr = (res.stderr as String? ?? '').toLowerCase();
      final combined = '$stdout\n$stderr';

      if (combined.contains('canceled by the user') ||
          combined.contains('cancelled by the user') ||
          combined.contains('operation was canceled')) {
        throw CertTrustException(
          'Administrative privileges are required to trust the proxy certificate. Please try again and accept the prompt.',
        );
      }

      // Verify certificate presence in store
      if (thumbprint != null) {
        final verified = await isCertInSystemStore(thumbprint: thumbprint);
        if (!verified && res.exitCode != 0) {
          throw CertTrustException(
            'Administrative privileges are required to trust the proxy certificate. Please try again and accept the prompt.',
          );
        }
      }
    } finally {
      try {
        if (await scriptFile.exists()) {
          await scriptFile.delete();
        }
      } catch (_) {}
    }
  } else if (Platform.isMacOS) {
    final tmpCert = File('/tmp/upstream-proxy-ca.crt');
    await tmpCert.writeAsString(certPem);

    try {
      final script =
          '/usr/bin/security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/upstream-proxy-ca.crt && rm -f /tmp/upstream-proxy-ca.crt';
      final res = await Process.run('/usr/bin/osascript', [
        '-e',
        'do shell script "$script" with administrator privileges',
      ]);

      final err = (res.stderr as String? ?? '');
      if (res.exitCode != 0 || err.contains('User canceled') || err.contains('-128')) {
        throw CertTrustException(
          'Administrative privileges are required to trust the proxy certificate. Please try again and accept the prompt.',
        );
      }
    } finally {
      try {
        if (await tmpCert.exists()) {
          await tmpCert.delete();
        }
      } catch (_) {}
    }
  }
}
