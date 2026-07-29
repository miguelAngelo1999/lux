import 'dart:io';

import 'package:crypto/crypto.dart';

// checksum-start
 const darwinAmd64Checksum = "d20faade89b5974a0f07d55de8e12f7e452ec2fe14a2c9d241000823cbc5667f";
 const darwinArm64Checksum = "36547c73404c3a314c1e22e85e62144096e49aafb39f380536d8b8955f8d3c9b";
 const darwinUniversalChecksum = "653fd260348c0c9139a91c36a6309fb09c6a4c889e13664ae5c740f457ae2794";
 const windowsAmd64Checksum = "aabf7e9b938e7bf5bb41b6f1eaa36118ab012de9d2bff98acf6c44bb9f4a4c1b";
// checksum-end

Future<void> verifyCoreBinary(String path) async {
  final file = File(path);

  // If path is a wrapper shell script (starts with #!), check _real binary instead
  if (await file.exists()) {
    final bytes = await file.readAsBytes();
    if (bytes.length > 2 && bytes[0] == 0x23 && bytes[1] == 0x21) {
      // It's a shell script wrapper — the real binary is at path_real
      final realPath = '${path}_real';
      final realFile = File(realPath);
      if (await realFile.exists()) {
        return _verifyFile(realFile);
      }
      // Wrapper exists but _real doesn't — skip verification
      return;
    }
  }

  return _verifyFile(file);
}

Future<void> _verifyFile(File file) async {
  final validChecksums = <String>{};
  validChecksums.add(darwinAmd64Checksum);
  validChecksums.add(darwinArm64Checksum);
  validChecksums.add(darwinUniversalChecksum);
  validChecksums.add(windowsAmd64Checksum);

  final bytes = await file.readAsBytes();
  final digest = sha256.convert(bytes);
  final hash = digest.toString();

  if (!validChecksums.contains(hash)) {
    throw Exception(
      'Checksum of core binary is not matched. '
      'Expect${validChecksums.toList()}, got $hash.',
    );
  }
}
