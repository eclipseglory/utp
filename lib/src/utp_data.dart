import 'dart:typed_data';

const MAX_UINT16 = 65535;

const MAX_UINT32 = 4294967295;

/// The current version is 1.
const VERSION = 1;

/// regular data packet. Socket is in connected state and has data to send.
/// An [ST_DATA] packet always has a data payload.
const ST_DATA = 0;

///Finalize the connection. This is the last packet. It closes the connection,
///similar to TCP FIN flag. This connection will never have a sequence number
///greater than the sequence number in this packet. The socket records this
///sequence number as `eof_pkt`. This lets the socket wait for packets that might
///still be missing and arrive out of order even after receiving the [ST_FIN] packet.
const ST_FIN = 1;

///State packet. Used to transmit an ACK with no data. Packets that don't
///include any payload do not increase the `seq_nr`.
const ST_STATE = 2;

/// Terminate connection forcefully. Similar to TCP RST flag. The remote host
///  does not have any state for this connection. It is stale and should be terminated.
const ST_RESET = 3;

/// Connect SYN. Similar to TCP SYN flag, this packet initiates a connection. The sequence number is initialized to 1. The
/// connection ID is initialized to a random number. The syn packet is special, all subsequent packets sent on this connection
/// (except for re-sends of the ST_SYN) are sent with the connection ID + 1. The connection ID is what the other end is
/// expected to use in its responses.
///
/// When receiving an [ST_SYN], the new socket should be initialized with the ID in the packet header. The send ID for the
/// socket should be initialized to the ID + 1. The sequence number for the return channel is initialized to a random number.
/// The other end expects an [ST_STATE] packet (only an ACK) in response.
const ST_SYN = 4;

/// uTP Packet
class UTPPacket {
  /// This is the 'microseconds' parts of the timestamp of when this packet was sent.
  ///
  int timestamp;

  /// This is the difference between the local time and the timestamp in the last received packet,
  /// at the time the last packet was received.
  ///
  int timestampDifference;

  /// This is a random, unique, number identifying all the packets that belong to the same connection.
  int connectionId;

  int wnd_size;

  /// This is the sequence number of this packet.
  int seq_nr;

  /// This is the sequence number the sender of the packet last received in the other direction.
  int ack_nr;

  int version;

  /// The type field describes the type of packet.
  ///
  /// It can be one of:
  /// - [ST_DATA] 0
  /// - [ST_FIN] 1
  /// - [ST_STATE] 2
  /// - [ST_RESET] 3
  /// - [ST_SYN] 4
  int type;

  /// The data payload buffer
  Uint8List payload;

  // Extensions
  List<Extension> extensionList = <Extension>[];

  Uint8List _bytes;

  int get length {
    if (payload != null) return payload.length;
    return 0;
  }

  /// Payload start with
  ///
  /// Sometimes, the whole data bytes with `Header`(include `Extension`) and `Payload`,
  /// so it need not to split `Payload` into a new buffer. This field record
  /// the index `Payload` start with
  final int offset;

  UTPPacket(this.type, this.connectionId, this.timestamp,
      this.timestampDifference, this.wnd_size, this.seq_nr, this.ack_nr,
      {this.version = VERSION, this.payload, this.offset = 0}) {
    assert(type <= 15 && type >= 0, 'Bad type');
    assert(version <= 15 && version >= 0, 'Bad version');
    assert(connectionId != null, 'Bad connection id');
    connectionId &= MAX_UINT16;
    assert(wnd_size != null, 'Bad wnd_size');
    wnd_size &= MAX_UINT32;
    assert(seq_nr != null, 'Bad seq_nr');
    seq_nr &= MAX_UINT16;
    assert(ack_nr != null, 'Bad ack_nr');
    ack_nr &= MAX_UINT16;
    assert(timestamp != null, 'Bad timestamp');
    assert(timestampDifference != null, 'Bad time difference');
  }

  void addExtension(Extension ext) {
    extensionList.add(ext);
    _bytes = null;
  }

  void removeExtension(Extension ext) {
    extensionList.remove(ext);
    _bytes = null;
  }

  factory UTPPacket.newAck(
    int connId,
    int seq,
    int ack, {
    int timeDifferent = 0,
    int wndSize = 0,
  }) {
    return UTPPacket(
        ST_STATE, connId, getNowTime53(), timeDifferent, wndSize, seq, ack);
  }

  factory UTPPacket.newSYN(
    int connId,
    int seq,
    int ack, {
    int timeDifferent = 0,
    int wndSize = 0,
  }) {
    return UTPPacket(
        ST_SYN, connId, getNowTime53(), timeDifferent, wndSize, seq, ack);
  }

  factory UTPPacket.newData(
    int connId,
    int seq,
    int ack,
    Uint8List payload, {
    int timeDifferent = 0,
    int wndSize = 0,
  }) {
    return UTPPacket(
        ST_DATA, connId, getNowTime53(), timeDifferent, wndSize, seq, ack,
        payload: payload);
  }

  /// generate bytes buffer
  ///
  /// [time] is the timestamp , sometimes we need get a new bytes buffer with
  /// different timestamp.
  Uint8List getBytes({int time, int wndSize, int timeDiff, int seq, int ack}) {
    timestamp = time ?? timestamp;
    wnd_size = wndSize ?? wnd_size;
    wnd_size &= MAX_UINT32;
    timestampDifference = timeDiff ?? timestampDifference;
    seq_nr = seq ?? seq_nr;
    seq_nr &= MAX_UINT16;
    ack_nr = ack ?? ack_nr;
    ack_nr &= MAX_UINT16;

    if (_bytes == null) {
      _bytes ??= _createData(type, connectionId, timestamp, timestampDifference,
          wnd_size, seq_nr, ack_nr,
          payload: payload, extensions: extensionList);
    } else {
      var view = ByteData.view(_bytes.buffer);
      view.setUint32(4, timestamp & MAX_UINT16);
      view.setUint32(8, timestampDifference & MAX_UINT16);
      view.setUint32(12, wnd_size);
      view.setUint16(16, seq_nr);
      view.setUint16(18, ack_nr);
    }
    return _bytes;
  }
}

class Extension {
  /// Extension ID
  final int id;

  bool get isUnKnownExtension => id != 1;

  /// Extension length
  final int length;

  /// Payload data buffer.
  final Uint8List payload;

  /// Effect payload start from
  int start;

  Extension(this.id, this.length, this.payload, [this.start = 0]) {
    assert(
        id != null && length != null && payload != null && payload.length >= 4,
        'Bad extension parameters');
  }
}

class SelectiveACK extends Extension {
  final int _ack;
  SelectiveACK(this._ack, int length, Uint8List payload, [int start = 0])
      : super(1, length, payload, start) {
    assert(_ack != null, 'Bad ACK number');
  }

  List<int> getAckeds() {
    var l = <int>[];
    for (var i = 0; i < length; i++) {
      var d = payload[i + start];
      var base = 1;
      if (d == 0) continue;
      for (var j = 0; j < 8; j++) {
        var test = base << j;
        if (d & test != 0) {
          l.add((i * 8 + j + _ack + 2) & MAX_UINT16);
        }
      }
    }
    return l;
  }

  void setAcked(int seq) {
    if (seq < _ack + 2) return;
    var v = seq - _ack - 2;
    var index = v ~/ 8;
    var offset = v.remainder(8);
    var nu = payload[start + index];
    var base = 1;
    base = base << offset;
    payload[start + index] = nu | base;
  }
}

Uint8List _createData(int type, int connectionId, int timestamp,
    int timestampDifference, int wnd_size, int seq_nr, int ack_nr,
    {int version = VERSION, List<Extension> extensions, Uint8List payload}) {
  assert(type <= 15 && type >= 0, 'Bad type');
  assert(version <= 15 && version >= 0, 'Bad version');
  connectionId &= MAX_UINT16;
  ack_nr &= MAX_UINT16;
  seq_nr &= MAX_UINT16;
  wnd_size &= MAX_UINT32;

  Uint8List bytes;
  ByteData view;
  if (extensions == null || extensions.isEmpty) {
    bytes = Uint8List(20);
    view = ByteData.view(bytes.buffer);
    view.setUint8(1, 0); // 没有extension
  } else {
    var extlen = extensions.fold(
        0, (previousValue, element) => previousValue + element.length + 2);
    bytes = Uint8List(20 + extlen);
    view = ByteData.view(bytes.buffer);
    view.setUint8(1, extensions[0].id);
    var index = 20;
    for (var i = 0; i < extensions.length; i++) {
      var ext = extensions[i];
      view.setUint8(index + 1, ext.length);
      for (var j = 0; j < ext.payload.length; j++) {
        view.setUint8(index + 2 + j, ext.payload[j + ext.start]);
      }
      if (i + 1 < extensions.length) {
        var next = extensions[i + 1];
        view.setUint8(index, next.id);
      }
    }
  }

  bytes[0] = (type * 16 | version);
  view.setUint16(2, connectionId);
  view.setUint32(4, timestamp & MAX_UINT16);
  view.setUint32(8, timestampDifference & MAX_UINT16);
  view.setUint32(12, wnd_size);
  view.setUint16(16, seq_nr);
  view.setUint16(18, ack_nr);
  if (payload != null && payload.isNotEmpty) {
    var l = <int>[];
    l.addAll(bytes);
    l.addAll(payload);
    return Uint8List.fromList(l);
  }
  return bytes;
}

/// Parse bytes [data] to `UTPData` instance
UTPPacket parseData(Uint8List data) {
  var view = ByteData.view(data.buffer);
  var first = data[0];
  var type = first ~/ 16;
  var version = first.remainder(16);
  var nextExt = data[1];

  var cid = view.getUint16(2);
  var ts = view.getUint32(4);
  var tsd = view.getUint32(8);
  var wnd = view.getUint32(12);
  var seq = view.getUint16(16);
  var ack = view.getUint16(18);
  var offset = 20;
  var packet = UTPPacket(type, cid, ts, tsd, wnd, seq, ack,
      version: version, payload: data, offset: offset);
  var index = 20;
  while (nextExt != 0) {
    Extension ext;
    if (nextExt == 1) {
      var len = view.getUint8(index + 1);
      ext = SelectiveACK(ack, len, data, index + 2);
    } else {
      // unkown extension
      var len = view.getUint8(index + 1);
      ext = Extension(nextExt, len, data, index + 2);
    }
    packet.addExtension(ext);
    nextExt = view.getUint8(index);
    index += view.getUint8(index + 1) + 2;
  }
  return packet;
}

/// DEBUG
String intToRadix2String(int i) {
  var str = i.toRadixString(2);
  var len = str.length;
  for (var i = 0; i < 8 - len; i++) {
    str = '0$str';
  }
  return str;
}

/// Get 53bit timestamp
int getNowTime53() {
  return DateTime.now().microsecondsSinceEpoch;
}
