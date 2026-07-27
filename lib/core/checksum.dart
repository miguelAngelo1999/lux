import 'dart:io';

import 'package:crypto/crypto.dart';

// checksum-start
 const darwinAmd64Checksum = "d6ffa5a0bfb8732460803d0db893a1f646f074b74e75648ffd279ef53f9aed2a";
 const darwinArm64Checksum = "18715fcfd78d05031f399994effc0d922eeca9318758605a3f8149ba3e2d6285";
 const darwinUniversalChecksum = "e22da6fed02d41f38c637284604a8eeae5f168927460d2e8b984e8e244bde861";
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
