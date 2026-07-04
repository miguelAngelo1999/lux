import 'dart:io';

import 'package:crypto/crypto.dart';

// checksum-start
 const darwinAmd64Checksum = "6146982cd80750dff36ccba6b3e1aa117a2d2e2c539c758187acf226442a9a49";
 const darwinArm64Checksum = "c4d39d5f3dacc662773385e8dc4cc1a2206e5d5b44f26275d4a713d1639e140f";
 const darwinUniversalChecksum = "bf7221c50142a018e9aabdb7fc7dee1277164ede2f29f9e4da8ab87213d14e81";
 const windowsAmd64Checksum = "8e11a43ebdb0bf35b4e400e6e62c75d72d14e2bb7ae61da2fdd8e000c78bf673";
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
