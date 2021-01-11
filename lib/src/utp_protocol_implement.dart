import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'utp_data.dart';
import 'utp_socket_recorder.dart';

const MAX_PACKET_SIZE = 4;

///
///
class UTPSocketPool with UTPSocketRecorder {
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

  final Map<RawDatagramSocket, _RawSocketStack> _stackMap = {};

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
    var stack = _avalidateStack;
    RawDatagramSocket socket;
    if (stack == null) {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      stack = _RawSocketStack(socket, maxSockets);
      _stackMap[socket] = stack;
      stack.onFullStatus(_whenSocketStackFullChange);
      _notFullStack.add(stack);
      socket.listen((event) => _onData(socket, event),
          onDone: () => _onDone(socket), onError: (e) => _onError(socket, e));
    } else {
      socket = stack.rawSocket;
    }
    var utp = _UTPSocket(socket, remoteAddress, remotePort);
    stack.add(utp);
    var completer = Completer<UTPSocket>();
    _connectingSocketMap[utp] = completer;
    var id = utp._sendSYN(); // start to connect
    recordUTPSocket(id, utp);
    return completer.future;
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
      if (datagram == null) return;
      var address = datagram.address;
      var port = datagram.port;
      UTPData data;
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
      Completer<UTPSocket> completer;
      if (utp != null) completer = _connectingSocketMap.remove(utp);
      _processReceiveData(utp._socket, address, port, data, utp,
          onConnected: (socket) => completer?.complete(socket),
          onError: (socket, error) => completer?.completeError(error),
          lostPackage: (socket, seq) => dev.log('丢包:$seq'));
    }
  }

  void _onDone(RawDatagramSocket source) async {
    var stack = _stackMap.remove(source);
    await stack?.dispose();
  }

  void _onError(RawDatagramSocket source, dynamic e) {
    var stack = _stackMap[source];
    stack?.forEach((socket) {
      socket?._receiveError(e);
    });
  }

  void _forEachStack(void Function(_RawSocketStack stack) processer) {
    _fullStack.forEach((stack) {
      if (processer != null) processer(stack);
    });

    _notFullStack.forEach((stack) {
      if (processer != null) processer(stack);
    });
  }

  Future dispose([dynamic reason]) async {
    if (isDisposed) return;
    _disposed = true;
    clean();
    _fullStack.clear();
    _notFullStack.clear();
    for (var i = 0; i < _stackMap.values.length; i++) {
      var stack = _stackMap.values.elementAt(i);
      stack.offFullStatus(_whenSocketStackFullChange);
      await stack.dispose();
    }
    _stackMap.clear();

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

  static Future<ServerUTPSocket> bind(dynamic host, [int port = 0]) async {
    var _socket = await RawDatagramSocket.bind(host, port);
    return _ServerUTPSocket(_socket);
  }
}

class _ServerUTPSocket extends ServerUTPSocket with UTPSocketRecorder {
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
        var address = datagram.address;
        var port = datagram.port;
        UTPData data;
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
        _processReceiveData(_socket, address, port, data, utp,
            newSocket: (socket) => recordUTPSocket(socket._receiveId, socket),
            onConnected: (socket) => _sc?.add(socket),
            lostPackage: (socket, seq) => dev.log('丢包:$seq'));
      }
    }, onDone: () {
      close('Remote/Local socket closed');
    }, onError: (e) {
      forEach((socket) {
        socket?._receiveError(e);
      });
    });
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

  bool get isFull => _socketStack.length >= max;

  bool get isNotFull => !isFull;

  RawDatagramSocket rawSocket;

  _RawSocketStack(this.rawSocket, this.max);

  bool add(UTPSocket socket) {
    var old = isFull;
    var r = _socketStack.add(socket);
    if (r && old != isFull) {
      _fullStatusHandler.forEach((f) {
        f(this, isFull);
      });
    }
    return r;
  }

  bool remove(UTPSocket socket) {
    var old = isFull;
    var r = _socketStack.remove(socket);
    if (r && old != isFull) {
      _fullStatusHandler.forEach((f) {
        f(this, isFull);
      });
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
  }

  void forEach(void Function(UTPSocket socket) processor) {
    _socketStack.forEach(processor);
  }
}

abstract class UTPSocket {
  _UTPSocketConnectState _connectState;

  bool get isConnected =>
      _connectState != null &&
      _connectState == _UTPSocketConnectState.CONNECTED;

  final RawDatagramSocket _socket;

  int _currentSeq;

  int _lastRemoteAck;

  int _lastDelay = 0;

  int _receiveId;

  int get connectionId => _receiveId;

  int _sendId;

  InternetAddress remoteAddress;

  int remotePort;

  InternetAddress get address => _socket?.address;

  int get port => _socket?.port;

  int maxWindow;

  int _remoteWndSize;

  UTPSocket(this._socket, this.remoteAddress, this.remotePort,
      [this.maxWindow = 1048576]);

  void _receive(Uint8List data);

  void _receiveError(dynamic error);

  /// Add data into the pipe to send to remote.
  ///
  /// Because the data was send by UDP , so each invoke this method , the socket need not to send
  /// the packet immeditelly, there are some rules :
  ///
  /// - 为了节约带宽，多次调用该方法如果在同一个Tick下，则会将每次发送的data添加入一个发送buffer中
  /// - 如果发送buffer达到了每个packet的最大限制，则会立即发送
  /// - 如果在同一个Tick下，没有更多的Add方法被调用，则会将发送buffer的数据一起打包发出
  void add(Uint8List data);

  void acked(int seq);

  /// Send SYN to remote to connect.
  ///
  /// This method will init connection id, seq_nr values.
  int _sendSYN();

  void _sendState();

  void _sendData(List<int> data);

  void _sendRawPacket(int type,
      {int connectionId,
      Uint8List payload,
      int seq,
      bool increaseSeq = true,
      bool save = true});

  StreamSubscription<Uint8List> listen(void Function(Uint8List datas) onData,
      {Function onError, void Function() onDone, bool cancelOnError});

  Future<dynamic> close([dynamic reason]);

  bool get isClosed;
}

enum _UTPSocketConnectState { SYN_SENT, SYN_RECV, CONNECTED, CLOSED }

// TODO TEST
const TYPE_NAME = {
  ST_STATE: 'ACK',
  ST_DATA: 'Data',
  ST_SYN: 'SYN',
};

class _UTPSocket extends UTPSocket {
  Timer _resendTimer;

  int _currentSendSeq;

  // int _lastLocalAck;

  bool _closed = false;

  final Map<int, dynamic> _sentBuffer = {};

  @override
  bool get isClosed => _closed;

  StreamController<Uint8List> _receiveDataStreamController;

  List<int> _sendingBuffer = <int>[];

  final StreamController<Uint8List> _sendController =
      StreamController<Uint8List>();

  StreamSubscription _sendSubcription;

  _UTPSocket(RawDatagramSocket socket,
      [InternetAddress remoteAddress, int remotePort])
      : super(socket, remoteAddress, remotePort) {
    _receiveDataStreamController = StreamController<Uint8List>();
    _sendSubcription = _sendController.stream.listen(_newSendPacket);
  }

  void _newSendPacket(Uint8List data) {
    _sendSubcription.pause();
    // print('发送Data给对方 , seq:$_currentSeq , ack:$_lastRemoteAck');
    _currentSendSeq = _currentSeq;
    _resendData(data, 0);
  }

  void _resendData(Uint8List data, int times,
      [bool increase = true, bool save = true]) async {
    if (times >= 5) {
      dev.log('发送消息错误，导致关闭', error: '发送消息超时', name: runtimeType.toString());
      await close();
      return;
    }
    _sendRawPacket(ST_DATA,
        payload: data, seq: _currentSendSeq, increaseSeq: increase, save: save);
    _resendTimer = Timer(Duration(seconds: 3 * pow(2, times)), () {
      // print('超时，重新发送 $_currentSendSeq');
      _resendData(data, ++times, false, true);
    });
  }

  @override
  void _receive(Uint8List data) {
    if (isClosed) throw 'Socket is closed';
    if (isConnected) _receiveDataStreamController?.add(data);
  }

  @override
  void _receiveError(dynamic error) {
    if (isClosed) throw 'Socket is closed';
    if (isConnected) _receiveDataStreamController?.addError(error);
  }

  // 这是专门用来控制发送Data的StreamSubcription，用于模拟cancel某个Future。
  StreamSubscription _dataFutureController;

  @override
  void add(Uint8List data) {
    if (isClosed) throw 'Socket is closed';
    if (isConnected) {
      _dataFutureController?.cancel();
      _sendingBuffer.addAll(data);
      if (_sendingBuffer.length >= MAX_PACKET_SIZE) {
        var temp = _sendingBuffer.sublist(0, MAX_PACKET_SIZE);
        _sendingBuffer = _sendingBuffer.sublist(MAX_PACKET_SIZE);
        Timer.run(() => _sendData(temp));
        if (_sendingBuffer.isEmpty) return;
      }
      _dataFutureController = Future.sync(() {
        return _sendingBuffer;
      }).asStream().listen((data) {
        _dataFutureController?.cancel();
        _dataFutureController = null;
        Timer.run(() {
          _sendData(data);
          _sendingBuffer.clear();
        });
      });
    }
  }

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List data) onData,
      {Function onError, void Function() onDone, bool cancelOnError}) {
    if (isClosed) throw 'Socket is closed';
    return _receiveDataStreamController?.stream?.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  Future<dynamic> close([dynamic reason]) async {
    if (isClosed) return;
    _closed = true;
    _connectState = _UTPSocketConnectState.CLOSED;
    var re = await _receiveDataStreamController?.close();
    _receiveDataStreamController = null;
    _sentBuffer.clear();

    _resendTimer?.cancel();
    _resendTimer = null;
    _sendingBuffer.clear();
    await _sendSubcription?.cancel();
    await _sendController?.close();
    return re;
  }

  @override
  void _sendRawPacket(int type,
      {int connectionId,
      Uint8List payload,
      int seq,
      bool increaseSeq = true,
      bool save = true}) async {
    if (_socket == null) throw 'Raw UDP socket is null';
    if (isClosed) throw 'Socket is closed';

    connectionId ??= _sendId;
    seq ??= _currentSeq;
    var sd = createData(type, connectionId, getNowTime32(), _lastDelay,
        maxWindow, seq, _lastRemoteAck,
        payload: payload);
    if (save) _sentBuffer[seq] = sd;
    if (increaseSeq) {
      _currentSeq++;
      _currentSeq &= MAX_UINT16;
    }
    _socket?.send(sd, remoteAddress, remotePort);
  }

  @override
  void acked(int seq) {
    if (isClosed) {
      throw 'Socket is closed';
    }
    if (!isConnected) throw 'Socket is not connected';
    // print('对方收到包$seq');
    if (seq == _currentSendSeq) {
      _resendTimer?.cancel();
      _resendTimer = null;
      // print('对方确认收到包 $_currentSendSeq，恢复发送');
      _sendSubcription.resume();
    }
    _sentBuffer.remove(seq);
  }

  @override
  void _sendData(List<int> data) {
    if (data.isEmpty) return;
    // print('准备发送Data给对方,seq:$_currentSeq , ack:$_lastRemoteAck');
    _sendController.add(Uint8List.fromList(data));
  }

  @override
  int _sendSYN() {
    _connectState = _UTPSocketConnectState.SYN_SENT; //修改socket连接状态
    // 初始化send_id 和_receive_id
    _receiveId = Random().nextInt(MAX_UINT16); //初始一个随机的connection id
    _sendId = _receiveId + 1;
    _sendId &= MAX_UINT16; // 防止溢出
    _currentSeq = Random().nextInt(MAX_UINT16); //初始化序列。序列从1开始
    _lastDelay = 0; // 第一次没有延迟
    _lastRemoteAck = 0; // 这个设为0，起始是没有得到远程seq的
    // 连接发起的时候conn id是receive id
    var connId = _receiveId;
    // print('发送SYN给对方,seq:$_currentSeq, ack:$_lastRemoteAck');
    _sendRawPacket(ST_SYN, connectionId: connId);
    return connId;
  }

  @override
  void _sendState() {
    // print('发送ACK给对方,seq_nr:$_currentSeq ack_nr : ${_lastRemoteAck}');
    _sendRawPacket(ST_STATE, increaseSeq: false, save: false);
  }
}

dynamic _validatePackage(UTPData packageData, UTPSocket receiver) {
  if (packageData.connectionId != receiver._receiveId) {
    return 'Connection id not match';
  }
  return null;
}

///
/// uTP protocol receive data process
///
/// Include init connection and other type data process , both of Server socket and client socket
void _processReceiveData(
    RawDatagramSocket rawSocket,
    InternetAddress remoteAddress,
    int remotePort,
    UTPData packetData,
    UTPSocket socket,
    {void Function(UTPSocket socket) onConnected,
    void Function(UTPSocket socket) newSocket,
    void Function(UTPSocket socket, dynamic error) onError,
    void Function(UTPSocket socket, List<int> seq) lostPackage}) {
  // print(
  //     '收到对方${TYPE_NAME[packetData.type]}包:seq_nr:${packetData.seq_nr} , ack_nr : ${packetData.ack_nr}');
  // if (packetData.dataExtension != null) print('有Extension');
  // ST_SYN:
  if (packetData.type == ST_SYN) {
    // 远程发起连接, 流程和普通数据传送不太一样，单独处理
    socket = _UTPSocket(rawSocket, remoteAddress, remotePort);
    // init receive_id and sent_id
    socket._receiveId = packetData.connectionId + 1;
    socket._sendId = packetData.connectionId; // 保证发送的conn id一致
    socket._currentSeq = Random().nextInt(65535); // 随机seq
    socket._connectState = _UTPSocketConnectState.SYN_RECV; // 更改连接状态
    socket._lastDelay = getNowTime32() - packetData.timestamp;
    socket._lastRemoteAck = packetData.seq_nr;
    socket._sendState();
    socket._currentSeq &= MAX_UINT16;
    if (newSocket != null) newSocket(socket);
    return;
  }
  if (socket == null) {
    dev.log('Receive data error', error: 'no socket');
    return;
  }
  if (socket.isClosed) {
    var err = 'Socket closed can not process receive data';
    if (onError != null) onError(socket, err);
    dev.log('Process receive data error :',
        error: err, name: 'utp_socket.dart');
    return;
  }

  var error = _validatePackage(packetData, socket);
  if (error != null) {
    Timer.run(() {
      socket._receiveError(error);
      if (onError != null) onError(socket, e);
    });
    dev.log('Remote connect error:', error: error, name: 'utp_socket.dart');
    return;
  }

  socket._lastDelay = getNowTime32() - packetData.timestamp;
  //ST_STATE:
  if (packetData.type == ST_STATE) {
    if (socket._connectState == _UTPSocketConnectState.SYN_SENT) {
      socket._connectState = _UTPSocketConnectState.CONNECTED;
      socket._lastRemoteAck =
          packetData.seq_nr - 1; // 第一次收到State，ack减1，否则无法跟libutp通讯
      socket._lastRemoteAck &= MAX_UINT16;
      socket._remoteWndSize = packetData.wnd_size;
      if (onConnected != null) onConnected(socket);
    }
    if (socket._connectState == _UTPSocketConnectState.CONNECTED) {
      if (socket._currentSeq - 1 != packetData.ack_nr) {
        // print('丢包？？？ ${socket._currentSeq}');
      }
      socket.acked(packetData.ack_nr);
    }
    return;
  }
  // ST_DATA:
  if (packetData.type == ST_DATA) {
    // 记录收到数据的seq：
    socket._lastRemoteAck = packetData.seq_nr; // 第一次收到State，ack减1，否则无法跟libutp通讯
    socket._sendState();
    // 远程第二次发送信息确认连接。这里一定要注意：libutp的实现中，第一次收到state消息返回的ack是减1的，这里要做一下判断
    if (socket._connectState == _UTPSocketConnectState.SYN_RECV &&
        socket._currentSeq - 1 == packetData.ack_nr) {
      socket._connectState = _UTPSocketConnectState.CONNECTED;
      socket._remoteWndSize = packetData.wnd_size;
      if (onConnected != null) onConnected(socket);
    }
    // 已连接状态下收到数据后去掉header，把payload以事件发出
    if (socket._connectState == _UTPSocketConnectState.CONNECTED) {
      if (packetData.payload == null || packetData.payload.isEmpty) {
        return;
      }
      var data = packetData.payload.sublist(packetData.offset);
      Timer.run(() => socket._receive(data));
      return;
    } else {
      var err = 'UTP socket is not connected, cant process ST_DATA';
      Timer.run(() {
        socket._receiveError(err);
        if (onError != null) onError(socket, err);
      });
      dev.log('process receive data error:',
          error: err, name: 'utp_socket.dart');
    }
  }

  // ST_FIN:
  // TODO implement
  // ST_RESET:
  // TODO implement
}

int getNowTime32() {
  return DateTime.now().millisecondsSinceEpoch & MAX_UINT32;
}
