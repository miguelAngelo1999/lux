import 'dart:io';

import 'package:crypto/crypto.dart';

// checksum-start
 const darwinAmd64Checksum = "24c981d2a838f807568cb9ab5b00c8e5f021e120f466fb85e13dc2be73480c12";
 const darwinArm64Checksum = "b3251d55dad1f497afbe3407ed369107179f6f803dff58e69a0f3f846e17f46d";
 const darwinUniversalChecksum = "c0d279901d04b318bdd46e76688ba66a0f8a92e49f94dd4b2c5db7588bae58f6";
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
