import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'utils.dart';
import 'enums/utp_connection_state.dart';
import 'utp_data.dart';
import 'utp_server_impl.dart';
import 'base/utp_socket.dart';
import 'base/utp_close_handler.dart';

class UTPSocketImpl extends UTPSocket {
  @override
  bool get isConnected => connectionState == UTPConnectState.CONNECTED;

  @override
  int? get connectionId => receiveId;

  UTPConnectState? connectionState;

  // int _timeoutCounterTime = 1000;

  int _packetSize = MIN_PACKET_SIZE;

  final int maxInflightPackets = 2;

  double? _srtt;

  double? _rttvar;

  /// 超时时间，单位微妙
  double _rto = 1000000.0;

  // double _rtt = 0.0;

  // double _rtt_var = 800.0;
//TODO:Test late initilzation
  late int sendId;

  int _currentLocalSeq = 0;

  /// Make sure the num dont over max uint16
  int _getUint16Int(int v) {
    v = v & MAX_UINT16;
    return v;
  }

  /// The next Packet seq number
  int get currentLocalSeq => _currentLocalSeq;

  set currentLocalSeq(v) => _currentLocalSeq = _getUint16Int(v);

  int _lastRemoteSeq = 0;

  /// The last receive remote packet seq number
  int get lastRemoteSeq => _lastRemoteSeq;

  set lastRemoteSeq(v) => _lastRemoteSeq = _getUint16Int(v);

  int? _lastRemoteAck;

  int? _finalRemoteFINSeq;

  Timer? _FINTimer;

  /// The last packet remote acked.
  int? get lastRemoteAck => _lastRemoteAck;

  set lastRemoteAck(v) => _lastRemoteAck = _getUint16Int(v);

  /// The timestamp when receive the last remote packet
  int? lastRemotePktTimestamp;

  int? remoteWndSize;

  int? receiveId;

  final Map<int, UTPPacket> _inflightPackets = <int, UTPPacket>{};

  final Map<int, Timer> _resendTimer = <int, Timer>{};

  int _currentWindowSize = 0;

  Timer? _rtoTimer;

  bool _closed = false;

  int? minPacketRTT;

  final List<List<int>> _baseDelays = <List<int>>[];

  /// 发送FIN消息并关闭socket的一个future控制completer
  Completer _closeCompleter = Completer();

  @override
  bool get isClosed => _closed;

  /// 正在关闭
  bool get isClosing => connectionState == UTPConnectState.CLOSING;

  final StreamController<Uint8List> _receiveDataStreamController =
      StreamController<Uint8List>();

  final List<UTPPacket> _receivePacketBuffer = <UTPPacket>[];

  Timer? _addDataTimer;

  final List<int> _sendingDataCache = <int>[];

  List<int> _sendingDataBuffer = <int>[];

  final Map<int, int> _duplicateAckCountMap = <int, int>{};

  final Map<int, Timer> _requestSendAckMap = <int, Timer>{};

  Timer? _keepAliveTimer;

  int? _startTimeOffset;

  int _allowWindowSize = MIN_PACKET_SIZE; // _packetSize * 2;

  UTPCloseHandler? _handler;

  bool _finSended = false;

  set closeHandler(UTPCloseHandler h) {
    _handler = h;
  }

  UTPSocketImpl(
      RawDatagramSocket socket, InternetAddress remoteAddress, int remotePort,
      [int maxWindow = 1048576, Encoding encoding = utf8])
      : super(socket, remoteAddress, remotePort,
            maxWindowSize: maxWindow, encoding: encoding) {
    // _allowWindowSize = maxWindow;
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
      var ack = (_lastRemoteSeq - 1) & MAX_UINT16;
      // dev.log('Send keepalive message', name: runtimeType.toString());
      var packet = UTPPacket(
          ST_STATE, sendId, 0, 0, maxWindowSize, currentLocalSeq, ack);
      sendPacket(packet, 0, false, false);
    });
  }

  /// 发送数据会通过该方法进入
  ///
  /// 当发送数据buffer没有数据，并且[_closeCompleter]不为空，则会发送FIN消息给对方
  ///
  void _requestSendData([List<int>? data]) {
    if (data != null && data.isNotEmpty) _sendingDataBuffer.addAll(data);
    if (_sendingDataBuffer.isEmpty) {
      if (!_closeCompleter.isCompleted && _sendingDataCache.isEmpty) {
        // 这说明此时可以发送FIN消息
        _sendFIN();
      }
      return;
    }
    var window = min(_allowWindowSize, remoteWndSize ?? 0);
    var allowSize = window - _currentWindowSize;
    if (allowSize <= 0) {
      return;
    } else {
      var sendingBufferSize = _sendingDataBuffer.length;
      allowSize = min(allowSize, sendingBufferSize);
      var packetNum = allowSize ~/ _packetSize;
      var remainSize = allowSize.remainder(_packetSize);
      var offset = 0;

      if (packetNum == 0 &&
          _sendingDataCache.isEmpty &&
          sendingBufferSize <= _packetSize) {
        var payload = Uint8List(remainSize);
        List.copyRange(
            payload, 0, _sendingDataBuffer, offset, offset + remainSize);
        var packet = newDataPacket(payload);
        if (sendPacket(packet)) {
          offset += remainSize;
        } else {
          _currentLocalSeq--;
          _inflightPackets.remove(packet.seq_nr);
          _currentWindowSize -= packet.length;
        }
      } else {
        for (var i = 0; i < packetNum; i++, offset += _packetSize) {
          var payload = Uint8List(_packetSize);
          List.copyRange(
              payload, 0, _sendingDataBuffer, offset, offset + _packetSize);
          var packet = newDataPacket(payload);
          if (!sendPacket(packet)) {
            _currentLocalSeq--;
            _inflightPackets.remove(packet.seq_nr);
            _currentWindowSize -= packet.length;
            break;
          }
        }
      }
      if (offset != 0) _sendingDataBuffer = _sendingDataBuffer.sublist(offset);
      Timer.run(() => _requestSendData());
      // _requestSendData();
    }
  }

  @override
  Future<bool> any(bool Function(Uint8List) test) {
    return _receiveDataStreamController.stream.any(test);
  }

  @override
  Stream<E> asyncExpand<E>(Stream<E>? Function(Uint8List) convert) {
    return _receiveDataStreamController.stream.asyncExpand(convert);
  }

  @override
  Stream<E> asyncMap<E>(FutureOr<E> Function(Uint8List) convert) {
    return _receiveDataStreamController.stream.asyncMap(convert);
  }

  @override
  Stream<R> cast<R>() {
    return _receiveDataStreamController.stream.cast<R>();
  }

  @override
  Future<bool> contains(Object? needle) {
    return _receiveDataStreamController.stream.contains(needle);
  }

  @override
  Stream<Uint8List> distinct([bool Function(Uint8List, Uint8List)? equals]) {
    return _receiveDataStreamController.stream.distinct(equals);
  }

  @override
  Future<E> drain<E>([E? futureValue]) {
    return _receiveDataStreamController.stream.drain<E>(futureValue);
  }

  @override
  Future<Uint8List> elementAt(int index) {
    return _receiveDataStreamController.stream.elementAt(index);
  }

  @override
  Future<bool> every(bool Function(Uint8List) test) {
    return _receiveDataStreamController.stream.every(test);
  }

  @override
  Stream<S> expand<S>(Iterable<S> Function(Uint8List) convert) {
    return _receiveDataStreamController.stream.expand<S>((convert));
  }

  @override
  Future<S> fold<S>(S initialValue, S Function(S, Uint8List) combine) {
    return _receiveDataStreamController.stream.fold<S>(initialValue, combine);
  }

  @override
  Future<dynamic> forEach(void Function(Uint8List) action) {
    return _receiveDataStreamController.stream.forEach(action);
  }

  @override
  Stream<Uint8List> handleError(Function onError,
      {bool Function(dynamic)? test}) {
    return _receiveDataStreamController.stream.handleError(onError, test: test);
  }

  @override
  void addError(dynamic error, [StackTrace? stackTrace]) {
    if (isClosed || isClosing) return;
    if (isConnected) _receiveDataStreamController.addError(error, stackTrace);
  }

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List data)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    if (isClosed) throw 'Socket is closed';
    return _receiveDataStreamController.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  void add(List<int> data) {
    if (isClosed || isClosing) return;
    if (isConnected && data.isNotEmpty) {
      _addDataTimer?.cancel();
      _sendingDataCache.addAll(data);
      if (_sendingDataCache.isEmpty) return;
      _addDataTimer = Timer(Duration.zero, () {
        var d = List<int>.from(_sendingDataCache);
        _sendingDataCache.clear();
        _requestSendData(d);
      });
    }
  }

  @override
  Future addStream(Stream<List<int>> stream) {
    if (isClosed || isClosing) return Future.value();
    var c = Completer();
    stream.listen((event) {
      if (isClosed || isClosing) {
        c.completeError('Socket was closed/closing , can not add event');
        return;
      }
      _receiveDataStreamController.add(Uint8List.fromList(event));
    }, onDone: () {
      c.complete();
    }, onError: (e) {
      c.completeError(e);
    });
    return c.future;
  }

  @override
  Stream<Uint8List> asBroadcastStream(
      {void Function(StreamSubscription<Uint8List> subscription)? onListen,
      void Function(StreamSubscription<Uint8List> subscription)? onCancel}) {
    return _receiveDataStreamController.stream
        .asBroadcastStream(onListen: onListen, onCancel: onCancel);
  }

  /// Send ST_RESET message to remote and close this socket force.
  @override
  Future destroy() async {
    connectionState = UTPConnectState.CLOSING;
    await sendResetMessage(sendId, socket, remoteAddress, remotePort);
    closeForce();
    return _closeCompleter.future;
  }

  @override
  Future get done => _receiveDataStreamController.done;

  @override
  Future<Uint8List> get first => _receiveDataStreamController.stream.first;

  @override
  Future<Uint8List> firstWhere(bool Function(Uint8List element) test,
      {Uint8List Function()? orElse}) {
    return _receiveDataStreamController.stream.firstWhere(test, orElse: orElse);
  }

  @Deprecated('Useless')
  @override
  Future flush() {
    // TODO: implement flush
    return Future.value(null);
  }

  @override
  bool get isBroadcast => _receiveDataStreamController.stream.isBroadcast;

  @override
  Future<bool> get isEmpty => _receiveDataStreamController.stream.isEmpty;

  @override
  Future<String> join([String separator = '']) {
    return _receiveDataStreamController.stream.join(separator);
  }

  @override
  Future<Uint8List> get last => _receiveDataStreamController.stream.last;

  @override
  Future<Uint8List> lastWhere(bool Function(Uint8List element) test,
      {Uint8List Function()? orElse}) {
    return _receiveDataStreamController.stream.lastWhere(test, orElse: orElse);
  }

  @override
  Future<int> get length => _receiveDataStreamController.stream.length;

  @override
  Stream<S> map<S>(S Function(Uint8List event) convert) {
    return _receiveDataStreamController.stream.map(convert);
  }

  @override
  Future pipe(StreamConsumer<Uint8List> streamConsumer) {
    return _receiveDataStreamController.stream.pipe(streamConsumer);
  }

  @override
  Future<Uint8List> reduce(
      Uint8List Function(Uint8List previous, Uint8List element) combine) {
    return _receiveDataStreamController.stream.reduce(combine);
  }

  @override
  Future<Uint8List> get single => _receiveDataStreamController.stream.single;

  @override
  Future<Uint8List> singleWhere(bool Function(Uint8List element) test,
      {Uint8List Function()? orElse}) {
    return _receiveDataStreamController.stream
        .singleWhere(test, orElse: orElse);
  }

  @override
  Stream<Uint8List> skip(int count) {
    return _receiveDataStreamController.stream.skip(count);
  }

  @override
  Stream<Uint8List> skipWhile(bool Function(Uint8List element) test) {
    return _receiveDataStreamController.stream.skipWhile(test);
  }

  @override
  Stream<Uint8List> take(int count) {
    return _receiveDataStreamController.stream.take(count);
  }

  @override
  Stream<Uint8List> takeWhile(bool Function(Uint8List element) test) {
    return _receiveDataStreamController.stream.takeWhile(test);
  }

  @override
  Stream<Uint8List> timeout(Duration timeLimit,
      {void Function(EventSink<Uint8List> sink)? onTimeout}) {
    return _receiveDataStreamController.stream
        .timeout(timeLimit, onTimeout: onTimeout);
  }

  @override
  Future<List<Uint8List>> toList() {
    return _receiveDataStreamController.stream.toList();
  }

  @override
  Future<Set<Uint8List>> toSet() {
    return _receiveDataStreamController.stream.toSet();
  }

  @override
  Stream<S> transform<S>(StreamTransformer<Uint8List, S> streamTransformer) {
    return _receiveDataStreamController.stream.transform(streamTransformer);
  }

  @override
  Stream<Uint8List> where(bool Function(Uint8List event) test) {
    return _receiveDataStreamController.stream.where(test);
  }

  @override
  void write(Object? obj) {
    var str = obj?.toString();
    if (str != null && str.isNotEmpty) add(encoding.encode(str));
  }

  @override
  void writeAll(Iterable objects, [String separator = '']) {
    if (objects.isEmpty) return;
    var s = '';
    for (var i = 0; i < objects.length; i++) {
      var obj = objects.elementAt(i);
      var str = obj?.toString();
      if (str == null) continue;
      s = '$s$str';
      if (i < objects.length - 1 && separator.isNotEmpty) s += separator;
    }
    write(s);
  }

  @override
  void writeCharCode(int charCode) {
    var s = String.fromCharCode(charCode);
    write(s);
  }

  @override
  void writeln([Object? obj = '']) {
    var str = obj?.toString();
    if (str == null || str.isEmpty) return;
    str = '$str\n';
    write(str);
  }

  @override
  Future close([dynamic reason]) {
    connectionState = UTPConnectState.CLOSING;
    _closeCompleter = Completer();
    Timer(Duration.zero, () => _requestSendData(null));
    // Timer.run(() => _requestSendData(null));
    return _closeCompleter.future;
  }

  /// 重发某个Packet
  ///
  /// [seq] 是packet的序列号
  ///
  /// [times]是重发次数
  void _resendPacket(int seq, [int times = 0]) {
    var packet = _inflightPackets[seq];
    if (packet == null) return _resendTimer.remove(seq)?.cancel();

    _resendTimer.remove(seq)?.cancel();
    _resendTimer[seq] = Timer(Duration.zero, () {
      // print('重新发送 $seq');
      _currentWindowSize -= packet.length;
      packet.resend++;
      _resendTimer.remove(seq);
      sendPacket(packet, times, false, false);
    });
  }

  /// 更新超时时间
  ///
  /// 该计算公式请查阅BEP0029规范以及[RFC6298](https://tools.ietf.org/html/rfc6298)
  void _caculateRTO(UTPPacket packet) {
    var packetRtt = getNowTimestamp(_startTimeOffset) - packet.sendTime;
    if (_srtt == null) {
      _srtt = packetRtt.toDouble();
      _rttvar = packetRtt / 2;
    } else {
      _rttvar = (1 - 0.25) * _rttvar! + 0.25 * (_srtt! - packetRtt).abs();
      _srtt = (1 - 0.125) * _srtt! + 0.125 * packetRtt;
    }
    _rto = _srtt! + max(100000, 4 * _rttvar!);
    // RFC6298规范中，如果RTO不到1秒，则设置为1秒，这里是给出的0.5秒
    _rto = max(_rto, 500000);
  }

  /// ACK某个[seq]对应的packet.
  ///
  /// 如果该Packet已经被acked，返回null，否则返回packet
  UTPPacket? _ackPacket(int seq) {
    var packet = _inflightPackets.remove(seq);
    var resend = _resendTimer.remove(seq);
    resend?.cancel();
    if (packet != null) {
      var ackedSize = packet.length;
      _currentWindowSize -= ackedSize;
      var now = getNowTimestamp(_startTimeOffset);
      var rtt = now - packet.sendTime;
      // 重发的packet不算
      if (rtt != 0 && packet.resend == 0) {
        minPacketRTT ??= rtt;
        minPacketRTT = min(minPacketRTT!, rtt);
      }
      return packet;
    }
    return null;
  }

  /// 更新base delay
  ///
  /// 只保存5秒内的delay
  void _updateBaseDelay(int delay) {
    if (delay <= 0) return;
    var now = DateTime.now().millisecondsSinceEpoch;
    _baseDelays.add([now, delay]);
    var first = _baseDelays.first;
    while (now - first[0] > 5000) {
      _baseDelays.removeAt(0);
      if (_baseDelays.isEmpty) break;
      first = _baseDelays.first;
    }
  }

  /// 获得当前Delay
  ///
  /// 计算规则：当前basedelay的平均值减去当前basedelay中的最小值
  int get currentDelay {
    if (_baseDelays.isEmpty) return 0;
    var sum = 0;
    int? baseDiff;
    for (var i = 0; i < _baseDelays.length; i++) {
      var diff = _baseDelays[i][1];
      baseDiff ??= diff;
      baseDiff = min(baseDiff, diff);
      sum += _baseDelays[i][1];
    }
    var avg = sum ~/ _baseDelays.length;
    return avg - baseDiff!;
  }

  /// 请查看[RFC6817](https://tools.ietf.org/html/rfc6817)以及BEP0029规范
  void _ledbatControl(int ackedSize, int delay) {
    if (ackedSize <= 0 || _allowWindowSize == 0) return;
    // int minBaseDelay;
    // _baseDelays.forEach((element) {
    //   minBaseDelay ??= element[1];
    //   minBaseDelay = min(minBaseDelay, element[1]);
    // });
    // if (minBaseDelay == null) return;
    // 这是原规范中提到的算法，和下面的算法是一致的。
    // 不同的是，1.UTP允许cwnd为0，这样就发不出数据，然后会在超时的时候将cwnd设为最小窗口
    // 2. currnetDelay不同，规范中提出，currentDelay可以利用很多种方法过滤获得，不过滤也
    // 是其中一种过滤。我在实现的时候采用的是利用5秒中内的delay的平均值,以及最小packet rtt两者
    // 的最小值，这是参考了libutp的代码，但具体对不对我也不知道。
    // var queuing_delay = delay - minBaseDelay;
    // var off_target = (CCONTROL_TARGET - queuing_delay) / CCONTROL_TARGET;
    // cwnd += MAX_CWND_INCREASE_PACKETS_PER_RTT * off_target * ackedSize ~/ cwnd;
    // var max_allowed_cwnd = _currentWindowSize + ackedSize + 3000;
    // cwnd = min(cwnd, max_allowed_cwnd);
    // cwnd = max(cwnd, 150);

    var current_delay = currentDelay;
    if (current_delay == 0 || minPacketRTT == null) return;
    var our_delay =
        min(minPacketRTT!, current_delay); // delay会影响增加窗口的大小，这种获得的delay增加窗口会很激进
    // var our_delay = current_delay; // 这种方法会温和一些
    if (our_delay == 0) return;
    // print(
    //     'rtt : $minPacketRTT ,our delay : $queuing_delay , current delay: $current_delay');
    var off_target1 = (CCONTROL_TARGET - our_delay) / CCONTROL_TARGET;
    //  The window size in the socket structure specifies the number of bytes we may have in flight (not acked) in total,
    //  on the connection. The send rate is directly correlated to this window size. The more bytes in flight, the faster
    //   send rate. In the code, the window size is called max_window. Its size is controlled, roughly, by the following expression:
    var delay_factor = off_target1;
    var window_factor = ackedSize / _allowWindowSize;
    var scaled_gain =
        MAX_CWND_INCREASE_PACKETS_PER_RTT * delay_factor * window_factor;
    // Where the first factor scales the off_target to units of target delays.
    // The scaled_gain is then added to the max_window:
    _allowWindowSize += scaled_gain.toInt();
    _packetSize = MAX_PACKET_SIZE;
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
  /// 重复收到[ackSeq]，或者[selectiveAck]中的序列号重复收到，当[isAckType]值为`true`的时候会进行计数(仅对STATE类型的ack_nr进行计数)，
  /// 当某seq重复次数超过3次：
  ///
  /// - 如果该序列号往前的包已经有超过3个被确认收到(*如果该序列号是最后几个发送的，那它的前几个可能不会有3个，则会降低该阈值*)，
  /// 则该序列号和它往前以及往后最近的已确认收到的序列号中间所有的包会被认为已经丢包。
  /// - 如果没有发生上述的情况，则认为该确认[ackSeq] + 1丢包。
  ///
  /// 然后该计数会重置， 丢包的数据会立即重发。
  ///
  void remoteAcked(int ackSeq, int currentDelay,
      [bool isAckType = true, List<int>? selectiveAck]) {
    if (isClosed) return;
    if (!isConnected && !isClosing) return;
    if (ackSeq > currentLocalSeq || _inflightPackets.isEmpty) return;

    var acked = <int>[];
    lastRemoteAck = ackSeq;
    var ackedSize = 0;

    var thisAckPacket = _ackPacket(ackSeq);
    var newSeqAcked = thisAckPacket != null;
    if (thisAckPacket != null) ackedSize += thisAckPacket.length;
    if (thisAckPacket != null && isAckType) {
      _updateBaseDelay(currentDelay);
      _caculateRTO(thisAckPacket);
    }
    acked.add(ackSeq);
    if (selectiveAck != null && selectiveAck.isNotEmpty) {
      acked.addAll(selectiveAck);
    }

    for (var i = 1; i < acked.length; i++) {
      var ackedPacket = _ackPacket(acked[i]);
      newSeqAcked = (ackedPacket != null) || newSeqAcked;
      if (ackedPacket != null) ackedSize += ackedPacket.length;
    }

    var hasLost = false;

    if (isAckType) {
      var lostPackets = <int>{};
      for (var i = 0; i < acked.length; i++) {
        var key = acked[i];
        if (_duplicateAckCountMap[key] == null) {
          _duplicateAckCountMap[key] = 1;
        } else {
          _duplicateAckCountMap[key] = _duplicateAckCountMap[key]! + 1;
          if (_duplicateAckCountMap[key]! >= 3) {
            _duplicateAckCountMap.remove(key);
            // print('$key 重复ack超过3($oldcount)次，计算丢包');
            var over = acked.length - i - 1;
            var limit = ((currentLocalSeq - 1 - key) & MAX_UINT16);
            limit = min(3, limit);
            if (over > limit) {
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
      for (var seq in lostPackets) {
        _resendPacket(seq);
      }
    }

    var sended = _inflightPackets.keys;
    var keys = List<int>.from(sended);
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i];
      if (compareSeqLess(ackSeq, key)) break;
      var ackedPacket = _ackPacket(key);
      if (ackedPacket != null) ackedSize += ackedPacket.length;
      newSeqAcked = (ackedPacket != null) || newSeqAcked;
    }

    if (newSeqAcked && isAckType) _ledbatControl(ackedSize, currentDelay);
    if (hasLost) {
      // dev.log('Lose packets, half cut window size and packet size',
      //     name: runtimeType.toString());
      _allowWindowSize = _allowWindowSize ~/ 2;
    }

    if (_inflightPackets.isEmpty && _duplicateAckCountMap.isNotEmpty) {
      _duplicateAckCountMap.clear();
    } else {
      var useless = <int>[];
      for (var element in _duplicateAckCountMap.keys) {
        if (compareSeqLess(element, ackSeq)) {
          useless.add(element);
        }
      }
      for (var element in useless) {
        _duplicateAckCountMap.remove(element);
      }
    }
    if (_finSended && _inflightPackets.isEmpty) {
      // 如果已经发送FIN并且发送队列中的所有packet已经被ack
      // 则认为对方已经全部收到，关闭该socket
      closeForce();
      return;
    }
    _startTimeoutCounter();
    startKeepAlive();
    Timer.run(() => _requestSendData());
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
    _rtoTimer?.cancel();
    if (_inflightPackets.isEmpty) return;
    if (connectionState == UTPConnectState.SYN_SENT) {
      // 这里请查阅RFC6298第5节 5.7
      if (_rto < 3000000) _rto = 3000000;
    }
    _rtoTimer = Timer(Duration(microseconds: _rto.floor()), () async {
      _rtoTimer?.cancel();
      if (_inflightPackets.isEmpty) return;
      if (times + 1 >= MAX_TIMEOUT) {
        dev.log('Socket closed :',
            error: 'Send data timeout (${times + 1}/$MAX_TIMEOUT)',
            name: runtimeType.toString());
        addError('Send data timeout');
        closeForce();
        await _closeCompleter.future;
        return;
      }
      // dev.log(
      //     'Send data/SYN timeout (${times + 1}/$MAX_TIMEOUT) , reset window/packet to min size($MIN_PACKET_SIZE bytes)',
      //     name: runtimeType.toString());
      _allowWindowSize = MIN_PACKET_SIZE;
      _packetSize = MIN_PACKET_SIZE;
      // print('更改packet size: $_packetSize , max window : $_allowWindowSize');
      times++;
      var now = getNowTimestamp(_startTimeOffset);
      for (var packet in _inflightPackets.values) {
        var passed = now - packet.sendTime;
        if (passed >= _rto) {
          _resendPacket(packet.seq_nr, times);
        }
      }
      _rto *= 2; // 超时时间翻倍
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

  SelectiveACK? newSelectiveACK() {
    if (_receivePacketBuffer.isEmpty) return null;
    _receivePacketBuffer.sort((a, b) {
      if (a > b) return 1;
      if (a < b) return -1;
      return 0;
    });
    var len = _receivePacketBuffer.last.seq_nr - lastRemoteSeq;
    var c = len ~/ 32;
    var r = len.remainder(32);
    if (r != 0) c++;
    var payload = List<int>.filled(c * 32, 0);
    var selectiveAck = SelectiveACK(lastRemoteSeq, payload.length, payload);
    for (var packet in _receivePacketBuffer) {
      selectiveAck.setAcked(packet.seq_nr);
    }
    return selectiveAck;
  }

  /// 请求发送ACK到远程端
  ///
  /// 请求会压入事件队列中，如果在触发之前有新的ACK要发出，且该ACK不小于要发送的ACK，
  /// 则会取消该次发送，用最新的ACK替代
  void requestSendAck() {
    if (isClosed) return;
    if (!isConnected && !isClosing) return;
    var packet = newAckPacket();
    var ack = packet.ack_nr;
    var keys = List<int>.from(_requestSendAckMap.keys);
    for (var i = 0; i < keys.length; i++) {
      var oldAck = keys[i];
      if (ack >= oldAck) {
        var timer = _requestSendAckMap.remove(oldAck);
        timer?.cancel();
      } else {
        break;
      }
    }
    var timer = _requestSendAckMap.remove(ack);
    timer?.cancel();
    _requestSendAckMap[ack] = Timer(Duration.zero, () {
      _requestSendAckMap.remove(ack);
      if (!sendPacket(packet, 0, false, false) &&
          packet.ack_nr == _finalRemoteFINSeq) {
        // 发送失败除非是最后的FIN，否则没必要持续重发
        Timer.run(() => requestSendAck());
      }
    });
  }

  /// 将数据包中的数据抛给监听器
  void _throwDataToListener(UTPPacket packet) {
    if (packet.payload != null && packet.payload!.isNotEmpty) {
      if (packet.offset != 0) {
        var data = packet.payload!.sublist(packet.offset);
        _receiveDataStreamController.add(Uint8List.fromList(data));
      } else {
        _receiveDataStreamController.add(Uint8List.fromList(packet.payload!));
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
    if (_finalRemoteFINSeq != null) {
      if (compareSeqLess(_finalRemoteFINSeq!, seq)) {
        // dev.log('Over FIN seq：$seq($_finalRemoteFINSeq)');
        return;
      }
    }
    if (compareSeqLess(seq, expectSeq)) {
      return;
    }
    if (compareSeqLess(expectSeq, seq)) {
      if (_receivePacketBuffer.contains(packet)) {
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
        var nextPacket = _receivePacketBuffer.first;
        while (nextPacket.seq_nr == ((lastRemoteSeq + 1) & MAX_UINT16)) {
          lastRemoteSeq = nextPacket.seq_nr;
          _throwDataToListener(nextPacket);
          _receivePacketBuffer.removeAt(0);
          if (_receivePacketBuffer.isEmpty) break;
          nextPacket = _receivePacketBuffer.first;
        }
      }
    }
    if (isClosing) {
      if (lastRemoteSeq == _finalRemoteFINSeq) {
        // 如果是最后一个数据包，那就关闭该socket
        var packet = newAckPacket();
        var s = sendPacket(packet, 0, false, false);
        // 如果没发出去，疯狂重发
        while (!s) {
          s = sendPacket(packet, 0, false, false);
        }
        _FINTimer?.cancel();
        closeForce();
        return;
      } else {
        //每次收到新数据都会重置FIN倒计时
        _startCountDownFINData();
      }
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
  bool sendPacket(UTPPacket packet,
      [int times = 0, bool increase = true, bool save = true]) {
    if (isClosed) return false;
    var len = packet.length;
    _currentWindowSize += len;
    // 按照包被创建时间来计算
    _startTimeOffset ??= DateTime.now().microsecondsSinceEpoch;
    var time = getNowTimestamp(_startTimeOffset!);
    var diff = (time - lastRemotePktTimestamp!).abs() & MAX_UINT32;
    // TODO:Remove null casting
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
    int? lastAck;
    if (packet.type == ST_DATA ||
        packet.type == ST_SYN ||
        packet.type == ST_FIN) {
      lastAck = lastRemoteSeq; // DATA类型发送的时候携带最新的ack
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
    var sendBytes = socket.send(bytes, remoteAddress, remotePort);
    var success = sendBytes > 0;
    if (success) {
      // dev.log(
      //     'Send(${_Type2Map[packet.type]}) : seq : ${packet.seq_nr} , ack : ${packet.ack_nr},length:${packet.length}',
      //     name: runtimeType.toString());
      if (packet.type == ST_DATA ||
          packet.type == ST_SYN ||
          packet.type == ST_FIN) {
        _startTimeoutCounter(times);
      }
    }
    // 每次发送都会更新一次keepalive
    if (isConnected && success) startKeepAlive();
    return success;
  }

  /// 发送FIN消息给对方。
  ///
  /// 此方法会在close的时候调用
  void _sendFIN() {
    if (isClosed || _finSended) return;
    var packet =
        UTPPacket(ST_FIN, sendId, 0, 0, 0, currentLocalSeq, lastRemoteSeq);
    _finSended = sendPacket(packet, 0, false, true);
    if (!_finSended) {
      _inflightPackets.remove(packet.seq_nr);
      Timer.run(() => _requestSendData());
    }
    return;
  }

  void _startCountDownFINData([int times = 0]) {
    if (times >= 5) {
      // 超时
      closeForce();
      return;
    }
    _FINTimer = Timer(Duration(microseconds: _rto.floor()), () {
      _rto *= 2;
      _startCountDownFINData(++times);
    });
  }

  void remoteFIN(int finalSeq) async {
    var expectFinal = (lastRemoteSeq + 1) & MAX_UINT32;
    if (compareSeqLess(expectFinal, finalSeq) || expectFinal == finalSeq) {
      _finalRemoteFINSeq = finalSeq;
      connectionState = UTPConnectState.CLOSING;
    }
  }

  /// 强制关闭
  ///
  /// 不发送FIN给remote，直接关闭socket
  void closeForce() async {
    if (isClosed) return;
    connectionState = UTPConnectState.CLOSED;
    _closed = true;

    _FINTimer?.cancel();
    _FINTimer = null;
    _receivePacketBuffer.clear();

    _addDataTimer?.cancel();
    _sendingDataCache.clear();
    _duplicateAckCountMap.clear();
    _rtoTimer?.cancel();

    _inflightPackets.clear();
    _resendTimer.forEach((key, timer) {
      timer.cancel();
    });
    _resendTimer.clear();

    _requestSendAckMap.forEach((key, timer) {
      timer.cancel();
    });
    _requestSendAckMap.clear();

    _sendingDataBuffer.clear();
    _keepAliveTimer?.cancel();

    _baseDelays.clear();

    // 相当于抛出一个事件
    Timer.run(() {
      _handler?.socketClosed(this);
      _handler = null;
      if (!_closeCompleter.isCompleted) {
        _closeCompleter.complete();
      }
    });
    _finSended = false;
    await _receiveDataStreamController.close();

    return;
  }
}
