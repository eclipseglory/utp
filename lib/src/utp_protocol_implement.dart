import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'utp_data.dart';

const MAX_PACKET_SIZE = 1382;

const MIN_PACKET_SIZE = 150;

///
/// UTP socket client.
///
/// This class can connect remote UTP socket. One UTPSocketClient
/// can create multiple UTPSocket.
///
/// See also [ServerUTPSocket]
class UTPSocketClient extends _UTPCloseHandler with UTPSocketRecorder {
  bool _closed = false;

  /// 是否已被销毁
  bool get isClosed => _closed;

  /// Each UDP socket can handler max connections
  final int maxSockets;

  RawDatagramSocket _rawSocket;

  UTPSocketClient([this.maxSockets = 10]);

  InternetAddress address;

  final Map<int, Completer<UTPSocket>> _connectingSocketMap = {};

  /// Connect remote UTP server socket.
  ///
  /// If [remoteAddress] and [remotePort] related socket was connectted already ,
  /// it will return a `Future` with `UTPSocket` instance directly;
  ///
  /// or this method will try to create a new `UTPSocket` instance to connect remote,
  /// once connect succesffully , the return `Future` will complete with the instance ,
  /// if connect fail , the `Future` will complete with an exception.
  Future<UTPSocket> connect(InternetAddress remoteAddress, int remotePort,
      [int localPort = 0]) async {
    assert(remotePort != null && remoteAddress != null,
        'Address and port can not be null');
    if (indexMap.length >= maxSockets) return null;
    if (_rawSocket == null) {
      _rawSocket =
          await RawDatagramSocket.bind(InternetAddress.anyIPv4, localPort);
      _rawSocket.listen((event) => _onData(event),
          onDone: () => _onDone(), onError: (e) => _onError(e));
    }

    var connId = Random().nextInt(MAX_UINT16);
    var utp = _UTPSocket(connId, _rawSocket, remoteAddress, remotePort);
    var completer = Completer<UTPSocket>();
    _connectingSocketMap[connId] = completer;

    utp.connectionState = UTPConnectState.SYN_SENT; //修改socket连接状态
    // 初始化send_id 和_receive_id
    utp.receiveId = connId; //初始一个随机的connection id
    utp.sendId = (utp.receiveId + 1) & MAX_UINT16;
    utp.sendId &= MAX_UINT16; // 防止溢出
    utp.currentLocalSeq = Random().nextInt(MAX_UINT16); // 随机一个seq;
    utp.lastRemoteSeq = 0; // 这个设为0，起始是没有得到远程seq的
    utp.lastRemotePktTimestamp = 0;
    var packet = UTPPacket(ST_SYN, connId, 0, 0, utp.maxWindowSize,
        utp.currentLocalSeq, utp.lastRemoteSeq);
    utp.sendPacket(packet, 0, true, true);
    recordUTPSocket(connId, utp);
    return completer.future;
  }

  void _onData(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      var datagram = _rawSocket.receive();
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
      if (utp != null) completer = _connectingSocketMap.remove(connId);
      _processReceiveData(utp._socket, address, port, data, utp,
          onConnected: (socket) => completer?.complete(socket),
          onError: (socket, error) => completer?.completeError(error));
    }
  }

  void _onDone() async {
    await close('远程/本地关闭连接');
  }

  void _onError(dynamic e) {
    dev.log('UDP socket error:', error: e, name: runtimeType.toString());
  }

  /// Close the raw UDP socket and all UTP sockets
  Future close([dynamic reason]) async {
    if (isClosed) return;
    _closed = true;
    var f = <Future>[];
    indexMap.forEach((key, socket) {
      f.add(socket?.close());
    });
    clean();

    _connectingSocketMap.forEach((key, c) {
      if (c != null && !c.isCompleted) {
        c.completeError('Socket was disposed');
      }
    });
    _connectingSocketMap.clear();
    return Stream.fromFutures(f).toList();
  }

  @override
  void socketClosed(_UTPSocket socket) {
    var s = removeUTPSocket(socket.connectionId);
    if (s != null) {
      dev.log('UTPSocket(id:${socket.connectionId}) is closed , remove it');
    }
  }
}

///
/// This class will create a UTP socket to listening income UTP socket.
///
/// See also [UTPSocketClient]
abstract class ServerUTPSocket extends _UTPCloseHandler {
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
        _processReceiveData(_socket, address, port, data, utp,
            newSocket: (socket) {
              recordUTPSocket(socket.connectionId, socket);
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

  @override
  void socketClosed(_UTPSocket socket) {
    var s = removeUTPSocket(socket.connectionId);
    if (s != null) {
      dev.log('UTPSocket(id:${socket.connectionId}) is closed , remove it');
    }
  }
}

///
/// Record uTP socket with its remote address and remote port.
///
/// This mixin provide some methods to record/find/remove uTP socket
/// instance.
///
/// This mixin use two simple `Map` to record the socket instance currentlly
mixin UTPSocketRecorder {
  final Map<int, _UTPSocket> indexMap = {};

  /// Get the `UTPSocket` via [connectionId]
  ///
  /// If not found , return `null`
  _UTPSocket findUTPSocket(int connectionId) {
    return indexMap[connectionId];
  }

  /// Record the `UTPSocket` via [connectionId]
  ///
  /// If it have a instance already , it will replace it with the new instance
  void recordUTPSocket(int connectionId, _UTPSocket s) {
    indexMap[connectionId] = s;
  }

  _UTPSocket removeUTPSocket(int connectionId) {
    return indexMap.remove(connectionId);
  }

  /// For each
  void forEach(void Function(UTPSocket socket) processer) {
    indexMap.forEach((key, value) {
      processer(value);
    });
  }

  /// clean the record map
  void clean() {
    indexMap.clear();
  }
}

/// UTP socket
///
/// More details please take a look : [UTP Micro_Transport_Protocol](http://en.wikipedia.org/wiki/Micro_Transport_Protocol)
abstract class UTPSocket {
  /// Is UTP socket connected to remote
  bool get isConnected;

  /// 这是用于通讯的真正的UDP socket
  final RawDatagramSocket _socket;

  /// The connection id between this socket with remote socket
  final int connectionId;

  /// Another side socket internet address
  final InternetAddress remoteAddress;

  /// Another side socket internet port
  final int remotePort;

  /// Local internet address
  InternetAddress get address => _socket?.address;

  /// Local internet port
  int get port => _socket?.port;

  /// The max window size. ready-only
  final int maxWindowSize;

  /// [_socket] is a UDP socket instance.
  ///
  /// [remoteAddress] and [remotePort] is another side uTP address and port
  ///
  UTPSocket(
      this.connectionId, this._socket, this.remoteAddress, this.remotePort,
      [this.maxWindowSize = 1048576]);

  /// Add data into the pipe to send to remote.
  void add(Uint8List data);

  void addError(dynamic error, [StackTrace stackTrace]);

  ///
  /// [onData] function is Listening the income datas handler.
  ///
  /// [onDone] will invoke when the socket was closed.
  ///
  /// [onError] can catch the error happen receiving message , but some error will not
  /// notify via this method instead of closing this socket instance.
  ///
  /// If [cancelOnError] is `true` , once the socket get an error , it will not receive other
  /// event or error anymore.
  StreamSubscription<Uint8List> listen(void Function(Uint8List datas) onData,
      {Function onError, void Function() onDone, bool cancelOnError});

  /// Close the socket.
  ///
  /// If socket is closed , it can't connect agian , if need to reconnect
  /// new a socket instance.
  Future<dynamic> close([dynamic reason]);

  /// This socket was closed no not
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
  CLOSED,

  /// UTP socket is closing
  CLOSING
}

const _Type2Map = {2: 'ACK', 0: 'Data', 4: 'SYN', 3: 'Reset', 1: 'FIN'};

abstract class _UTPCloseHandler {
  void socketClosed(_UTPSocket socket);
}

class _UTPSocket extends UTPSocket {
  @override
  bool get isConnected => connectionState == UTPConnectState.CONNECTED;

  UTPConnectState connectionState;

  int _timeoutCounterTime = 1000;

  int _packetSize = MIN_PACKET_SIZE;

  final int maxInflightPackets = 2;

  double _rtt = 0.0;

  double _rtt_var = 800.0;

  int sendId;

  int _currentLocalSeq = 0;

  /// Make sure the num dont over max uint16
  int _getUint16Int(int v) {
    if (v != null) {
      v = v & MAX_UINT16;
    }
    return v;
  }

  /// The next Packet seq number
  int get currentLocalSeq => _currentLocalSeq;

  set currentLocalSeq(v) => _currentLocalSeq = _getUint16Int(v);

  int _lastRemoteSeq = 0;

  /// The last receive remote packet seq number
  int get lastRemoteSeq => _lastRemoteSeq;

  set lastRemoteSeq(v) => _lastRemoteSeq = _getUint16Int(v);

  int _lastRemoteAck;

  int _FINSeq;

  Timer _FINTimer;

  /// The last packet remote acked.
  int get lastRemoteAck => _lastRemoteAck;

  set lastRemoteAck(v) => _lastRemoteAck = _getUint16Int(v);

  /// The timestamp when receive the last remote packet
  int lastRemotePktTimestamp;

  int remoteWndSize;

  int receiveId;

  final Map<int, UTPPacket> _inflightPackets = <int, UTPPacket>{};

  final Map<int, Timer> _resendTimer = <int, Timer>{};

  int _currentWindowSize = 0;

  Timer _outTimer;

  bool _closed = false;

  @override
  bool get isClosed => _closed;

  /// 正在关闭
  bool get isClosing => connectionState == UTPConnectState.CLOSING;

  StreamController<Uint8List> _receiveDataStreamController;

  final List<UTPPacket> _receivePacketBuffer = <UTPPacket>[];

  Timer _addDataTimer;

  final List<int> _sendingDataCache = <int>[];

  List<int> _sendingDataBuffer = <int>[];

  final Map<int, int> _duplicateAckCountMap = <int, int>{};

  final Map<int, Timer> _requestSendAckMap = <int, Timer>{};

  Timer _keepAliveTimer;

  int _startTimeOffset;

  int _allowWindowSize;

  _UTPCloseHandler _handler;

  set closeHandler(_UTPCloseHandler h) {
    _handler = h;
  }

  _UTPSocket(int connectionId, RawDatagramSocket socket,
      [InternetAddress remoteAddress, int remotePort, int maxWindow = 1048576])
      : super(connectionId, socket, remoteAddress, remotePort, maxWindow) {
    _allowWindowSize = MIN_PACKET_SIZE; // _packetSize * 2;
    _packetSize = MIN_PACKET_SIZE;
    _receiveDataStreamController = StreamController<Uint8List>();
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

  /// socket每次连接成功后或者发送/接收任何消息（keepalive消息除外），都会定义一个延时30秒的Timer。
  ///
  /// Timer触发就会发送一次ST_STATE 消息，seq_nr为下一次发送seq，ack_nr为最后一次收到的远程seq-1
  void startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer(Duration(seconds: 30), () {
      var ack = 0;
      if (_lastRemoteSeq != null) ack = (_lastRemoteSeq - 1) & MAX_UINT16;
      var packet = UTPPacket(
          ST_STATE, sendId, 0, 0, maxWindowSize, currentLocalSeq, ack);
      sendPacket(packet, 0, false, false);
    });
  }

  /// 发送数据会通过该方法进入
  ///
  void _requestSendData([List<int> data]) {
    if (data != null && data.isNotEmpty) _sendingDataBuffer.addAll(data);
    if (_sendingDataBuffer.isEmpty) return;
    var window = min(_allowWindowSize, remoteWndSize);
    var allowSize = window - _currentWindowSize;
    var packetSize = min(allowSize, _packetSize);
    if (packetSize <= 0) {
      return;
    } else {
      if (_sendingDataBuffer.length > packetSize) {
        var d = _sendingDataBuffer.sublist(0, packetSize);
        _sendingDataBuffer = _sendingDataBuffer.sublist(packetSize);
        var packet = newDataPacket(Uint8List.fromList(d));
        d.clear();
        d = null;
        sendPacket(packet);
      } else {
        var packet = newDataPacket(Uint8List.fromList(_sendingDataBuffer));
        _sendingDataBuffer.clear();
        sendPacket(packet);
      }
      Timer.run(() => _requestSendData());
    }
  }

  @override
  void addError(dynamic error, [StackTrace stackTrace]) {
    if (isClosed) throw 'Socket is closed';
    if (isConnected) _receiveDataStreamController?.addError(error, stackTrace);
  }

  @override
  void add(Uint8List data) {
    if (isClosed || connectionState == UTPConnectState.CLOSING) return;
    if (isConnected && data != null && data.isNotEmpty) {
      _addDataTimer?.cancel();
      _sendingDataCache.addAll(data);
      if (_sendingDataCache.isEmpty) return;
      _addDataTimer = Timer(Duration.zero, () {
        var d = List<int>.from(_sendingDataCache);
        _sendingDataCache.clear();
        Timer.run(() => _requestSendData(d));
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
    await _sendFIN();
    closeForce();
  }

  /// 重发某个Packet
  void _resendPacket(int seq, [int times = 0]) {
    var packet = _inflightPackets[seq];
    if (packet == null) return _resendTimer.remove(seq)?.cancel();

    _resendTimer.remove(seq)?.cancel();
    _resendTimer[seq] = Timer(Duration.zero, () {
      // print('重新发送 $seq');
      _currentWindowSize -= packet.length;
      _resendTimer.remove(seq);
      sendPacket(packet, times, false, false);
    });
  }

  /// 更新超时时间
  ///
  /// 该计算公式请查阅BEP00029规范
  void _caculateTimeoutTime(UTPPacket packet) {
    var packetRtt = getNowTimestamp(_startTimeOffset) - packet.sendTime;
    var packetRttD = packetRtt / 1000;
    var delta = (_rtt - packetRttD).abs();
    _rtt_var += (delta - _rtt_var) / 4;
    _rtt += (packetRttD - _rtt) / 8;
    var td = max(_rtt + _rtt_var * 4, 500.0);
    _timeoutCounterTime = td.floor(); //(_rtt + _rtt_var * 4, 500);

    var len = packet.length;
    if (len != 0 && packetRtt != 0) {
      var speed = MIN_PACKET_SIZE / packetRttD;
      var maybe = speed * td;
      var mf = maybe.floor();
      _allowWindowSize = mf;
      _allowWindowSize = min(_allowWindowSize, maxWindowSize);
      _packetSize = mf;
      _packetSize = min(_packetSize, MAX_PACKET_SIZE);
    }
  }

  /// 确认收到某个Packet
  ///
  /// 如果该Packet已经被acked，返回false，否则返回true
  bool _ackPacket(int seq) {
    var packet = _inflightPackets.remove(seq);
    var resend = _resendTimer.remove(seq);
    resend?.cancel();
    if (packet != null) {
      _caculateTimeoutTime(packet);
      _currentWindowSize -= packet.length;
      return true;
    }
    return false;
  }

  ///
  ///
  /// 该方法根据[BEP0029 协议规范](http://www.bittorrent.org/beps/bep_0029.html)实现，但做出了改动。
  ///
  /// 每次对方确认收到某序列号的数据包后（对于STATE和DATA类型都适用）， 会根据该序列号和已经发送的包进行比较。 如果此[ackSeq]是在确认范围内，
  /// 即 <= seq_nr ，且 >= last_seq_nr，则认为该[ackSeq]有效。
  ///
  /// 对于有效[ackSeq]，会查看发送队列中的数据包，并清除所有小于等于该[ackSeq]的数据包(因为对方已经表示确认收到了)。
  ///
  /// 重复收到[ackSeq]，或者[selectiveAck]中的序列号重复收到，当[count]值为`true`的时候会进行计数(仅对STATE类型的ack_nr进行计数)，
  /// 当某seq重复次数超过3次：
  ///
  /// - 如果该序列号往前的包已经有超过3个被确认收到(*如果该序列号是最后几个发送的，那它的前几个可能不会有3个，则会降低该阈值*)，
  /// 则该序列号和它往前以及往后最近的已确认收到的序列号中间所有的包会被认为已经丢包。
  /// - 如果没有发生上述的情况，则认为该确认[ackSeq] + 1丢包。
  ///
  /// 然后该计数会重置， 丢包的数据会立即重发。
  ///
  void remoteAcked(int ackSeq, [List<int> selectiveAck, bool count = false]) {
    if (isClosed || !isConnected || isClosing) return;
    if (ackSeq > currentLocalSeq || _inflightPackets.isEmpty) return;
    var newSeqAcked = false;
    var acked = <int>[];
    lastRemoteAck = ackSeq;
    acked.add(ackSeq);
    if (selectiveAck != null && selectiveAck.isNotEmpty) {
      acked.addAll(selectiveAck);
    }
    for (var i = 0; i < acked.length; i++) {
      // 愚蠢，短路了都没看出来  :
      // newSeqAcked = newSeqAcked || _ackPacket(acked[i]);
      newSeqAcked = _ackPacket(acked[i]) || newSeqAcked;
    }

    var hasLost = false;

    if (count) {
      var lostPackets = <int>{};
      for (var i = 0; i < acked.length; i++) {
        var key = acked[i];
        if (_duplicateAckCountMap[key] == null) {
          _duplicateAckCountMap[key] = 1;
        } else {
          _duplicateAckCountMap[key]++;
          if (_duplicateAckCountMap[key] >= 3) {
            _duplicateAckCountMap.remove(key);
            // print('$key 重复ack超过3($oldcount)次，计算丢包');
            var over = acked.length - i - 1;
            var limit = ((currentLocalSeq - 1 - key) & MAX_UINT16);
            limit = min(3, limit);
            if (over >= limit) {
              var nextIndex = i + 1;
              var preIndex = i - 1;
              if (nextIndex < acked.length) {
                var c =
                    ((acked[nextIndex] - key) & MAX_UINT16) - 1; // 两个Ack中间有几个
                for (var j = 0; j < c; j++) {
                  lostPackets.add((key + j + 1) & MAX_UINT16);
                }
              }
              if (preIndex >= 0) {
                var c =
                    ((key - acked[preIndex]) & MAX_UINT16) - 1; // 两个Ack中间有几个
                for (var j = 0; j < c; j++) {
                  lostPackets.add((acked[preIndex] + j + 1) & MAX_UINT16);
                }
              }
            } else {
              var next = (key + 1) & MAX_UINT16;
              if (next < currentLocalSeq && !acked.contains(next)) {
                lostPackets.add(next);
              }
            }
          }
        }
      }
      hasLost = lostPackets.isNotEmpty;
      lostPackets.forEach((seq) {
        _resendPacket(seq);
      });
    }

    var sended = _inflightPackets.keys;
    var keys = List<int>.from(sended);
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i];
      if (compareSeqLess(ackSeq, key)) break;
      newSeqAcked = _ackPacket(key) || newSeqAcked;
    }
    if (hasLost) {
      dev.log('Lost packet, fix window size and packet size',
          name: runtimeType.toString());
      _allowWindowSize = _allowWindowSize ~/ 2;
      if (_packetSize > _allowWindowSize) _packetSize = _allowWindowSize;
    }

    if (_inflightPackets.isEmpty && _duplicateAckCountMap.isNotEmpty) {
      _duplicateAckCountMap.clear();
    } else {
      var _useless = <int>[];
      _duplicateAckCountMap.keys.forEach((element) {
        if (compareSeqLess(element, ackSeq)) {
          _useless.add(element);
        }
      });
      _useless.forEach((element) {
        _duplicateAckCountMap.remove(element);
      });
    }
    if (newSeqAcked) _startTimeoutCounter();
    Timer.run(() => _requestSendData());
    startKeepAlive();
  }

  /// 启动一个超时定时器
  ///
  /// 每发生一次超时，超时限定时间会翻倍，并且maxWindowSize会设置为min packet size，即150个字节
  ///
  /// [times] 超时次数。如果每次正常发送数据，则这个值是0。如果是在超时回调
  /// 中发送数据，这个值会自增。
  ///
  /// 每次超时，socket会重新发送队列中的packet。当超时次数超过5次时，则认为对方挂了，socket会自行断开
  void _startTimeoutCounter([int times = 0]) async {
    _outTimer?.cancel();
    if (_inflightPackets.isEmpty) return;
    _outTimer = Timer(Duration(milliseconds: _timeoutCounterTime), () async {
      _outTimer?.cancel();
      if (_inflightPackets.isEmpty) return;
      if (times >= 5) {
        dev.log('发送消息错误，导致关闭', error: '发送消息超时', name: runtimeType.toString());
        addError('发送消息超时');
        await close();
        return;
      }

      _allowWindowSize = MIN_PACKET_SIZE;
      _packetSize = MIN_PACKET_SIZE;
      // print('更改packet size: $_packetSize , max window : $_allowWindowSize');
      times++;
      var now = getNowTimestamp(_startTimeOffset);
      _inflightPackets.values.forEach((packet) {
        var passed = now - packet.sendTime;
        passed = passed ~/ 1000; // 这是微秒，换成毫秒
        if (passed >= _timeoutCounterTime) {
          _resendPacket(packet.seq_nr, times);
        }
      });
      _timeoutCounterTime *= 2; // 超时时间翻倍
    });
  }

  UTPPacket newAckPacket() {
    return UTPPacket(
        ST_STATE, sendId, 0, 0, maxWindowSize, currentLocalSeq, lastRemoteSeq);
  }

  UTPPacket newDataPacket(Uint8List payload) {
    return UTPPacket(
        ST_DATA, sendId, 0, 0, maxWindowSize, currentLocalSeq, lastRemoteSeq,
        payload: payload);
  }

  SelectiveACK newSelectiveACK() {
    if (_receivePacketBuffer.isEmpty) return null;
    var len = _receivePacketBuffer.length;
    var c = len ~/ 32;
    var r = len.remainder(32);
    if (r != 0) c++;
    var payload = Uint8List(c * 32);
    var selectiveAck = SelectiveACK(lastRemoteSeq, payload.length, payload);
    _receivePacketBuffer.forEach((packet) {
      selectiveAck.setAcked(packet.seq_nr);
    });
    return selectiveAck;
  }

  /// 请求发送ACK到远程端
  ///
  /// 请求会压入事件队列中，如果在触发之前有新的ACK要发出，且该ACK不小于要发送的ACK，
  /// 则会取消该次发送，用最新的ACK替代
  void requestSendAck() {
    if (isClosed || !isConnected || isClosing) return;
    var packet = newAckPacket();
    var ack = packet.ack_nr;
    var keys = List<int>.from(_requestSendAckMap.keys);
    for (var i = 0; i < keys.length; i++) {
      var oldAck = keys[i];
      if (ack >= oldAck) {
        var timer = _requestSendAckMap.remove(oldAck);
        timer?.cancel();
        dev.log('有冗余ACK：$oldAck');
      } else {
        break;
      }
    }
    var timer = _requestSendAckMap.remove(ack);
    timer?.cancel();
    _requestSendAckMap[ack] = Timer(Duration.zero, () {
      _requestSendAckMap.remove(ack);
      sendPacket(packet);
    });
  }

  /// 将数据包中的数据抛给监听器
  void _throwDataToListener(UTPPacket packet) {
    if (packet.payload != null && packet.payload.isNotEmpty) {
      if (packet.offset != 0) {
        var data = packet.payload.sublist(packet.offset);
        _receiveDataStreamController?.add(data);
      } else {
        _receiveDataStreamController?.add(packet.payload);
      }
      packet.payload = null;
    }
  }

  /// 处理接收到的[packet]
  ///
  /// 这都是处理远程发送的ST_DATA消息
  void addReceivePacket(UTPPacket packet) {
    var expectSeq = (lastRemoteSeq + 1) & MAX_UINT16;
    var seq = packet.seq_nr;
    if (seq < expectSeq) {
      dev.log('重复数据：$seq($expectSeq)');
      return;
    }
    if (seq > expectSeq) {
      if (_receivePacketBuffer.contains(packet)) {
        dev.log('重复数据：$seq($expectSeq)');
        return;
      }
      _receivePacketBuffer.add(packet);
    }
    if (seq == expectSeq) {
      // 这是期待的正确顺序包
      lastRemoteSeq = expectSeq;
      if (_receivePacketBuffer.isEmpty) {
        _throwDataToListener(packet);
      } else {
        _throwDataToListener(packet);
        _receivePacketBuffer.sort((a, b) {
          if (a > b) return 1;
          if (a < b) return -1;
          return 0;
        });
        for (var i = 0; i < _receivePacketBuffer.length;) {
          var nextPacket = _receivePacketBuffer[i];
          if (nextPacket.seq_nr == ((lastRemoteSeq + 1) & MAX_UINT16)) {
            lastRemoteSeq = nextPacket.seq_nr;
            _throwDataToListener(nextPacket);
            _receivePacketBuffer.removeAt(i);
            continue;
          }
          break;
        }
      }
    }
    // 这里是配合收到FIN消息后继续接收数据，如果收到了最后一个，就强行关闭
    // 这里不会重新计时
    if (lastRemoteSeq == _FINSeq && isClosing) {
      _FINTimer?.cancel();
      closeForce();
    }
    requestSendAck(); // 接受数据后都会请求发送一次ACK
  }

  /// 发送数据包。
  ///
  /// 每次发送的数据包都会更新发送时间以及timedifference，并且会携带最新的ack和selectiveAck。但是
  /// 如果是STATE类型，则不会更改原有的ack值。
  ///
  /// [packet]是数据包对象。
  ///
  /// [times]是第几次重发
  ///
  /// [increase]表示是否自增seq , 如果type是ST_STATE，则该值无论真假，都不会增加seq
  ///
  /// [save]表示是否保存到in-flighting packets map中，如果type是ST_STATE，则该值无论真假，都不会保存
  void sendPacket(UTPPacket packet,
      [int times = 0, bool increase = true, bool save = true]) {
    if (isClosed || _socket == null) return;
    var len = packet.length;
    _currentWindowSize += len;
    // 按照包被创建时间来计算
    _startTimeOffset ??= DateTime.now().microsecondsSinceEpoch;
    var time = getNowTimestamp(_startTimeOffset);
    var diff = (time - lastRemotePktTimestamp) & MAX_UINT32;
    if (packet.type == ST_SYN) {
      diff = 0;
    }
    if (increase && packet.type != ST_STATE) {
      currentLocalSeq++;
      currentLocalSeq &= MAX_UINT16;
    }
    if (save && packet.type != ST_STATE) {
      _inflightPackets[packet.seq_nr] = packet;
    }
    int lastAck;
    if (packet.type == ST_DATA || packet.type == ST_SYN) {
      lastAck = lastRemoteSeq; // DATA类型发送的时候携带最新的ack
      _startTimeoutCounter(times);
    }
    if (packet.type == ST_DATA || packet.type == ST_STATE) {
      // 携带最新的selectiveAck
      packet.clearExtensions();
      var selectiveAck = newSelectiveACK();
      if (selectiveAck != null) {
        packet.addExtension(selectiveAck);
      }
    }
    var bytes = packet.getBytes(ack: lastAck, time: time, timeDiff: diff);
    dev.log(
        'SendOut(${_Type2Map[packet.type]}) : seq : ${packet.seq_nr} , ack : ${packet.ack_nr}',
        name: runtimeType.toString());
    _socket?.send(bytes, remoteAddress, remotePort);
    // 每次发送都会更新一次keepalive
    if (isConnected) startKeepAlive();
  }

  /// 发送FIN消息给对方。
  ///
  /// 此方法会在close的时候调用
  Future _sendFIN() {
    if (isClosed) return null;
    // 告诉对方，最后一个seq就是你收到了，我要关闭了,别等了
    var lastSeq = lastRemoteAck;
    var time = getNowTimestamp(_startTimeOffset);
    var diff = (time - lastRemotePktTimestamp) & MAX_UINT32;
    var packet =
        UTPPacket(ST_FIN, sendId, time, diff, 0, lastSeq, lastRemoteSeq);
    return Future.sync(
        () => _socket?.send(packet.getBytes(), remoteAddress, remotePort));
  }

  void _waitFINLastData([int times = 0]) {
    if (times >= 5) {
      // 超时
      closeForce();
      return;
    }
    _FINTimer = Timer(Duration(milliseconds: _timeoutCounterTime), () {
      _timeoutCounterTime *= 2;
      _waitFINLastData(++times);
    });
  }

  void _remoteFIN(int lastSeq) {
    if (lastRemoteSeq > lastSeq) {
      _FINSeq = lastSeq;
      // 半关闭状态
      connectionState = UTPConnectState.CLOSING;

      _addDataTimer?.cancel();
      _sendingDataCache.clear();
      _duplicateAckCountMap.clear();
      _outTimer?.cancel();

      _resendTimer.forEach((key, timer) {
        timer?.cancel();
      });
      _resendTimer.clear();
      _waitFINLastData();
      return;
    } else {
      closeForce();
      return;
    }
  }

  /// 强制关闭
  void closeForce() async {
    if (isClosed) return;
    connectionState = UTPConnectState.CLOSED;
    _closed = true;

    _FINTimer?.cancel();
    _FINTimer = null;
    _receivePacketBuffer?.clear();
    await _receiveDataStreamController?.close();
    _receiveDataStreamController = null;

    _addDataTimer?.cancel();
    _sendingDataCache.clear();
    _duplicateAckCountMap.clear();
    _outTimer?.cancel();

    _inflightPackets.clear();
    _resendTimer.forEach((key, timer) {
      timer?.cancel();
    });
    _resendTimer.clear();

    _requestSendAckMap.forEach((key, timer) {
      timer?.cancel();
    });
    _requestSendAckMap.clear();

    _sendingDataBuffer?.clear();
    _keepAliveTimer?.cancel();

    Timer.run(() => _handler?.socketClosed(this));
    return;
  }
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
    {void Function(_UTPSocket socket) onConnected,
    void Function(_UTPSocket socket) newSocket,
    void Function(_UTPSocket socket, dynamic error) onError}) {
  // print(
  //     '收到对方${TYPE_NAME[packetData.type]}包:seq_nr:${packetData.seq_nr} , ack_nr : ${packetData.ack_nr}');
  // if (packetData.dataExtension != null) print('有Extension');
  if (socket != null && socket.isClosed) return;
  dev.log(
      'Receive(${_Type2Map[packetData.type]}) : seq : ${packetData.seq_nr} , ack : ${packetData.ack_nr}');

  switch (packetData.type) {
    case ST_SYN:
      _processSYNMessage(
          socket, rawSocket, remoteAddress, remotePort, packetData, newSocket);
      break;
    case ST_DATA:
      _processDataMessage(socket, packetData, onConnected, onError);
      break;
    case ST_STATE:
      _processStateMessage(socket, packetData, onConnected, onError);
      break;
    case ST_FIN:
      _processFINMessage(socket, packetData);
      break;
    case ST_RESET: // TODO implemenmt
      break;
  }
}

void _processFINMessage(_UTPSocket socket, UTPPacket packetData) async {
  if (socket == null || socket.isClosed || socket.isClosing) return;
  var lastSeq = packetData.seq_nr; // 这是最后一个
  socket._remoteFIN(lastSeq);
}

/// 处理进来的SYN消息
///
/// 每次收到SYN消息，都要新建一个连接。但是如果该连接ID已经有对应的[socket]，那就应该通知对方Reset
void _processSYNMessage(_UTPSocket socket, RawDatagramSocket rawSocket,
    InternetAddress remoteAddress, int remotePort, UTPPacket packetData,
    [void Function(_UTPSocket socket) newSocket]) {
  if (socket != null) {
    _sendResetMessage(
        packetData.connectionId, rawSocket, remoteAddress, remotePort);
    dev.log(
        'Duplicated connection id or error data type , reset the connection',
        name: 'utp_protocol_implement');
    return;
  }
  var connId = (packetData.connectionId + 1) & MAX_UINT16;
  socket = _UTPSocket(connId, rawSocket, remoteAddress, remotePort);
  // init receive_id and sent_id
  socket.receiveId = connId;
  socket.sendId = packetData.connectionId; // 保证发送的conn id一致
  socket.currentLocalSeq = Random().nextInt(MAX_UINT16); // 随机seq
  socket.connectionState = UTPConnectState.SYN_RECV; // 更改连接状态
  socket.lastRemoteSeq = packetData.seq_nr;
  socket.remoteWndSize = packetData.wnd_size;
  socket.lastRemotePktTimestamp = packetData.sendTime;
  var packet = socket.newAckPacket();
  socket.sendPacket(packet, 0, false, false);
  if (newSocket != null) newSocket(socket);
  return;
}

/// 通过UDP套接字直接发送一个RESET类型消息给对方
void _sendResetMessage(int connId, RawDatagramSocket rawSocket,
    InternetAddress remoteAddress, int remotePort) {
  var packet = UTPPacket(ST_RESET, connId, 0, 0, 0, 1, 0);
  var bytes = packet.getBytes();
  rawSocket?.send(bytes, remoteAddress, remotePort);
  return;
}

/// 将packet数据中的SelectiveAck Extension带的ack序列号读出
List<int> _readSelectiveAcks(UTPPacket packetData) {
  List<int> selectiveAcks;
  if (packetData.extensionList.isNotEmpty) {
    selectiveAcks = <int>[];
    packetData.extensionList.forEach((ext) {
      if (ext.isUnKnownExtension) return;
      var s = ext as SelectiveACK;
      selectiveAcks.addAll(s.getAckeds());
    });
  }
  return selectiveAcks;
}

/// 处理进来的Data消息
///
/// 对于处于SYN_RECV的socket来说，此时收到消息如果序列号正确，那就是真正连接成功
void _processDataMessage(_UTPSocket socket, UTPPacket packetData,
    [void Function(_UTPSocket) onConnected,
    void Function(_UTPSocket source, dynamic error) onError]) {
  var selectiveAcks = _readSelectiveAcks(packetData);
  if (socket.connectionState == UTPConnectState.SYN_RECV &&
      (socket.currentLocalSeq - 1) & MAX_UINT16 == packetData.ack_nr) {
    socket.connectionState = UTPConnectState.CONNECTED;
    socket.startKeepAlive();
    socket.remoteWndSize = packetData.wnd_size;
    if (onConnected != null) onConnected(socket);
  }
  // 已连接状态下收到数据后去掉header，把payload以事件发出
  if (socket.connectionState == UTPConnectState.CONNECTED ||
      socket.connectionState == UTPConnectState.CLOSING) {
    socket.remoteWndSize = packetData.wnd_size; // 更新对方的window size
    socket.lastRemotePktTimestamp = packetData.sendTime;
    socket.addReceivePacket(packetData);
    socket.remoteAcked(packetData.ack_nr, selectiveAcks);
    return;
  } else {
    // 需不需要reset呢？
    var err = 'UTP socket is not connected, cant process ST_DATA';
    Timer.run(() {
      socket.addError(err);
      if (onError != null) onError(socket, err);
    });
  }
}

/// 处理Ack消息
///
/// 如果[socket]处于SYN_SENT状态，那么此时如果序列号正确即表示连接成功
void _processStateMessage(_UTPSocket socket, UTPPacket packetData,
    [void Function(_UTPSocket) onConnected,
    void Function(_UTPSocket source, dynamic error) onError]) {
  var selectiveAcks = _readSelectiveAcks(packetData);
  if (socket.connectionState == UTPConnectState.SYN_SENT &&
      (socket.currentLocalSeq - 1) & MAX_UINT16 == packetData.ack_nr) {
    socket.connectionState = UTPConnectState.CONNECTED;
    socket.lastRemoteSeq = packetData.seq_nr;
    socket.lastRemoteSeq--;
    socket.remoteWndSize = packetData.wnd_size;
    socket.startKeepAlive();
    if (onConnected != null) onConnected(socket);
  }
  if (socket.connectionState == UTPConnectState.CONNECTED) {
    socket.remoteWndSize = packetData.wnd_size; // 更新对方的window size
    socket.lastRemotePktTimestamp = packetData.sendTime;
    socket.remoteAcked(packetData.ack_nr, selectiveAcks, true);
  } else {
    // 需不需要reset呢？
    var err = 'UTP socket is not connected, cant process ST_STATE';
    Timer.run(() {
      socket.addError(err);
      if (onError != null) onError(socket, err);
    });
  }
}
