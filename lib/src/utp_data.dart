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
  /// Re-send times
  int resend = 0;

  /// This is the 'microseconds' parts of the timestamp of when this packet was sent.
  int sendTime;

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
  List<int>? payload;

  // Extensions
  List<Extension> extensionList = <Extension>[];

  Uint8List? _bytes;

  int get length {
    if (payload != null) return payload!.length - offset;
    return 0;
  }

  /// Payload start with
  ///
  /// Sometimes, the whole data bytes with `Header`(include `Extension`) and `Payload`,
  /// so it need not to split `Payload` into a new buffer. This field record
  /// the index `Payload` start with
  int offset;

  UTPPacket(this.type, this.connectionId, this.sendTime,
      this.timestampDifference, this.wnd_size, this.seq_nr, this.ack_nr,
      {this.version = VERSION, this.payload, this.offset = 0}) {
    assert(type <= 15 && type >= 0, 'Bad type');
    assert(version <= 15 && version >= 0, 'Bad version');
    connectionId &= MAX_UINT16;
    wnd_size &= MAX_UINT32;
    seq_nr &= MAX_UINT16;
    ack_nr &= MAX_UINT16;
  }

  void addExtension(Extension ext) {
    extensionList.add(ext);
    _bytes = null;
  }

  void removeExtension(Extension ext) {
    extensionList.remove(ext);
    _bytes = null;
  }

  void clearExtensions() {
    if (extensionList.isNotEmpty) {
      extensionList.clear();
      _bytes = null;
    }
  }

  /// generate bytes buffer
  ///
  /// [time] is the timestamp , sometimes we need get a new bytes buffer with
  /// different timestamp.
  Uint8List getBytes(
      {int? time, int? wndSize, int? timeDiff, int? seq, int? ack}) {
    sendTime = time ?? sendTime;
    wnd_size = wndSize ?? wnd_size;
    wnd_size &= MAX_UINT32;
    timestampDifference = timeDiff ?? timestampDifference;
    seq_nr = seq ?? seq_nr;
    seq_nr &= MAX_UINT16;
    ack_nr = ack ?? ack_nr;
    ack_nr &= MAX_UINT16;

    if (_bytes == null) {
      var p = payload;
      if (offset != 0 && payload != null) {
        p = List<int>.filled(payload!.length - offset, 0);
        List.copyRange(p, 0, payload!, offset);
      }
      _bytes = _createData(type, connectionId, sendTime, timestampDifference,
          wnd_size, seq_nr, ack_nr,
          payload: p, extensions: extensionList);
    } else {
      var view = ByteData.view(_bytes!.buffer);
      view.setUint32(4, sendTime & MAX_UINT32);
      view.setUint32(8, timestampDifference & MAX_UINT32);
      view.setUint32(12, wnd_size);
      view.setUint16(16, seq_nr);
      view.setUint16(18, ack_nr);
    }
    return _bytes!;
  }

  @override
  int get hashCode => seq_nr.toString().hashCode;

  @override
  bool operator ==(other) {
    if (other is UTPPacket) {
      return other.seq_nr == seq_nr;
    }
    return false;
  }

  bool operator <(b) {
    if (b is UTPPacket) {
      return compareSeqLess(seq_nr, b.seq_nr);
    }
    throw 'Different type can not compare';
  }

  bool operator >=(b) {
    if (b is UTPPacket) {
      return !(this < b);
    }
    throw 'Different type can not compare';
  }

  bool operator >(b) {
    if (b is UTPPacket) {
      return this >= b && this != b;
    }
    throw 'Different type can not compare';
  }

  bool operator <=(b) {
    if (b is UTPPacket) {
      return !(this > b);
    }
    throw 'Different type can not compare';
  }
}

class Extension {
  /// Extension ID
  final int id;

  bool get isUnKnownExtension => id != 1;

  /// Extension length
  final int length;

  /// Payload data buffer.
  final List<int> payload;

  /// Effect payload start from
  int start;

  Extension(this.id, this.length, this.payload, [this.start = 0]) {
    assert(payload.length >= 4, 'Bad payload size');
  }
}

class SelectiveACK extends Extension {
  final int _ack;
  SelectiveACK(this._ack, int length, List<int> payload, [int start = 0])
      : super(1, length, payload, start);

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
    {int version = VERSION, List<Extension>? extensions, List<int>? payload}) {
  assert(type <= 15 && type >= 0, 'Bad type');
  assert(version <= 15 && version >= 0, 'Bad version');
  connectionId &= MAX_UINT16;
  ack_nr &= MAX_UINT16;
  seq_nr &= MAX_UINT16;
  wnd_size &= MAX_UINT32;

  Uint8List bytes;
  ByteData view;
  var payloadLen = 0;
  var payloadStart = 20;
  if (payload != null && payload.isNotEmpty) {
    payloadLen = payload.length;
  }
  if (extensions == null || extensions.isEmpty) {
    bytes = Uint8List(20 + payloadLen);
    view = ByteData.view(bytes.buffer);
    view.setUint8(1, 0); // 没有extension
  } else {
    var extlen = extensions.fold(
        0, (int previousValue, element) => previousValue + element.length + 2);
    payloadStart += extlen;
    bytes = Uint8List(20 + extlen + payloadLen);
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
  view.setUint32(4, timestamp & MAX_UINT32);
  view.setUint32(8, timestampDifference & MAX_UINT32);
  view.setUint32(12, wnd_size);
  view.setUint16(16, seq_nr);
  view.setUint16(18, ack_nr);
  if (payloadLen > 0) {
    List.copyRange(bytes, payloadStart, payload!);
  }
  return bytes;
}

/// Parse bytes [data] to `UTPData` instance
UTPPacket? parseData(List<int> datas) {
  if (datas.isEmpty || datas.length < 20) return null;
  var data = Uint8List.fromList(datas);
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
  while (nextExt != 0) {
    Extension ext;
    if (nextExt == 1) {
      var len = view.getUint8(offset + 1);
      ext = SelectiveACK(ack, len, data, offset + 2);
    } else {
      // unkown extension
      var len = view.getUint8(offset + 1);
      ext = Extension(nextExt, len, data, offset + 2);
    }
    packet.addExtension(ext);
    nextExt = view.getUint8(offset);
    offset += view.getUint8(offset + 1) + 2;
  }
  packet.offset = offset;
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
int getNowTimestamp([int? offset]) {
  offset ??= 0;
  return DateTime.now().microsecondsSinceEpoch - offset;
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
