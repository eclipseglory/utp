import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:developer' as dev;
import 'utils.dart';
import 'enums/utp_connection_state.dart';
import 'utp_data.dart';
import 'base/utp_socket.dart';
import 'utp_socket_impl.dart';
import 'base/utp_socket_recorder.dart';
import 'base/utp_close_handler.dart';

///
/// UTP socket client.
///
/// This class can connect remote UTP socket. One UTPSocketClient
/// can create multiple UTPSocket.
///
/// See also [ServerUTPSocket]
class UTPSocketClient extends UTPCloseHandler with UTPSocketRecorder {
  bool _closed = false;

  /// Has it been destroyed
  bool get isClosed => _closed;

  /// Each UDP socket can handler max connections
  final int maxSockets;

  RawDatagramSocket? _rawSocket;

  UTPSocketClient([this.maxSockets = 10]);

  InternetAddress? address;

  final Map<int, Completer<UTPSocket>> _connectingSocketMap = {};

  bool get isFull => indexMap.length >= maxSockets;

  bool get isNotFull => !isFull;

  /// Connect remote UTP server socket.
  ///
  /// If [remoteAddress] and [remotePort] related socket was connectted already ,
  /// it will return a `Future` with `UTPSocket` instance directly;
  ///
  /// or this method will try to create a new `UTPSocket` instance to connect remote,
  /// once connect succesffully , the return `Future` will complete with the instance ,
  /// if connect fail , the `Future` will complete with an exception.
  Future<UTPSocket?> connect(InternetAddress remoteAddress, int remotePort,
      [int localPort = 0]) async {
    _closed = false;
    if (indexMap.length >= maxSockets) return null;
    if (_rawSocket == null) {
      _rawSocket =
          await RawDatagramSocket.bind(InternetAddress.anyIPv4, localPort);
      _rawSocket?.listen((event) => _onData(event),
          onDone: () => _onDone(), onError: (e) => _onError(e));
    }

    var connId = Random().nextInt(MAX_UINT16);
    var utp = UTPSocketImpl(_rawSocket!, remoteAddress, remotePort);
    var completer = Completer<UTPSocket>();
    _connectingSocketMap[connId] = completer;

    utp.connectionState =
        UTPConnectState.SYN_SENT; // Modify the socket connection state.
    // Initialize send_id and _receive_id.
    utp.receiveId = connId; // Initialize a random connection ID.
    utp.sendId = (utp.receiveId ?? 0 + 1) & MAX_UINT16;
    utp.sendId &= MAX_UINT16; // Avoid overflow
    utp.currentLocalSeq = Random()
        .nextInt(MAX_UINT16); // Generate a random sequence number (seq).
    utp.lastRemoteSeq =
        0; // This is set to 0, the remote seq is not obtained at the beginning
    utp.lastRemotePktTimestamp = 0;
    utp.closeHandler = this;
    var packet = UTPPacket(ST_SYN, connId, 0, 0, utp.maxWindowSize,
        utp.currentLocalSeq, utp.lastRemoteSeq);
    utp.sendPacket(packet, 0, true, true);
    recordUTPSocket(connId, utp);
    return completer.future;
  }

  void _onData(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      var datagram = _rawSocket?.receive();
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
      if (utp == null) {
        dev.log('UTP error',
            error: 'Can not find connection $connId',
            name: runtimeType.toString());
        return;
      }
      var completer = _connectingSocketMap.remove(connId);
      processReceiveData(utp.socket, address, port, data, utp,
          onConnected: (socket) {
            socket.closeHandler = this;
            completer?.complete(socket);
          },
          onError: (socket, error) => completer?.completeError(error));
    }
  }

  void _onDone() async {
    await close('Local/Remote closed the connection');
  }

  void _onError(dynamic e) {
    dev.log('UDP socket error:', error: e, name: runtimeType.toString());
  }

  /// Close the raw UDP socket and all UTP sockets
  Future close([dynamic reason]) async {
    if (isClosed) return;
    _closed = true;
    _rawSocket?.close();
    _rawSocket = null;
    var f = <Future>[];
    indexMap.forEach((key, socket) {
      var r = socket.close();
      f.add(r);
    });
    clean();

    _connectingSocketMap.forEach((key, c) {
      if (!c.isCompleted) {
        c.completeError('Socket was disposed');
      }
    });
    _connectingSocketMap.clear();
    return Stream.fromFutures(f).toList();
  }

  @override
  void socketClosed(UTPSocketImpl socket) {
    if (socket.connectionId != null) {
      removeUTPSocket(socket.connectionId!);
    }

    var completer = _connectingSocketMap.remove(socket.connectionId);
    if (completer != null && !completer.isCompleted) {
      completer.completeError('Connect remote failed');
    }
  }
}
