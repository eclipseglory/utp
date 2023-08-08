import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';

import 'utils.dart';
import 'utp_data.dart';
import 'base/utp_socket.dart';
import 'utp_socket_impl.dart';
import 'base/utp_socket_recorder.dart';
import 'base/server_utp_socket.dart';

const MAX_TIMEOUT = 5;

/// 100 ms = 100000 micro seconds
const CCONTROL_TARGET = 100000;

/// Each UDP packet should less than 1400 bytes
const MAX_PACKET_SIZE = 1382;

const MIN_PACKET_SIZE = 150;

const MAX_CWND_INCREASE_PACKETS_PER_RTT = 3000;

class ServerUTPSocketImpl extends ServerUTPSocket with UTPSocketRecorder {
  bool _closed = false;

  bool get isClosed => _closed;

  RawDatagramSocket? _socket;

  StreamController<UTPSocket>? _sc;

  ServerUTPSocketImpl(this._socket) {
    assert(_socket != null, 'UDP socket parameter can not be null');
    _sc = StreamController<UTPSocket>();

    _socket?.listen((event) {
      if (event == RawSocketEvent.read) {
        var datagram = _socket?.receive();
        if (datagram == null) return;
        var address = datagram.address;
        var port = datagram.port;
        UTPPacket? data;
        try {
          data = parseData(datagram.data);
        } catch (e) {
          dev.log('Process receive data error :',
              error: e, name: runtimeType.toString());
          return;
        }
        if (data == null) {
          dev.log('Process receive data error :',
              error: 'Data is null', name: runtimeType.toString());
          return;
        }
        var connId = data.connectionId;
        var utp = findUTPSocket(connId);
        processReceiveData(_socket, address, port, data, utp,
            newSocket: (socket) {
              if (socket.connectionId != null) {
                recordUTPSocket(socket.connectionId!, socket);
              }
              socket.closeHandler = this;
            },
            onConnected: (socket) => _sc?.add(socket));
      }
    }, onDone: () {
      close('Remote/Local socket closed');
    }, onError: (e) {
      dev.log('UDP error:', error: e, name: runtimeType.toString());
    });
  }

  @override
  InternetAddress? get address => _socket?.address;

  @override
  int? get port => _socket?.port;

  @override
  Future<dynamic> close([dynamic reason]) async {
    if (isClosed) return;
    _closed = true;
    var l = <Future>[];
    forEach((socket) {
      var r = socket.close(reason);
      l.add(r);
    });

    await Stream.fromFutures(l).toList();

    _socket?.close();
    _socket = null;
    var re = await _sc?.close();
    _sc = null;
    return re;
  }

  @override
  StreamSubscription<UTPSocket>? listen(void Function(UTPSocket p1) onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return _sc?.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  void socketClosed(UTPSocketImpl socket) {
    if (socket.connectionId != null) {
      removeUTPSocket(socket.connectionId!);
    }
  }
}
