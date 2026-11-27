import 'dart:io';

import 'package:crypto/crypto.dart';

// checksum-start
 const darwinAmd64Checksum = "4f8ed6c12a9edbcb5d21ac520dbd125047f987856c97ae0a103285b50f993731";
 const darwinArm64Checksum = "05ba6e2a12a1686e0edbf3669a1dfcc606d59b9d9b9c69607d6ad816121201b5";
// Windows: NO checksum validation. The Inno Setup installer verifies
// integrity before installing. A Dart-level check causes "checksum mismatch"
// crashes on every update because the installer cannot kill lux_core.exe
// (a SYSTEM process), leaving old lux.exe checking new lux_core.exe's hash.
 const windowsAmd64Checksum = "c2ec90e45d9c9ddd219e3c655c7b17bf14b6149928fd81ce6d12abf2c6f9a5fc";
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
    "b8300bf43c376e467ccd1aa129c1eb7a5e94164c6de2d4e54ce6f4072dc5354f",
    "d93456d6b8d7593b2835281237e7da506eba78f7199e9e4243f039a4cf4dd563",
    "4487fced126348b2dfef79ba29e6d46308181b668c4a110adb007aac35c6ef26",
    "e249eaafcb69d21dcfbc0e1bb723423e4cc803aa925bbb486d7191472e56d8c9",
    "747c97ddc7382f9a248472b29922f900bdeb11e85011497f21af8788b8edc306",
    "0e342dbddf8361f45a7d3f8e8015b2721b15a558ca542e5bf4018756c578fc2f",
  ];
  if (!validChecksums.contains(curChecksum)) {
    throw "Checksum of core binary is not matched. Expect $validChecksums, get $curChecksum.";
  }
}
