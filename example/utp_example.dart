import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:utp/src/utp_protocol_implement.dart';

void main() async {
  print(0xFFFF & -1);
  exit(1);
  var ss = await ServerUTPSocket.bind(InternetAddress.anyIPv4, 0);
  var port = ss.port;
  var count = 0;
  ss.listen((socket) {
    print(
        '${socket.remoteAddress.address}:${socket.remotePort}[${socket.connectionId}] connect me');
    socket.listen((data) {
      var str = utf8.decode(data); //String.fromCharCodes(data);

      print(
          'Receive "$str" from ${socket.remoteAddress.address}:${socket.remotePort}[${socket.connectionId}] ,$count');
      count++;
      if (str == 'Hello') socket.add(Uint8List.fromList('World!'.codeUnits));
      if (str == 'uTP') {
        socket.add(Uint8List.fromList('Protocol'.codeUnits));
      }
    });
  });

  var pool = UTPSocketPool();
  var s1 = await pool.connect(InternetAddress.tryParse('127.0.0.1'), port);
  print(
      'connect ${s1.remoteAddress.address}:${s1.remotePort}[${s1.connectionId}] successfully');
  s1.listen((datas) {
    print(
        'Receive "${String.fromCharCodes(datas)}" from ${s1.remoteAddress.address}:${s1.remotePort}[${s1.connectionId}] ');
  });
  s1.add(Uint8List.fromList('Hello'.codeUnits));

  // var s2 = await pool.connect(InternetAddress.tryParse('127.0.0.1'), port);
  // print(
  //     'connect ${s2.remoteAddress.address}:${s2.remotePort}[${s2.connectionId}] successfully');
  // s2.listen((datas) {
  //   print(
  //       'Receive "${String.fromCharCodes(datas)}" from ${s2.remoteAddress.address}:${s2.remotePort}[${s2.connectionId}] ');
  //   // pool.dispose();
  // });
  // s2.add(Uint8List.fromList('uTP'.codeUnits));
  // for (var i = 0; i < 1000; i++) {
  //   s2.add(Uint8List.fromList(utf8.encode('$i 个数据')));
  // }
}
