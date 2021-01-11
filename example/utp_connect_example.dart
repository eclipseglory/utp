import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:utp/src/utp_protocol_implement.dart';

void main() async {
  var ss = await ServerUTPSocket.bind(InternetAddress.anyIPv4, 0);
  var port = ss.port;
  print(port);
  ss.listen((socket) {
    print('${socket.remoteAddress.address}:${socket.remotePort} connect me');
    // socket.add(Uint8List.fromList('Hello JS'.codeUnits));
    socket.listen((datas) {
      print(String.fromCharCodes(datas));
      for (var i = 0; i < 100; i++) {
        socket.add(Uint8List.fromList(i.toString().codeUnits));
      }
    });
  });
  // var count = 0;
  // var pool = UTPSocketPool();
  // var s1 = await pool.connect(InternetAddress.tryParse('127.0.0.1'), 49309);
  // print('connect ${s1.remoteAddress.address}:${s1.remotePort} successfully');
  // s1.listen((datas) {
  //   count++;
  //   print('${String.fromCharCodes(datas)},length:${datas.length}');
  //   // s1.add(Uint8List.fromList('World'.codeUnits));
  // });
  // for (var i = 0; i < 20; i++) {
  //   s1.add(Uint8List.fromList('i'.toString().codeUnits));
  // }
  // await Future.delayed(Duration(seconds: 5),
  //     () => s1.add(Uint8List.fromList('World'.codeUnits)));

  /*
    发送SYN给对方,seq:49877, ack:0
收到对方ACK包:seq_nr:41 , ack_nr : 49877
connect 127.0.0.1:61374 successfully
发送Data给对方,seq:49878 , ack:40
收到对方ACK包:seq_nr:41 , ack_nr : 49878
收到对方Data包:seq_nr:41 , ack_nr : 49878
发送ACK给对方,seq_nr:49879 ack_nr : 41
utp
收到对方Data包:seq_nr:42 , ack_nr : 49878
发送ACK给对方,seq_nr:49879 ack_nr : 42
utputputputputputputputputputputputputputputputputputputp

------

发送SYN给对方,seq:3894, ack:0
收到对方ACK包:seq_nr:41 , ack_nr : 3894
connect 127.0.0.1:56273 successfully
发送Data给对方,seq:3895 , ack:40
收到对方Data包:seq_nr:41 , ack_nr : 3894
发送ACK给对方,seq_nr:3896 ack_nr : 41
utp
收到对方ACK包:seq_nr:43 , ack_nr : 3895
收到对方Data包:seq_nr:42 , ack_nr : 3895
发送ACK给对方,seq_nr:3896 ack_nr : 42
utputputputputputputputputputputputputputputputputputputp

  */
}
