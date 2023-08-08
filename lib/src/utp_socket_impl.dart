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

  /// Timeout duration in microseconds.
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

  /// Sending FIN message and closing the socket with a future controlling the completer.
  Completer _closeCompleter = Completer();

  @override
  bool get isClosed => _closed;

  /// closing
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

  /// After each successful connection or sending/receiving any message (excluding keepalive messages), the socket will define a Timer with a delay of 30 seconds.
  ///
  /// When the Timer triggers, it will send an ST_STATE message, where seq_nr is set to the next sequence number to be sent, and ack_nr is set to the last received remote sequence number minus 1.
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

  /// Data transmission will go through this method.
  ///
  /// When the sending data buffer is empty and [_closeCompleter] is not null, a FIN message will be sent to the other party.
  void _requestSendData([List<int>? data]) {
    if (data != null && data.isNotEmpty) _sendingDataBuffer.addAll(data);
    if (_sendingDataBuffer.isEmpty) {
      if (!_closeCompleter.isCompleted && _sendingDataCache.isEmpty) {
        //This means that the FIN message can be sent at this time
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

  /// Resend a Packet
  ///
  /// [seq] is the sequence number of the packet
  ///
  /// [times] is the number of retransmissions
  void _resendPacket(int seq, [int times = 0]) {
    var packet = _inflightPackets[seq];
    if (packet == null) return _resendTimer.remove(seq)?.cancel();

    _resendTimer.remove(seq)?.cancel();
    _resendTimer[seq] = Timer(Duration.zero, () {
      // print('Resend $seq');
      _currentWindowSize -= packet.length;
      packet.resend++;
      _resendTimer.remove(seq);
      sendPacket(packet, times, false, false);
    });
  }

  /// update timeout
  ///
  /// For the calculation formula, please refer to the BEP0029 specification and[RFC6298](https://tools.ietf.org/html/rfc6298)
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
    // In RFC 6298, if the calculated RTO (Retransmission TimeOut) value is less than 1 second, it should be set to 1 second. However, in this context, it has been specified as 0.5 seconds.
    _rto = max(_rto, 500000);
  }

  /// ACK the packet corresponding to a certain [seq].
  ///
  /// If the Packet has been acked, return null, otherwise return packet
  UTPPacket? _ackPacket(int seq) {
    var packet = _inflightPackets.remove(seq);
    var resend = _resendTimer.remove(seq);
    resend?.cancel();
    if (packet != null) {
      var ackedSize = packet.length;
      _currentWindowSize -= ackedSize;
      var now = getNowTimestamp(_startTimeOffset);
      var rtt = now - packet.sendTime;
      // Retransmitted packets do not count
      if (rtt != 0 && packet.resend == 0) {
        minPacketRTT ??= rtt;
        minPacketRTT = min(minPacketRTT!, rtt);
      }
      return packet;
    }
    return null;
  }

  /// update base delay
  ///
  /// Only delays within a 5-second interval are saved.
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

  /// Get the current Delay
  ///
  /// Calculation rules: the average value of the current basedelay minus the minimum value in the current basedelay
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

  /// Please see [RFC6817](https://tools.ietf.org/html/rfc6817) and the BEP0029 specification
  void _ledbatControl(int ackedSize, int delay) {
    if (ackedSize <= 0 || _allowWindowSize == 0) return;
    // int minBaseDelay;
    // _baseDelays.forEach((element) {
    //   minBaseDelay ??= element[1];
    //   minBaseDelay = min(minBaseDelay, element[1]);
    // });
    // if (minBaseDelay == null) return;
    // This is the algorithm mentioned in the original specification, which is
    // consistent with the algorithm below. The differences are as follows:
    // 1. UTP allows cwnd (congestion window) to be 0, so no data can be sent,
    //and then cwnd will be set to the minimum window size when a timeout occurs.
    // 2. The currentDelay is different; the specification proposes that
    // currentDelay can be obtained using various methods, and filtering is one
    //  of them. In my implementation, I used the average of delays within 5
    //  seconds and the minimum packet round-trip time as the currentDelay,
    //  which was referenced from the libutp code, but I'm not certain if it is
    //  correct or not
    // var queuing_delay = delay - minBaseDelay;
    // var off_target = (CCONTROL_TARGET - queuing_delay) / CCONTROL_TARGET;
    // cwnd += MAX_CWND_INCREASE_PACKETS_PER_RTT * off_target * ackedSize ~/ cwnd;
    // var max_allowed_cwnd = _currentWindowSize + ackedSize + 3000;
    // cwnd = min(cwnd, max_allowed_cwnd);
    // cwnd = max(cwnd, 150);

    var current_delay = currentDelay;
    if (current_delay == 0 || minPacketRTT == null) return;
    var our_delay = min(minPacketRTT!,
        current_delay); // The delay will affect the increase in the window size, and obtaining delay in this way can lead to an aggressive increase in the window size.
    // var our_delay = current_delay; // This method will be more moderate.
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
  /// This method implements the [BEP0029 protocol specification](http://www.bittorrent.org/beps/bep_0029.html) with some modifications.
  /// After the other party acknowledges receiving a data packet with a specific sequence number (applicable for both STATE and DATA types), the method compares this [ackSeq] with the packets that have already been sent. If [ackSeq] is within the confirmation range, i.e., <= seq_nr and >= last_seq_nr, it is considered valid.
  ///
  /// For valid [ackSeq], the method checks the sending queue and clears all packets with a sequence number less than or equal to [ackSeq] (since the other party has confirmed receiving them).
  ///
  /// If [ackSeq] is received multiple times or if the sequence numbers in [selectiveAck] are repeated, and the [isAckType] value is `true`, the method will count the repetitions (only for STATE type's ack_nr). If a sequence number is repeated more than 3 times:
  ///
  ///   - If there are more than 3 packets confirmed as received before this sequence number (*if this sequence number is among the last few sent, its earlier packets may not reach 3 confirmations*), then all packets between this sequence number and the closest confirmed received sequence numbers before and after it will be considered lost.
  ///   - If the above condition is not met, it is assumed that the sequence number [ackSeq] + 1 is lost.

// The count is then reset, and the lost packets are immediately retransmitted.
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
            // print('$key repeated ack exceeded 3($oldcount) times, calculating packet loss')
            var over = acked.length - i - 1;
            var limit = ((currentLocalSeq - 1 - key) & MAX_UINT16);
            limit = min(3, limit);
            if (over > limit) {
              var nextIndex = i + 1;
              var preIndex = i - 1;
              if (nextIndex < acked.length) {
                var c = ((acked[nextIndex] - key) & MAX_UINT16) -
                    1; // how many packets between two Acks.
                for (var j = 0; j < c; j++) {
                  lostPackets.add((key + j + 1) & MAX_UINT16);
                }
              }
              if (preIndex >= 0) {
                var c = ((key - acked[preIndex]) & MAX_UINT16) -
                    1; // how many packets between two Acks.
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
      // If FIN has been sent and all packets in the sending queue have been ACKed,
      // then it is assumed that the other party has received everything and the socket is closed.
      closeForce();
      return;
    }
    _startTimeoutCounter();
    startKeepAlive();
    Timer.run(() => _requestSendData());
  }

  ///Start a timeout timer
  ///
  ///Every time a timeout occurs, the timeout limit will be doubled, and maxWindowSize will be set to min packet size, which is 150 bytes
  ///
  ///[times] is the number of timeouts. If data is sent normally every time, this value is 0. If it is in the timeout callback
  ///this value will increase automatically.
  ///
  // Each timeout, the socket will resend the packets in the queue. If the number of timeouts exceeds 5 times, it is considered that the other party has disconnected, and the socket will disconnect itself
  void _startTimeoutCounter([int times = 0]) async {
    _rtoTimer?.cancel();
    if (_inflightPackets.isEmpty) return;
    if (connectionState == UTPConnectState.SYN_SENT) {
      // Please refer to Section 5.7 of RFC6298 here
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
      // print('Modifying packet size: $_packetSize , max window : $_allowWindowSize');
      times++;
      var now = getNowTimestamp(_startTimeOffset);
      for (var packet in _inflightPackets.values) {
        var passed = now - packet.sendTime;
        if (passed >= _rto) {
          _resendPacket(packet.seq_nr, times);
        }
      }
      _rto *= 2; // double the timeout
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

  // Request to send an ACK to the remote end.
  ///
  /// The request will be pushed into the event queue. If a new ACK needs to be sent before the trigger, and that ACK is not smaller than the ACK to be sent, the current sending will be canceled, and the latest ACK will be used instead.
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
        // Re-sending is unnecessary for failed messages, unless it's the last FIN message
        Timer.run(() => requestSendAck());
      }
    });
  }

  /// Pass the data from the data packet to the listener.
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

  /// Handling the received [packet].
  ///
  /// These are all the ST_DATA messages received from the remote.
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
      // This is the expected correct sequence of packets.
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
        // If it is the last data packet, then close the socket
        var packet = newAckPacket();
        var s = sendPacket(packet, 0, false, false);
        // If the data has not been sent, it will be continuously retransmitted
        while (!s) {
          s = sendPacket(packet, 0, false, false);
        }
        _FINTimer?.cancel();
        closeForce();
        return;
      } else {
        //Every time new data is received, the FIN countdown will be reset.
        _startCountDownFINData();
      }
    }
    requestSendAck(); // After receiving data, an ACK (Acknowledgment) request will be sent once.
  }

  // Send a data packet.
  ///
  /// Every time a data packet is sent, the send time and time difference will be updated, and the latest ACK and Selective ACK will be included. However, if the packet type is STATE, the original ACK value will not be changed.
  ///
  /// [packet] is the data packet object.
  ///
  /// [times] indicates the number of retries.
  ///
  /// [increase] indicates whether to increment the sequence number. If the type is ST_STATE, this value does not affect the sequence number and will not be increased.
  ///
  /// [save] indicates whether to save the packet to the in-flight packets map. If the type is ST_STATE, this value does not affect saving, and the packet will not be saved.
  bool sendPacket(UTPPacket packet,
      [int times = 0, bool increase = true, bool save = true]) {
    if (isClosed) return false;
    var len = packet.length;
    _currentWindowSize += len;
    //Calculated according to the time when the package was created
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
      lastAck =
          lastRemoteSeq; // When sending data of type DATA, it carries the latest ACK (Acknowledgment) information.
    }
    if (packet.type == ST_DATA || packet.type == ST_STATE) {
      // Carrying the latest Selective ACK (Acknowledgment) information.
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
    // Every time data is sent, the keepalive will be updated."
    if (isConnected && success) startKeepAlive();
    return success;
  }

  ///Send a FIN message to the other party.
  ///
  ///This method will be called when closing
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
      // timeout
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

  ///force close
  ///
  ///Do not send FIN to remote, close the socket directly
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

    // Equivalent to firing an event
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
