import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:utp/src/utp_protocol_implement.dart';

void main() async {
  var ss = await ServerUTPSocket.bind(InternetAddress.anyIPv4, 0);
  var port = ss.port;
  var count = 0;
  var s2;
  ss.listen((socket) {
    print(
        '${socket.remoteAddress.address}:${socket.remotePort}[${socket.connectionId}] connect me');
    socket.listen((data) {
      var str = utf8.decode(data); //String.fromCharCodes(data);
      print(
          'Receive "$str" from ${socket.remoteAddress.address}:${socket.remotePort}[${socket.connectionId}] ,$count');
      count++;
      if (count == 200) {
        print(s2);
      }
    });
  });

  var pool = UTPSocketClient();
  s2 = await pool.connect(InternetAddress.tryParse('127.0.0.1'), port);
  print(
      'connect ${s2.remoteAddress.address}:${s2.remotePort}[${s2.connectionId}] successfully');
  s2.listen((datas) {
    // pool.dispose();
  });
  for (var i = 0; i < 1000; i++) {
    s2.add(Uint8List.fromList(utf8.encode('$i 个数据')));
  }
}
