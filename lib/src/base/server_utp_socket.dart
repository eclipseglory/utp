import 'dart:async';
import 'dart:io';

import 'utp_close_handler.dart';
import '../utp_server_impl.dart';
import 'utp_socket.dart';

///
/// This class will create a UTP socket to listening income UTP socket.
///
/// See also [UTPSocketClient]
abstract class ServerUTPSocket extends UTPCloseHandler {
  int? get port;

  InternetAddress? get address;

  Future<dynamic> close([dynamic reason]);

  StreamSubscription<UTPSocket>? listen(void Function(UTPSocket socket) onData,
      {Function onError, void Function() onDone, bool cancelOnError});

  static Future<ServerUTPSocketImpl> bind(dynamic host, [int port = 0]) async {
    var socket = await RawDatagramSocket.bind(host, port);
    return ServerUTPSocketImpl(socket);
  }
}
