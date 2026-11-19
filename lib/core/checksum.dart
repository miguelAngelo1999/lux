import 'dart:io';

import 'package:crypto/crypto.dart';

// checksum-start
 const darwinAmd64Checksum = "098afe0ffad2193c145e01cb3de44737b0b694d387be354c7d6ad92060f475c3";
 const darwinArm64Checksum = "b4650b01a98ef1a36b352c18f82dbe2ec223116dd23760ac9b274214b639977a";
// Windows: NO checksum validation. The Inno Setup installer verifies
// integrity before installing. A Dart-level check causes "checksum mismatch"
// crashes on every update because the installer cannot kill lux_core.exe
// (a SYSTEM process), leaving old lux.exe checking new lux_core.exe's hash.
 const windowsAmd64Checksum = "064c3edf529eb258e2a41b0344a103108a3a0f1d0696aa7a1746457221872f2d";
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
