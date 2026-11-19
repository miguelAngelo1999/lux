import 'dart:io';

import 'package:crypto/crypto.dart';

// checksum-start
 const darwinAmd64Checksum = "6f9f717c1a83e9c73563e3ac3a72c11d02c757a8a8688d2ba52b4a44c98da1f7";
 const darwinArm64Checksum = "f0250e763c7324b6cbe67887fd8dae379e49115fb1b6b4d6ead9f0ec579a3583";
// Windows: NO checksum validation. The Inno Setup installer verifies
// integrity before installing. A Dart-level check causes "checksum mismatch"
// crashes on every update because the installer cannot kill lux_core.exe
// (a SYSTEM process), leaving old lux.exe checking new lux_core.exe's hash.
 const windowsAmd64Checksum = "817dc04bcbfd24eeb4c27ff3bb090fae7c58c569aba49433de39a6776531a480";
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
