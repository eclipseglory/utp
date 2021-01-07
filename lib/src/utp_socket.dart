import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'utp_data.dart';

///
///
class UTPSocketPool with _UTPSocketRecorder {
  bool _disposed = false;

  /// 是否已被销毁
  bool get isDisposed => _disposed;

  /// Each UDP socket can handler max connections
  final int maxSockets;

  UTPSocketPool([this.maxSockets = 10]);

  InternetAddress address;

  final List<_RawSocketStack> _fullStack = <_RawSocketStack>[];

  final List<_RawSocketStack> _notFullStack = <_RawSocketStack>[];

  final Map<UTPSocket, Completer<UTPSocket>> _connectingSocketMap = {};

  /// Connect remote UTP server socket.
  ///
  /// If [remoteAddress] and [remotePort] related socket was connectted already ,
  /// it will return a `Future` with `UTPSocket` instance directly;
  ///
  /// or this method will try to create a new `UTPSocket` instance to connect remote,
  /// once connect succesffully , the return `Future` will complete with the instance ,
  /// if connect fail , the `Future` will complete with an exception.
  Future<UTPSocket> connect(
      InternetAddress remoteAddress, int remotePort) async {
    assert(remotePort != null && remoteAddress != null,
        'Address and port can not be null');
    var utp = _getUTPSocket(remoteAddress, remotePort);
    if (utp != null) return utp;
    var stack = _avalidateStack;
    RawDatagramSocket socket;
    if (stack == null) {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      stack = _RawSocketStack(socket, maxSockets);
      stack.onFullStatus(_whenSocketStackFullChange);
      _notFullStack.add(stack);
    } else {
      socket = stack.rawSocket;
    }
    utp = _UTPSocket(socket.address, socket.port, remoteAddress, remotePort);
    utp._socket = socket;
    stack.add(utp);
    _recordUTPSocket(utp, remoteAddress, remotePort);
    socket.listen((event) => _onData(socket, event),
        onDone: () => _onDone(socket), onError: (e) => _onError(socket, e));
    var completer = Completer<UTPSocket>();
    _sendSYN(utp); // Start to connect
    _connectingSocketMap[utp] = completer;
    return completer.future;
  }

  /// Connect SYN. Similar to TCP SYN flag, this packet initiates a connection.
  /// The sequence number is initialized to 1. The connection ID is initialized
  /// to a random number. The syn packet is special, all subsequent packets sent
  ///  on this connection (except for re-sends of the ST_SYN) are sent with the
  /// connection ID + 1. The connection ID is what the other end is expected to
  /// use in its responses.
  void _sendSYN(UTPSocket socket) {
    socket._connectState = _UTPSocketConnectState.SYN_SENT; //修改socket连接状态
    // 初始化send_id 和_receive_id
    socket._receiveId = Random().nextInt(65535); //初始一个随机的connection id
    socket._sendId = socket._receiveId + 1;
    socket._currentLocalSeq = 1; //初始化序列。序列从1开始
    socket._lastRemoteTimestamp = getNowTimeStamp(); // 连接远程第一次的timestamp就是现在
    socket._currentLocalAck = 0; // 这个设为0，起始是没有得到远程seq的
    // 连接发起的时候conn id是receive id
    socket._sendRawData(ST_SYN, connectionId: socket._receiveId);
  }

  _RawSocketStack get _avalidateStack {
    if (_notFullStack.isNotEmpty) return _notFullStack.first;
    return null;
  }

  void _whenSocketStackFullChange(_RawSocketStack stack, bool isFull) {
    if (isFull) {
      _notFullStack.remove(stack);
      _fullStack.add(stack);
    } else {
      _fullStack.remove(stack);
      _notFullStack.add(stack);
    }
  }

  void _onData(RawDatagramSocket source, RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      var datagram = source.receive();
      var address = datagram.address;
      var port = datagram.port;
      var data = datagram.data;
      var utp = _getUTPSocket(address, port);
      if (utp == null || utp.isClosed) return;
      UTPData packageData;
      var completer = _connectingSocketMap.remove(utp);
      try {
        packageData = parseData(data);
      } catch (e) {
        completer?.completeError(e);
        dev.log('Parse receive data error',
            error: e, name: runtimeType.toString());
        return;
      }
      if (packageData.type == ST_STATE) {
        if (utp._connectState == _UTPSocketConnectState.SYN_SENT) {
          var errMsg = _validatePackage(packageData, utp);
          if (errMsg != null) {
            completer?.completeError(errMsg);
            dev.log('Connect remote error',
                error: errMsg, name: runtimeType.toString());
            return;
          }
          utp._lastRemoteTimestamp = packageData.timestamp;
          utp._currentLocalAck = packageData.seq_nr;

          utp._connectState = _UTPSocketConnectState.CONNECTED;

          utp._sendRawData(ST_DATA);
          completer?.complete(utp);
          return;
        }
      }
      if (packageData.type == ST_DATA) {
        if (utp._connectState != _UTPSocketConnectState.CONNECTED) {
          throw 'UTP socket is not connected, cant process ST_DATA';
        }
        var errMsg = _validatePackage(packageData, utp);
        if (errMsg != null) {
          dev.log('Remote data error',
              error: errMsg, name: runtimeType.toString());
          return;
        }
        utp._lastRemoteTimestamp = packageData.timestamp;
        utp._currentLocalAck = packageData.seq_nr;
        var payload = packageData.payload;
        if (payload == null || payload.isEmpty) return;
        var offset = packageData.offset;
        utp._receive(payload.sublist(offset));
      }
    }
  }

  void _onDone(RawDatagramSocket source) {
    _forEach((socket) {
      socket?.close();
    }, source);
  }

  void _onError(RawDatagramSocket source, dynamic e) {
    _forEach((socket) {
      socket?._receiveError(e);
    }, source);
  }

  void _forEach(void Function(UTPSocket socket) processer,
      [RawDatagramSocket source]) {
    _fullStack.forEach((stack) {
      if (source != null && stack.rawSocket == source) {
        stack.forEach(processer);
      }
    });

    _notFullStack.forEach((stack) {
      if (source != null && stack.rawSocket == source) {
        stack.forEach(processer);
      }
    });
  }

  Future dispose([dynamic reason]) async {
    if (isDisposed) return;
    _disposed = true;
    clean();
    for (var i = 0; i < _fullStack.length; i++) {
      var stack = _fullStack[i];
      stack.offFullStatus(_whenSocketStackFullChange);
      await stack.dispose();
    }
    _fullStack.clear();

    for (var i = 0; i < _notFullStack.length; i++) {
      var stack = _notFullStack[i];
      stack.offFullStatus(_whenSocketStackFullChange);
      await stack.dispose();
    }
    _notFullStack.clear();

    _connectingSocketMap.forEach((key, c) {
      if (c != null && !c.isCompleted) {
        c.completeError('Socket was disposed');
      }
    });
    _connectingSocketMap.clear();
  }
}

abstract class ServerUTPSocket {
  int get port;

  InternetAddress get address;

  Future<dynamic> close([dynamic reason]);

  StreamSubscription<UTPSocket> listen(void Function(UTPSocket socket) onData,
      {Function onError, void Function() onDone, bool cancelOnError});

  void _test() async {
    var ss = await ServerSocket.bind(address, port);
    // ss.listen((event) { })
  }

  static Future<ServerUTPSocket> bind(dynamic host, [int port = 0]) async {
    var _socket = await RawDatagramSocket.bind(host, port);
    return _ServerUTPSocket(_socket);
  }
}

class _ServerUTPSocket extends ServerUTPSocket with _UTPSocketRecorder {
  bool _closed = false;

  bool get isClosed => _closed;

  RawDatagramSocket _socket;

  StreamController<UTPSocket> _sc;

  _ServerUTPSocket(this._socket) {
    assert(_socket != null, 'UDP socket parameter can not be null');
    _sc = StreamController<UTPSocket>();

    _socket.listen((event) {
      if (event == RawSocketEvent.read) {
        var datagram = _socket.receive();
        var data = datagram.data;
        var address = datagram.address;
        var port = datagram.port;
        _processReceiveData(address, port, data);
      }
    }, onDone: () {
      close('Remote/Local socket closed');
    }, onError: (e) {
      forEach((socket) {
        socket?._receiveError(e);
      });
    });
  }

  /// Server Socket监听外部连接时处理接收数据
  void _processReceiveData(InternetAddress address, int port, Uint8List data) {
    if (isClosed || _socket == null) return;
    UTPData packageData;
    try {
      packageData = parseData(data);
    } catch (e) {
      dev.log('Parse receive data error :',
          error: e, name: runtimeType.toString());
      return;
    }

    var socket = _getUTPSocket(address, port);
    if (socket != null) {
      if (packageData.type == ST_DATA) {
        var error = _validatePackage(packageData, socket);
        if (error != null) {
          dev.log('Remote connect error:',
              error: error, name: runtimeType.toString());
          socket.close();
          return;
        }
        socket._lastRemoteTimestamp = packageData.timestamp;
        socket._currentLocalAck = packageData.seq_nr;
        // 远程第二次发送信息确认连接
        if (socket._connectState == _UTPSocketConnectState.SYN_RECV) {
          socket._connectState = _UTPSocketConnectState.CONNECTED;
          _sc?.add(socket);
          return;
        }
        // 已连接状态下收到数据后去掉header，把payload以事件发出
        if (socket._connectState == _UTPSocketConnectState.CONNECTED) {
          if (packageData.payload == null || packageData.payload.isEmpty) {
            return;
          }
          var data = packageData.payload.sublist(packageData.offset);
          socket._receive(data);
          return;
        }
      }
      return;
    } else {
      // 远程发起连接
      if (packageData.type == ST_SYN) {
        var utp = _UTPSocket(_socket.address, _socket.port, address, port);
        utp._socket = _socket;
        _recordUTPSocket(utp, address, port);
        // init receive_id and sent_id
        utp._receiveId = packageData.connectionId + 1;
        utp._sendId = packageData.connectionId; // 保证发送的conn id一致
        utp._currentLocalSeq = Random().nextInt(65535); // 随机一个发送序列
        utp._currentLocalAck = packageData.seq_nr;
        utp._connectState = _UTPSocketConnectState.SYN_RECV; // 更改连接状态
        utp._lastRemoteTimestamp = packageData.timestamp;
        utp._sendRawData(ST_STATE);
        return;
      }
    }
  }

  @override
  InternetAddress get address => _socket?.address;

  @override
  int get port => _socket?.port;

  @override
  Future<dynamic> close([dynamic reason]) async {
    if (isClosed) return;
    _closed = true;
    var l = <Future>[];
    forEach((socket) {
      l.add(socket.close(reason));
    });

    await Stream.fromFutures(l).toList();

    _socket?.close();
    _socket = null;
    var re = await _sc?.close();
    _sc = null;
    return re;
  }

  @override
  StreamSubscription<UTPSocket> listen(void Function(UTPSocket p1) onData,
      {Function onError, void Function() onDone, bool cancelOnError}) {
    return _sc?.stream?.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }
}

class _RawSocketStack {
  bool _disposed = false;

  bool get isDisposed => _disposed;

  final int max;

  final Set<void Function(_RawSocketStack source, bool full)>
      _fullStatusHandler = {};

  final Set<UTPSocket> _socketStack = <UTPSocket>{};

  final Map<InternetAddress, Map<int, UTPSocket>> _utpMap = {};

  bool get isFull => _socketStack.length >= max;

  bool get isNotFull => !isFull;

  RawDatagramSocket rawSocket;

  _RawSocketStack(this.rawSocket, this.max);

  bool add(UTPSocket socket) {
    var old = isFull;
    var r = _socketStack.add(socket);
    if (r) {
      _utpMap[socket.remoteAddress] ??= <int, UTPSocket>{};
      var m = _utpMap[socket.remoteAddress];
      m[socket.remotePort] = socket;
      if (old != isFull) {
        _fullStatusHandler.forEach((f) {
          f(this, isFull);
        });
      }
    }
    return r;
  }

  UTPSocket getUTPSocket(InternetAddress remoteAddress, int remotePort) {
    var m = _utpMap[remoteAddress];
    if (m != null) return m[remotePort];
    return null;
  }

  bool remove(UTPSocket socket) {
    var old = isFull;
    var r = _socketStack.remove(socket);
    if (r) {
      var m = _utpMap[socket.remoteAddress];
      if (m != null) {
        m.remove(socket.remotePort);
      }
      if (old != isFull) {
        _fullStatusHandler.forEach((f) {
          f(this, isFull);
        });
      }
    }
    return r;
  }

  bool onFullStatus(void Function(_RawSocketStack source, bool full) handler) {
    return _fullStatusHandler.add(handler);
  }

  bool offFullStatus(void Function(_RawSocketStack source, bool full) handler) {
    return _fullStatusHandler.remove(handler);
  }

  Future dispose() async {
    if (isDisposed) return;
    _disposed = true;
    _fullStatusHandler.clear();
    rawSocket?.close();
    rawSocket = null;
    for (var i = 0; i < _socketStack.length; i++) {
      var utp = _socketStack.elementAt(i);
      await utp?.close();
    }
    _socketStack.clear();
    _utpMap.clear();
  }

  void forEach(void Function(UTPSocket socket) processor) {
    _socketStack.forEach(processor);
  }
}

abstract class UTPSocket {
  _UTPSocketConnectState _connectState;

  RawDatagramSocket _socket;

  int _currentLocalSeq;

  int _currentLocalAck;

  int _receiveId;

  int _sendId;

  InternetAddress remoteAddress;

  int remotePort;

  InternetAddress address;

  int port;

  int maxWindow;

  int _lastRemoteTimestamp;

  UTPSocket(this.address, this.port, this.remoteAddress, this.remotePort,
      [this.maxWindow = 100 * 1024 * 1024]);

  void _receive(Uint8List data);

  void _receiveError(dynamic error);

  void add(Uint8List data);

  void _sendRawData(int type, {int connectionId, Uint8List payload});

  StreamSubscription<Uint8List> listen(void Function(Uint8List datas) onData,
      {Function onError, void Function() onDone, bool cancelOnError});

  Future<dynamic> close([dynamic reason]);

  bool get isClosed;
}

enum _UTPSocketConnectState { SYN_SENT, SYN_RECV, CONNECTED, CLOSED }

class _UTPSocket extends UTPSocket {
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  StreamController<Uint8List> _streamController;
  _UTPSocket(InternetAddress address, int port,
      [InternetAddress remoteAddress, int remotePort])
      : super(address, port, remoteAddress, remotePort) {
    _streamController = StreamController<Uint8List>();
  }

  @override
  void _receive(Uint8List data) {
    _streamController?.add(data);
  }

  @override
  void _receiveError(dynamic error) {
    _streamController?.addError(error);
  }

  @override
  void add(Uint8List data) {
    _sendRawData(ST_DATA, payload: data);
  }

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List data) onData,
      {Function onError, void Function() onDone, bool cancelOnError}) {
    return _streamController?.stream?.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  Future<dynamic> close([dynamic reason]) async {
    if (isClosed) return;
    _closed = true;
    _connectState = _UTPSocketConnectState.CLOSED;
    var re = await _streamController?.close();
    _streamController = null;
    return re;
  }

  @override
  void _sendRawData(int type, {int connectionId, Uint8List payload}) {
    if (isClosed) throw 'Socket is closed';
    connectionId ??= _sendId;
    var timestamp = getNowTimeStamp();
    var stampdiff = timestamp - _lastRemoteTimestamp;
    var sd = createData(type, connectionId, timestamp, stampdiff, maxWindow,
        _currentLocalSeq++, _currentLocalAck,
        payload: payload);
    _socket.send(sd, remoteAddress, remotePort);
  }
}

mixin _UTPSocketRecorder {
  final Map<InternetAddress, Map<int, UTPSocket>> _indexMap = {};

  UTPSocket _getUTPSocket(InternetAddress remoteAddress, int remotePort) {
    var m = _indexMap[remoteAddress];
    if (m != null) {
      return m[remotePort];
    }
    return null;
  }

  void _recordUTPSocket(UTPSocket s, InternetAddress address, int port) {
    _indexMap[address] ??= <int, UTPSocket>{};
    var m = _indexMap[address];
    m[port] = s;
  }

  UTPSocket _removeUTPSocket(InternetAddress remoteAddress, int remotePort) {
    var m = _indexMap[remoteAddress];
    if (m != null) {
      return m.remove(remotePort);
    }
    return null;
  }

  void forEach(void Function(UTPSocket socket) processer) {
    _indexMap.forEach((key, value) {
      value.forEach((key, value) {
        processer(value);
      });
    });
  }

  void clean() {
    _indexMap.clear();
  }
}

// UTPSocket _getUTPSocket(InternetAddress remoteAddress, int remotePort,
//     Map<InternetAddress, Map<int, UTPSocket>> map) {
//   var m = map[remoteAddress];
//   if (m != null) {
//     return m[remotePort];
//   }
//   return null;
// }

// void _saveUTPSocket(UTPSocket s, InternetAddress address, int port,
//     Map<InternetAddress, Map<int, UTPSocket>> map) {
//   map[address] ??= <int, UTPSocket>{};
//   var m = map[address];
//   m[port] = s;
// }

dynamic _validatePackage(UTPData packageData, UTPSocket receiver) {
  if (packageData.connectionId != receiver._receiveId) {
    return 'Connection id invalidate';
  }
  return null;
}

// void _processReceiveDatagram(RawDatagramSocket rawSocket) {
//   var datagram = rawSocket.receive();
//   var address = datagram.address;
//   var port = datagram.port;
//   var data = datagram.data;
//   UTPData packageData;
//   try {
//     packageData = parseData(data);
//   } catch (e) {
//     dev.log('Parse receive data error :',
//         error: e, name: 'utp_socket.dart');
//     return;
//   }

//   var socket = _getUTPSocket(address, port, _utpSocketIndexMap);
//   if (socket != null) {
//     if (packageData.type == ST_DATA) {
//       var error = _validatePackage(packageData, socket);
//       if (error != null) {
//         dev.log('Remote connect error:',
//             error: error, name: runtimeType.toString());
//         socket.close();
//         return;
//       }
//       socket._lastRemoteTimestamp = packageData.timestamp;
//       socket._currentLocalAck = packageData.seq_nr;
//       // 远程第二次发送信息确认连接
//       if (socket._connectState == _UTPSocketConnectState.SYN_RECV) {
//         socket._connectState = _UTPSocketConnectState.CONNECTED;
//         _sc?.add(socket);
//         return;
//       }
//       // 已连接状态下收到数据后去掉header，把payload以事件发出
//       if (socket._connectState == _UTPSocketConnectState.CONNECTED) {
//         if (packageData.payload == null || packageData.payload.isEmpty) {
//           return;
//         }
//         var data = packageData.payload.sublist(packageData.offset);
//         socket._receive(data);
//         return;
//       }
//     }
//     return;
//   } else {
//     // 远程发起连接
//     if (packageData.type == ST_SYN) {
//       var utp = _UTPSocket(_socket.address, _socket.port, address, port);
//       utp._socket = _socket;
//       _saveUTPSocket(utp, address, port, _utpSocketIndexMap);
//       // init receive_id and sent_id
//       utp._receiveId = packageData.connectionId + 1;
//       utp._sendId = packageData.connectionId; // 保证发送的conn id一致
//       utp._currentLocalSeq = Random().nextInt(65535); // 随机一个发送序列
//       utp._currentLocalAck = packageData.seq_nr;
//       utp._connectState = _UTPSocketConnectState.SYN_RECV; // 更改连接状态
//       utp._lastRemoteTimestamp = packageData.timestamp;
//       utp._sendRawData(ST_STATE);
//       return;
//     }
//   }
// }
