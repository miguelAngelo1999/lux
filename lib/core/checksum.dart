import 'dart:io';

import 'package:crypto/crypto.dart';

// checksum-start
 const darwinAmd64Checksum = "270dcd06f8de7767c0d4cc7a0ab0f61ba47b54f884340442f1bbc052ef35f3d2";
 const darwinArm64Checksum = "1d2e3ebdc05c884df2effc92909300241a9b917f25d7da398f8ebed1fea544ab";
// Windows: NO checksum validation. The Inno Setup installer verifies
// integrity before installing. A Dart-level check causes "checksum mismatch"
// crashes on every update because the installer cannot kill lux_core.exe
// (a SYSTEM process), leaving old lux.exe checking new lux_core.exe's hash.
 const windowsAmd64Checksum = "";
// checksum-end

Future<void> verifyCoreBinary(String filePath) async {
  // Windows: skip entirely — installer guarantees integrity.
  if (Platform.isWindows) return;

  var input = File(filePath);
  if (!input.existsSync()) {
    throw "File $filePath does not exist.";
  }
  var value = await sha256.bind(input.openRead()).first;
  var curChecksum = value.toString();
  final validChecksums = [darwinAmd64Checksum, darwinArm64Checksum];
  if (!validChecksums.contains(curChecksum)) {
    throw "Checksum of core binary is not matched. Expect $validChecksums, get $curChecksum.";
  }
}
