import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:utp/src/utp_data.dart';
import 'package:utp/src/utp_protocol_implement.dart';

void main() async {
  // print(compareSeqLess(0, 1));
  // print(compareSeqLess(0, MAX_UINT16));
  // print(DateTime.now().millisecondsSinceEpoch);
  // exit(1);
  // var ss = await ServerUTPSocket.bind(InternetAddress.anyIPv4, 0);
  // var port = ss.port;
  // print(port);
  // ss.listen((socket) {
  //   print('${socket.remoteAddress.address}:${socket.remotePort} connect me');
  //   // Timer(Duration(seconds: 5),
  //   //     () => socket.add(Uint8List.fromList('Hello JS'.codeUnits)));
  //   // Timer(Duration(seconds: 15),
  //   //     () => socket.add(Uint8List.fromList('Hello JS'.codeUnits)));
  //   // for (var i = 0; i < 2000; i++) {
  //   // socket.add(Uint8List.fromList('i'.toString().codeUnits));
  //   // }
  //   socket.listen((datas) {
  //     print(String.fromCharCodes(datas));
  //   }, onError: (e) {
  //     log('error:', error: e);
  //   });
  // });
  var count = 0;
  var pool = UTPSocketPool();
  var s1 = await pool.connect(InternetAddress.tryParse('127.0.0.1'), 50269);
  print('connect ${s1.remoteAddress.address}:${s1.remotePort} successfully');
  s1.listen((datas) {
    count++;
    print('${String.fromCharCodes(datas)},length:${datas.length}');
    // s1.add(Uint8List.fromList('World'.codeUnits));
  });
  // Timer.periodic(Duration(seconds: 5), (timer) {
    for (var i = 0; i < 10000; i++) {
      s1.add(Uint8List.fromList('$i,'.toString().codeUnits));
    }
  // });

  // await Future.delayed(Duration(seconds: 5),
  //     () => s1.add(Uint8List.fromList('World'.codeUnits)));
}
