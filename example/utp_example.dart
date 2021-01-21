import 'dart:convert';
import 'dart:io';

import 'package:utp/src/utp_protocol_implement.dart';

void main() async {
  int startTime;
  var ss = await ServerUTPSocket.bind(InternetAddress.anyIPv4, 0);
  var port = ss.port;
  var receive = <int>[];
  var total = 1000;
  ss.listen((socket) {
    print(
        '${socket.remoteAddress.address}:${socket.remotePort}[${socket.connectionId}] connected');
    socket.listen((data) {
      receive.addAll(data);
    }, onDone: () async {
      var endTime = DateTime.now().microsecondsSinceEpoch;
      var result = utf8.decode(receive);
      var t = result.split('\n').where((element) => element.isNotEmpty).length;
      assert(t == total, 'receive data error');
      print(
          'Remote ${socket.remoteAddress.address}:${socket.remotePort}[${socket.connectionId}] closed');
      // print('Receive $t chinese , spend ${(endTime - startTime) / 1000} ms:');
      print('receive $t chinese text: ');
      print('$result');
      await ss.close();
      print('server closed');
    });
  });

  var pool = UTPSocketClient();
  var s1 = await pool.connect(InternetAddress.tryParse('127.0.0.1'), port);
  var chinese = '中文字符甲乙丙丁戊己庚辛';
  print('send ${(chinese.length * total * 2) / 1024} kb datas');
  for (var i = 0; i < total; i++) {
    s1.writeln(chinese);
  }
  startTime = DateTime.now().microsecondsSinceEpoch;
  await s1.close();
  await pool.close();
  print('client closed');
}
