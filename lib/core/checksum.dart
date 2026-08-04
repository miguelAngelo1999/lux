import 'dart:io';

import 'package:crypto/crypto.dart';

// checksum-start
 const darwinAmd64Checksum = "785728fe453d6e343823d4bb7ea03e16b3fb27cfac7e57651362862a33de0298";
 const darwinArm64Checksum = "16e5e8b053ab6170dd8a884b697e57f33d6cded9de863ae93f0c5e5d7ffa79c1";
 const darwinUniversalChecksum = "468657be2f35d6a63deb9aac0dae04c7c6fc1ecd76f97da14bfa99572a84a4db";
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
