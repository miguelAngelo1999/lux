import 'dart:io';

import 'package:crypto/crypto.dart';

// checksum-start
 const darwinAmd64Checksum = "76bf5403336adc8a636dae9bf7c943fef2ae3bbfa910560ccca82d9103fcd3d2";
 const darwinArm64Checksum = "2766bd97f0f1fc0778a2ce9d47ba87546d2d820792278922f682da7b22a21792";
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
