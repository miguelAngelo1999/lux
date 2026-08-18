import 'dart:io';

import 'package:crypto/crypto.dart';

// checksum-start
 const darwinAmd64Checksum = "270dcd06f8de7767c0d4cc7a0ab0f61ba47b54f884340442f1bbc052ef35f3d2";
 const darwinArm64Checksum = "1d2e3ebdc05c884df2effc92909300241a9b917f25d7da398f8ebed1fea544ab";
 const windowsAmd64Checksum = "b7f19b7fb430f5782ec5505b543138e20edf7437b9de149b184f41c35c1d779a";
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
  } else {
    validChecksums.add(darwinAmd64Checksum);
    validChecksums.add(darwinArm64Checksum);
  }
  if (!validChecksums.contains(curChecksum)) {
    throw "Checksum of core binary is not matched. Expect $validChecksums, get $curChecksum.";
  }
}
