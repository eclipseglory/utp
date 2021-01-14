import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'utp_data.dart';
import 'utp_socket_recorder.dart';

const MAX_PACKET_SIZE = 1435;

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

    utp._connectState = UTPConnectState.SYN_SENT; //修改socket连接状态
    // 初始化send_id 和_receive_id
    utp.receiveId = Random().nextInt(MAX_UINT16); //初始一个随机的connection id
    utp.sendId = utp.receiveId + 1;
    utp.sendId &= MAX_UINT16; // 防止溢出
    utp.currentLocalSeq = 1; //初始化序列。序列从1开始
    utp.lastReceiveSeq = 0; // 这个设为0，起始是没有得到远程seq的
    utp.lastReceiveTime = 0;
    // 连接发起的时候conn id是receive id
    var connId = utp.receiveId;
    var packet = UTPPacket(ST_SYN, connId, getNowTime16(), 0, utp.maxWindowSize,
        utp.currentLocalSeq, utp.lastReceiveSeq);
    utp.sendPacket(packet, 0, true, true);
    recordUTPSocket(connId, utp);
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
      UTPPacket data;
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
      socket?.receiveError(e);
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
        UTPPacket data;
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
            newSocket: (socket) => recordUTPSocket(socket.connectionId, socket),
            onConnected: (socket) => _sc?.add(socket),
            lostPackage: (socket, seq) => dev.log('丢包:$seq'));
      }
    }, onDone: () {
      close('Remote/Local socket closed');
    }, onError: (e) {
      forEach((socket) {
        if (socket is _UTPSocket) socket?.receiveError(e);
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

  final Set<_UTPSocket> _socketStack = <_UTPSocket>{};

  bool get isFull => _socketStack.length >= max;

  bool get isNotFull => !isFull;

  RawDatagramSocket rawSocket;

  _RawSocketStack(this.rawSocket, this.max);

  bool add(_UTPSocket socket) {
    var old = isFull;
    var r = _socketStack.add(socket);
    if (r && old != isFull) {
      _fullStatusHandler.forEach((f) {
        f(this, isFull);
      });
    }
    return r;
  }

  bool remove(_UTPSocket socket) {
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

  void forEach(void Function(_UTPSocket socket) processor) {
    _socketStack.forEach(processor);
  }
}

abstract class UTPSocket {
  UTPConnectState _connectState;

  bool get isConnected => _connectState == UTPConnectState.CONNECTED;

  final RawDatagramSocket _socket;

  int get currentWindowSize;

  /// The connection id between this socket with remote socket
  int get connectionId;

  /// Another side socket internet address
  final InternetAddress remoteAddress;

  /// Another side socket internet port
  final int remotePort;

  /// Local internet address
  InternetAddress get address => _socket?.address;

  /// Local internet port
  int get port => _socket?.port;

  int maxWindowSize;

  /// [_socket] is a UDP socket instance.
  ///
  /// [remoteAddress] and [remotePort] is another side uTP address and port
  ///
  UTPSocket(this._socket, this.remoteAddress, this.remotePort,
      [this.maxWindowSize = 1048576]);

  /// Add data into the pipe to send to remote.
  ///
  /// Because the data was send by UDP , so each invoke this method , the socket need not to send
  /// the packet immeditelly, there are some rules :
  ///
  /// - 为了节约带宽，多次调用该方法如果在同一个Tick下，则会将每次发送的data添加入一个发送buffer中
  /// - 如果发送buffer达到了每个packet的最大限制，则会立即发送
  /// - 如果在同一个Tick下，没有更多的Add方法被调用，则会将发送buffer的数据一起打包发出
  void add(Uint8List data);

  /// When receive STATE message , ACK the ack_nr id
  ///
  /// This method should remove the send buffer data via the [seq].
  ///
  /// If the packet with sequence number (seq_nr - cur_window) has not been acked
  /// (this is the oldest packet in the send buffer, and the next one expected to be acked), but 3
  ///  or more packets have been acked past it (through Selective ACK), the packet is assumed to
  /// have been lost. Similarly, when receiving 3 duplicate acks, ack_nr + 1 is assumed to have
  /// been lost (if a packet with that sequence number has been sent).
  ///
  /// This is applied to selective acks as well. Each packet that is acked in the selective ack
  /// message counts as one duplicate ack, which, if it 3 or more, should trigger a re-send of
  /// packets that had at least 3 packets acked after them.
  ///
  /// When a packet is lost, the max_window is multiplied by 0.5 to mimic TCP.
  ///
  /// See : http://www.bittorrent.org/beps/bep_0029.html
  void remoteAcked(int seq);

  ///
  /// [onData] function is Listening the income datas handler.
  ///
  /// [onError] can catch the error happen receiving message , but some error will not
  /// notify via this method instead of closing this socket instance.
  StreamSubscription<Uint8List> listen(void Function(Uint8List datas) onData,
      {Function onError, void Function() onDone, bool cancelOnError});

  /// Close the socket.
  ///
  /// If socket is closed , it can't connect agian , if need to reconnect
  /// new a socket instance.
  Future<dynamic> close([dynamic reason]);

  /// If this socket was closed
  bool get isClosed;
}

/// UTP socket connection state.
enum UTPConnectState {
  /// UTP socket send then SYN message to another for connecting
  SYN_SENT,

  /// UTP socket receive a SYN message from another
  SYN_RECV,

  /// UTP socket was connected with another one.
  CONNECTED,

  /// UTP socket was closed
  CLOSED
}

class _UTPSocket extends UTPSocket {
  @override
  int get connectionId => receiveId;

  final int maxInflightPackets = 250;

  int sendId;

  int currentLocalSeq = 0;

  int lastReceiveSeq = 0;

  int lastRemoteAck;

  int lastReceiveTime;

  int remoteWndSize;

  int receiveId;

  final Map<int, UTPPacket> _inflightPackets = <int, UTPPacket>{};

  final Map<int, Timer> _resendTimer = <int, Timer>{};

  int _currentWindowSize = 0;

  final Map<int, Timer> _outTimeTimer = <int, Timer>{};

  @override
  int get currentWindowSize => _currentWindowSize;

  bool _closed = false;

  @override
  bool get isClosed => _closed;

  StreamController<Uint8List> _receiveDataStreamController;

  Timer _addDataTimer;

  final List<int> _sendingDataCache = <int>[];

  List<int> _sendingDataBuffer = <int>[];

  final StreamController<List<int>> _sendController =
      StreamController<List<int>>();

  StreamSubscription _sendSubcription;

  final Map<int, int> _duplicateAckCountMap = <int, int>{};

  _UTPSocket(RawDatagramSocket socket,
      [InternetAddress remoteAddress, int remotePort])
      : super(socket, remoteAddress, remotePort) {
    _receiveDataStreamController = StreamController<Uint8List>();
    _sendSubcription = _sendController.stream.listen(_newSendingData);
  }

  bool isInCurrentAckWindow(int seq) {
    var currentWindow = max(_inflightPackets.length + 3, 3);
    var ma = currentLocalSeq - 1;
    var min = ma - currentWindow;
    if (compareSeqLess(ma, seq) || compareSeqLess(seq, min)) {
      return false;
    }
    return true;
  }

  void _newSendingData(List<int> data) {
    if (data != null && data.isNotEmpty) _sendingDataBuffer.addAll(data);

    var window = min(maxWindowSize, remoteWndSize);
    var allowSize = window - _currentWindowSize;
    var packetSize = min(allowSize, MAX_PACKET_SIZE);
    if (packetSize <= 0 || _inflightPackets.length >= maxInflightPackets) {
      _sendSubcription.pause();
      return;
    } else {
      if (_sendingDataBuffer.length > packetSize) {
        var d = _sendingDataBuffer.sublist(0, packetSize);
        _sendingDataBuffer = _sendingDataBuffer.sublist(packetSize);
        var packet = UTPPacket(
            ST_DATA,
            sendId,
            getNowTime16(),
            lastReceiveTime - getNowTime16(),
            maxWindowSize,
            currentLocalSeq,
            lastReceiveSeq,
            payload: Uint8List.fromList(d));
        sendPacket(packet, currentLocalSeq);
        if (_sendingDataBuffer.isNotEmpty) {
          Future.sync(() => _newSendingData(null));
        }
      } else {
        var packet = UTPPacket.newData(sendId, currentLocalSeq, lastReceiveSeq,
            Uint8List.fromList(_sendingDataBuffer));
        _sendingDataBuffer.clear();
        sendPacket(packet, currentLocalSeq);
      }
    }
  }

  void receive(Uint8List data) {
    if (isClosed) throw 'Socket is closed';
    if (isConnected) _receiveDataStreamController?.add(data);
  }

  void receiveError(dynamic error) {
    if (isClosed) throw 'Socket is closed';
    if (isConnected) _receiveDataStreamController?.addError(error);
  }

  @override
  void add(Uint8List data) {
    if (isClosed) throw 'Socket is closed';
    if (isConnected && data != null && data.isNotEmpty) {
      _addDataTimer?.cancel();
      _sendingDataCache.addAll(data);
      if (_sendingDataCache.isEmpty) return;
      _addDataTimer = Timer(Duration.zero, () {
        var d = List<int>.from(_sendingDataCache);
        _sendingDataCache.clear();
        _sendController.add(d);
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
    _connectState = UTPConnectState.CLOSED;
    var re = await _receiveDataStreamController?.close();
    _receiveDataStreamController = null;
    _addDataTimer?.cancel();
    _sendingDataCache.clear();
    await _sendSubcription?.cancel();
    await _sendController?.close();
    return re;
  }

  /// 重发某个Packet
  void _resendPacket(int seq) {
    var packet = _inflightPackets[seq];
    if (packet == null) return;
    _resendTimer[seq]?.cancel();
    // 如果重发的packet记录着超时，取消它
    var timer = _outTimeTimer.remove(seq);
    timer?.cancel();
    _resendTimer[seq] = Timer(Duration.zero, () {
      print('重新发送 $seq');
      _currentWindowSize -= packet.length;
      _resendTimer.remove(seq);
      sendPacket(packet, 0, false, false);
    });
  }

  /// 确认收到某个Packet
  void _ackPacket(int seq) {
    var packet = _inflightPackets.remove(seq);
    var timer = _outTimeTimer.remove(seq);
    var resend = _resendTimer.remove(seq);
    resend?.cancel();
    timer?.cancel();
    if (packet != null) {
      _currentWindowSize -= packet.length;
    }
  }

  @override
  void remoteAcked(int ackSeq, [List<int> selectiveAck, bool count = false]) {
    if (isClosed || !isConnected) return;

    if (ackSeq > currentLocalSeq) return;
    if (_inflightPackets.isEmpty && _duplicateAckCountMap.isNotEmpty) {
      _duplicateAckCountMap.clear();
    }

    var acked = <int>[];
    acked.add(ackSeq);
    if (selectiveAck != null && selectiveAck.isNotEmpty) {
      acked.addAll(selectiveAck);
    }
    for (var i = 0; i < acked.length; i++) {
      _ackPacket(acked[i]);
    }

    if (count) {
      for (var i = 0; i < acked.length; i++) {
        var key = acked[i];
        if (_duplicateAckCountMap[key] == null) {
          _duplicateAckCountMap[key] = 1;
        } else {
          _duplicateAckCountMap[key] += 1;
          if (_duplicateAckCountMap[key] >= 3) {
            _duplicateAckCountMap.remove(key);
            if (i == acked.length - 1) {
              var left = ((currentLocalSeq - key) & MAX_UINT16) - 1;
              if (_inflightPackets.length == left) {
                // TODO debug"
                var r = [];
                for (var i = 0; i < left; i++) {
                  var seq = (i + 1 + key) & MAX_UINT16;
                  r.add(seq);
                  _resendPacket(seq);
                }
                print('超过3次收到$key，后续估计是连续包都丢了，全部重发 $r');
              } else {
                print('超过3次收到$key，重新发送 ${(key + 1) & MAX_UINT16}');
                _resendPacket((key + 1) & MAX_UINT16);
              }
            } else {
              var b = acked[i + 1];
              var c = ((b - key) & MAX_UINT16) - 1; // 两个Ack中间有几个
              if (c == 0) continue; // 没有就跳过
              var over = acked.length - i - 1; //这些没有Ack的包之后有多少包被Ack了
              var d = ((currentLocalSeq - b) & MAX_UINT16);
              // 超过这个数量就说明这些丢包了，要重发
              if (over >= min(3, d)) {
                // TODO debug"
                var r = [];
                for (var j = 0; j < c; j++) {
                  _resendPacket((key + j + 1) & MAX_UINT16);
                  r.add((key + j + 1) & MAX_UINT16);
                }
                print('超过3次收到$key，重新发送 ${r}');
              } else {
                print('超过3次收到$key，重新发送 ${(key + 1) & MAX_UINT16}');
                _resendPacket((key + 1) & MAX_UINT16);
              }
            }
          }
        }
      }
    }

    var sended = _inflightPackets.keys;
    var keys = List<int>.from(sended);
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i];
      if (compareSeqLess(ackSeq, key)) break;
      _ackPacket(key); //这才是真正确认了
    }
    var _useless = <int>[];
    _duplicateAckCountMap.keys.forEach((element) {
      if (compareSeqLess(element, ackSeq)) {
        _useless.add(element);
      }
    });
    _useless.forEach((element) {
      _duplicateAckCountMap.remove(element);
    });

    _newTimeOutTimer();
    _sendSubcription.resume();
  }

  void _newTimeOutTimer([int times = 0]) async {
    if (_inflightPackets.isEmpty) return;
    var key = _inflightPackets.keys.first;
    if (_outTimeTimer[key] != null) return;

    _outTimeTimer[key]?.cancel();
    var packet = _inflightPackets[key];
    if (packet == null) return;
    _outTimeTimer[key] = Timer(Duration(seconds: 3 * pow(2, times)), () async {
      if (times >= 5) {
        dev.log('发送消息错误，导致关闭', error: '发送消息超时', name: runtimeType.toString());
        await close();
        return;
      }
      print('超时 ${3 * pow(2, times)} , 发送：$key');
      _currentWindowSize -= packet.length;
      _outTimeTimer.remove(key);
      sendPacket(packet, ++times, false, false);
    });
  }

  void sendPacket(UTPPacket packet,
      [int times = 0, bool increase = true, bool save = true]) {
    if (isClosed || _socket == null) return;
    var len = packet.length;
    _currentWindowSize += len;
    var ack = lastReceiveSeq;
    // 按照包被创建时间来计算
    var diff = packet.timestamp - lastReceiveTime;
    if (packet.type == ST_STATE) {
      // ACK不修改当时的ack值
      ack = packet.ack_nr;
    }
    if (packet.type == ST_SYN) {
      diff = 0;
      ack = 0;
    }
    if (increase) {
      currentLocalSeq++;
      currentLocalSeq &= MAX_UINT16;
    }
    if (save) _inflightPackets[packet.seq_nr] = packet;

    if (packet.type == ST_DATA || packet.type == ST_SYN) {
      _newTimeOutTimer(times);
    }

    // var bytes = packet.getBytes(
    //     wndSize: maxWindowSize, timeDiff: diff, seq: seq, ack: ack);
    var bytes = packet.getBytes(timeDiff: diff);
    // print('发送包 ${packet.seq_nr} , ack : $ack , timeDiff : $diff');
    _socket?.send(bytes, remoteAddress, remotePort);
  }
}

dynamic _validatePackage(UTPPacket packageData, _UTPSocket receiver) {
  if (packageData.connectionId != receiver.receiveId) {
    return 'Connection id not match';
  }
  // if (packageData.seq_nr < receiver._lastReceiveSeq) {
  //   return 'Incorrect remote seq_nr';
  // }
  // if (packageData.ack_nr > receiver._currentLocalSeq) {
  //   return 'Incorrect remote ack_nr';
  // }
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
    UTPPacket packetData,
    _UTPSocket socket,
    {void Function(UTPSocket socket) onConnected,
    void Function(UTPSocket socket) newSocket,
    void Function(UTPSocket socket, dynamic error) onError,
    void Function(UTPSocket socket, List<int> seq) lostPackage}) {
  // print(
  //     '收到对方${TYPE_NAME[packetData.type]}包:seq_nr:${packetData.seq_nr} , ack_nr : ${packetData.ack_nr}');
  // if (packetData.dataExtension != null) print('有Extension');
  var receiveTime = getNowTime16();
  // ST_SYN:
  if (packetData.type == ST_SYN) {
    socket = _UTPSocket(rawSocket, remoteAddress, remotePort);
    // init receive_id and sent_id
    socket.receiveId = packetData.connectionId + 1;
    socket.sendId = packetData.connectionId; // 保证发送的conn id一致
    socket.currentLocalSeq = Random().nextInt(MAX_UINT16); // 随机seq
    socket._connectState = UTPConnectState.SYN_RECV; // 更改连接状态
    socket.lastReceiveSeq = packetData.seq_nr;
    socket.remoteWndSize = packetData.wnd_size;
    socket.lastReceiveTime = receiveTime;
    var ack = UTPPacket(ST_STATE, socket.sendId, receiveTime, 0,
        socket.maxWindowSize, socket.currentLocalSeq, packetData.seq_nr);
    socket.sendPacket(ack, 0, false, false);
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
    return;
  }

  var error = _validatePackage(packetData, socket);
  if (error != null) {
    Timer.run(() {
      socket.receiveError(error);
      if (onError != null) onError(socket, e);
    });
    return;
  }

  socket.remoteWndSize = packetData.wnd_size; // 更新对方的window size
  socket.lastReceiveTime = getNowTime16();
  // TODO debug:
  var selectiveStr = 'SelectiveACK : ';
  var selectiveAcks = <int>[];
  if (packetData.extensionList.isNotEmpty) {
    packetData.extensionList.forEach((ext) {
      if (ext.isUnKnownExtension) return;
      var s = ext as SelectiveACK;
      selectiveAcks.addAll(s.getAckeds());
      selectiveStr = '$selectiveStr${s.getAckeds()}';
    });
  }
  var expectRemotePacket = socket.lastReceiveSeq + 1;

  // print('期待远程包序号 $expectRemotePacket , 收到远程包序号：${packetData.seq_nr}');
  if (packetData.seq_nr > expectRemotePacket) {
    // TODO 远程丢包处理没做
    print('对方有丢包');
  } else {
    if (packetData.seq_nr == expectRemotePacket) {
      // 记录收到数据的seq：
      socket.lastReceiveSeq = packetData.seq_nr;
    }
  }
  print('Process : 确认收到包 ${packetData.ack_nr} , $selectiveStr');
  //ST_STATE:
  if (packetData.type == ST_STATE) {
    if (socket._connectState == UTPConnectState.SYN_SENT) {
      socket._connectState = UTPConnectState.CONNECTED;
      socket.lastReceiveSeq = packetData.seq_nr;
      socket.lastReceiveSeq--; // 第一次收到State，ack减1，否则无法跟libutp通讯
      socket.lastReceiveSeq &= MAX_UINT16;
      socket.remoteWndSize = packetData.wnd_size;
      if (onConnected != null) onConnected(socket);
    }
    if (socket._connectState == UTPConnectState.CONNECTED) {
      // socket.lastRemoteAck = packetData.ack_nr;
      socket.remoteAcked(packetData.ack_nr, selectiveAcks, true);
    }
    return;
  }
  // ST_DATA:
  if (packetData.type == ST_DATA) {
    if (packetData.payload == null) throw '收到数据解析错误,payload为空';
    var len = packetData.payload.length;
    if (socket.currentWindowSize + len > socket.maxWindowSize) {
      dev.log('Receive data size over window limit size , ignore it',
          name: 'utp_protocol_implement.dart');
      return;
    }

    // socket._sendState();
    // 远程第二次发送信息确认连接。这里一定要注意：libutp的实现中，第一次收到state消息返回的ack是减1的，这里要做一下判断
    if (socket._connectState == UTPConnectState.SYN_RECV &&
        socket.currentLocalSeq - 1 == packetData.ack_nr) {
      socket._connectState = UTPConnectState.CONNECTED;
      socket.remoteWndSize = packetData.wnd_size;
      if (onConnected != null) onConnected(socket);
    }
    // 已连接状态下收到数据后去掉header，把payload以事件发出
    if (socket._connectState == UTPConnectState.CONNECTED) {
      socket.remoteAcked(packetData.ack_nr, selectiveAcks);
      // TODO 这里要改进，不一定需要立即发送ACK，ACK消息优先级低于Data
      var ack = UTPPacket(
          ST_STATE,
          socket.sendId,
          receiveTime,
          receiveTime - socket.lastReceiveTime,
          socket.maxWindowSize,
          socket.currentLocalSeq,
          packetData.seq_nr);
      socket.sendPacket(ack, 0, false, false);
      if (packetData.payload == null || packetData.payload.isEmpty) {
        return;
      }
      var data = packetData.payload.sublist(packetData.offset);
      Timer.run(() => socket.receive(data));
      return;
    } else {
      var err = 'UTP socket is not connected, cant process ST_DATA';
      Timer.run(() {
        socket.receiveError(err);
        if (onError != null) onError(socket, err);
      });
    }
  }
  // ST_FIN:
  // TODO implement
  // ST_RESET:
  // TODO implement
}

// compare if lhs is less than rhs, taking wrapping
// into account. if lhs is close to UINT_MAX and rhs
// is close to 0, lhs is assumed to have wrapped and
// considered smaller
bool compareSeqLess(int left, int right) {
  // distance walking from lhs to rhs, downwards
  var dist_down = (left - right) & MAX_UINT16;
  // distance walking from lhs to rhs, upwards
  var dist_up = (right - left) & MAX_UINT16;

  // if the distance walking up is shorter, lhs
  // is less than rhs. If the distance walking down
  // is shorter, then rhs is less than lhs
  return dist_up < dist_down;
}
