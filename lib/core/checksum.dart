import 'dart:io';

import 'package:crypto/crypto.dart';

// checksum-start
 const darwinAmd64Checksum = "270dcd06f8de7767c0d4cc7a0ab0f61ba47b54f884340442f1bbc052ef35f3d2";
 const darwinArm64Checksum = "1d2e3ebdc05c884df2effc92909300241a9b917f25d7da398f8ebed1fea544ab";
 const windowsAmd64Checksum = "068ce1c82dd62a3dcfe60d9bae8c3c3b2469692b6e30a842077d43562cb5f99c";
// Older builds that are still valid — keep previous hashes so an in-progress
// update (old lux.exe + new lux_core.exe) doesn't brick until the new lux.exe
// is also installed.
 const windowsAmd64ChecksumPrev = "a42f64ef2bcd8adb9e841124595c28802a8ad7f74519bb07db0583a91a64cfc8";
// checksum-end

Future<void> verifyCoreBinary(String filePath) async {
  var input = File(filePath);
  if (!input.existsSync()) {
    throw "File $filePath does not exist.";
  }
  var value = await sha256.bind(input.openRead()).first;
  var curChecksum = value.toString();
  var validChecksums = <String>[];
  if (Platform.isWindows) {
    validChecksums.add(windowsAmd64Checksum);
    validChecksums.add(windowsAmd64ChecksumPrev); // allow previous build during rolling update
  } else {
    validChecksums.add(darwinAmd64Checksum);
    validChecksums.add(darwinArm64Checksum);
  }
  if (!validChecksums.contains(curChecksum)) {
    throw "Checksum of core binary is not matched. Expect $validChecksums, get $curChecksum.";
  }
}
