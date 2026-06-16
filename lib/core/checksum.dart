import 'dart:io';

import 'package:crypto/crypto.dart';

// checksum-start
 const darwinAmd64Checksum = "d23b911e046560cfb404d4d2a083dbe00be6392abfcd756202ada2d895be401b";
 const darwinArm64Checksum = "5081d02925f05742efc121f933329e9e885fd726d98fd8df34860a7fde88727c";
 const windowsAmd64Checksum = "8f7a765ab5d01a403de9ef274724400e9619576a7c8033cd5a1e36d352efe80c";
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
