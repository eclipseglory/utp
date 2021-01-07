import 'dart:io';
import 'dart:typed_data';

import 'package:utp/src/utp_protocol_implement.dart';

void main() async {
  var ss = await ServerUTPSocket.bind(InternetAddress.anyIPv4, 0);
  var port = ss.port;
  ss.listen((socket) {
    print('${socket.remoteAddress.address}:${socket.remotePort} connect me');
    socket.listen((data) {
      print(String.fromCharCodes(data));
      socket.add(Uint8List.fromList('World!'.codeUnits));
      ss.close();
    });
  });

  var pool = UTPSocketPool();
  pool.connect(InternetAddress.tryParse('127.0.0.1'), port).then((socket) {
    print(
        'connect ${socket.remoteAddress.address}:${socket.remotePort} successfully');
    socket.listen((data) {
      print(String.fromCharCodes(data));
      pool.dispose();
    });
    socket.add(Uint8List.fromList('Hello'.codeUnits));
  });

  print('wait');
}
