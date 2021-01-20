import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:utp/src/utp_protocol_implement.dart';

void main(List<String> args) async {
  var server = await ServerUTPSocket.bind(InternetAddress.anyIPv4, 65444);
  var port = server.port;
  server.listen((socket) {
    socket.listen((datas) {
      print(String.fromCharCodes(datas));
    }, onDone: () {
      print('server socket closed');
      server.close();
    });
  }, onDone: () {
    print('server closed');
  }, onError: (e) {
    print(e);
  });
  print('Server listening: $port');
  var client = UTPSocketClient();
  var socket =
      await client.connect(InternetAddress.tryParse('127.0.0.1'), port);
  socket.listen((datas) {}, onDone: () async {
    print('client socket closed');
    await client.close();
  });
  socket.add(Uint8List.fromList('byte'.codeUnits));
  await socket.close();
}
