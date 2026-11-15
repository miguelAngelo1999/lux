import 'dart:io';

import 'package:crypto/crypto.dart';

// checksum-start
 const darwinAmd64Checksum = "f497ca2ec1adb960c1e7945f53f32633d00d3c9155317d461ba09d77d4e37d97";
 const darwinArm64Checksum = "f4ffa939e222b1f9075f3ddaa0618cba233e2e4c25503fd31b67e112e9a229bb";
// Windows: NO checksum validation. The Inno Setup installer verifies
// integrity before installing. A Dart-level check causes "checksum mismatch"
// crashes on every update because the installer cannot kill lux_core.exe
// (a SYSTEM process), leaving old lux.exe checking new lux_core.exe's hash.
 const windowsAmd64Checksum = "9b52088f60b1878d94bc97d8640924b664147a88020d41b3374847e386a2f269";
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
  final validChecksums = [
    darwinAmd64Checksum,
    darwinArm64Checksum,
    "4487fced126348b2dfef79ba29e6d46308181b668c4a110adb007aac35c6ef26",
    "e249eaafcb69d21dcfbc0e1bb723423e4cc803aa925bbb486d7191472e56d8c9",
    "747c97ddc7382f9a248472b29922f900bdeb11e85011497f21af8788b8edc306",
    "0e342dbddf8361f45a7d3f8e8015b2721b15a558ca542e5bf4018756c578fc2f",
  ];
  if (!validChecksums.contains(curChecksum)) {
    throw "Checksum of core binary is not matched. Expect $validChecksums, get $curChecksum.";
  }
}
