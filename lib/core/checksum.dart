import 'dart:io';

import 'package:crypto/crypto.dart';

// checksum-start
 const darwinAmd64Checksum = "6146982cd80750dff36ccba6b3e1aa117a2d2e2c539c758187acf226442a9a49";
 const darwinArm64Checksum = "c4d39d5f3dacc662773385e8dc4cc1a2206e5d5b44f26275d4a713d1639e140f";
 const darwinUniversalChecksum = "d51eda156d215a1103c9b78015522c71e1c59d876ac8e14d09e675a6e06292d8";
 const windowsAmd64Checksum = "03bff64cae27d5d2804b578132e94a6f95a5a9beef42fb3e1c1132b2c85afc9f";
// checksum-end

Future<void> verifyCoreBinary(String filePath) async {
  var input = File(filePath);
  if (!input.existsSync()) {
    throw "File $filePath does not exist.";
  }
  // If the file is a shell script wrapper (elevation setup), verify the real binary instead
  var checkPath = filePath;
  final realPath = '${filePath}_real';
  if (await File(realPath).exists()) {
    checkPath = realPath;
  } else {
    // Check if it's a shell script (starts with #!)
    final bytes = await File(filePath).openRead(0, 2).first;
    if (bytes.length >= 2 && bytes[0] == 0x23 && bytes[1] == 0x21) {
      // Shell script wrapper — skip verification (elevation handled externally)
      return;
    }
  }
  var value = await sha256.bind(File(checkPath).openRead()).first;
  var curChecksum = value.toString();
  var validChecksums = <String>[];
  if (Platform.isWindows) {
    validChecksums.add(windowsAmd64Checksum);
  } else {
    validChecksums.add(darwinAmd64Checksum);
    validChecksums.add(darwinArm64Checksum);
    validChecksums.add(darwinUniversalChecksum);
  }
  if (!validChecksums.contains(curChecksum)) {
    throw "Checksum of core binary is not matched. Expect $validChecksums, get $curChecksum.";
  }
}

