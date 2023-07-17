import 'dart:convert';
import 'dart:io';

import 'package:utp/src/base/server_utp_socket.dart';
import 'package:utp/src/utp_socket_client.dart';

void main() async {
  var total = 21889;
  var chinese = '中文字符甲乙丙丁戊己庚辛\n';
  int startTime;
  var ss = await ServerUTPSocket.bind(InternetAddress.anyIPv4, 0);
  var port = ss.port;
  print('[Server] start to listening at $port');
  var receive = <int>[];
  ss.listen((socket) {
    startTime = DateTime.now().microsecondsSinceEpoch;
    print(
        '[Server] ${socket.remoteAddress.address}:${socket.remotePort}[${socket.connectionId}] connected');
    socket.listen((data) {
      receive.addAll(data);
    }, onDone: () async {
      var endTime = DateTime.now().microsecondsSinceEpoch;
      var spendTime = (endTime - startTime) / 1000000;
      var result = utf8.decode(receive);
      var totalSize = receive.length / 1024;
      receive.clear();
      print('$result');
      await ss.close();
      print(
          '[Server] Remote ${socket.remoteAddress.address}:${socket.remotePort}[${socket.connectionId}] closed,so close server too');
      print(
          '[Server] Server closed. Receive $totalSize kb datas , speed ${(totalSize / spendTime).toStringAsFixed(3)} kb/s');
    });
  });

  var pool = UTPSocketClient();
  var s1 = await pool.connect(InternetAddress.tryParse('127.0.0.1')!, port!);
  var cbys = utf8.encode(chinese).length;
  print(
      '[Client] Connect ${s1?.remoteAddress.address}:${s1?.remotePort}[${s1?.connectionId}] successfully. Start to send ${(total * cbys) / 1024}kb datas');
  for (var i = 0; i < total; i++) {
    s1?.write(chinese);
  }
  await s1?.close();
  print('[Client] Client closed');
  await pool.close();
}
