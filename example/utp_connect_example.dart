import 'dart:async';
import 'dart:collection';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:utp/src/utp_data.dart';
import 'package:utp/src/utp_protocol_implement.dart';

void main() async {
//   time : 37978 , seq : 2 , ack : 40 diff 3928696703
// Remote:seq:41 : ack 1 , time 29574 , diff 4294956452 s-ack SelectiveACK :
  // 1610785561042 29755
  /// 26691 1610785853962
  /// time : 36978 , seq : 2 , ack : 6333 diff 4182072641
  ///Remote:seq:6334 : ack 1 , time 1321024461 , diff 1320986443 s-ack SelectiveACK :

  // var t = DateTime.fromMicrosecondsSinceEpoch(765972086 + 766026193);
  // // // print(compareSeqLess(0, 1));
  // // // print(compareSeqLess(0, MAX_UINT16));
  // // // print(DateTime.now().millisecondsSinceEpoch);
  // // var time = DateTime.fromMicrosecondsSinceEpoch(0);
  // // // 761219
  // // var time2 = DateTime.fromMicrosecondsSinceEpoch(761218435);
  // // print(time2.microsecondsSinceEpoch - time.microsecondsSinceEpoch);
  // // print(time);
  // // var now = DateTime.now();

  var port;
  // var ss = await ServerUTPSocket.bind(InternetAddress.anyIPv4, 64444);
  //   port = ss.port;
  // print(port);
  // ss.listen((socket) {
  //   print('${socket.remoteAddress.address}:${socket.remotePort} connect me');

  //   socket.listen((datas) {
  //     print(String.fromCharCodes(datas));
  //   }, onError: (e) {
  //     log('error:', error: e);
  //   });
  // });
  port = 54388;
  var pool = UTPSocketClient();
  var s1 = await pool.connect(InternetAddress.tryParse('127.0.0.1'), port);
  print('connect ${s1.remoteAddress.address}:${s1.remotePort} successfully');
  s1.listen((datas) {
    print('${String.fromCharCodes(datas)},length:${datas.length}');
    // s1.add(Uint8List.fromList('World'.codeUnits));
  });
  // Timer.periodic(Duration(seconds: 5), (timer) {
  for (var i = 0; i < 10000; i++) {
    s1.add(Uint8List.fromList('$i ,'.toString().codeUnits));
  }
  // });
}

// 1610785561042 29755
