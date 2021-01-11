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

/// uTP Data
class UTPData {
  /// This is the 'microseconds' parts of the timestamp of when this packet was sent.
  ///
  /// [timestamp] is a 32 byte number , if the set value large than 4294967295, it will change
  /// value to `4294967295 mod value`
  int timestamp;

  /// This is the difference between the local time and the timestamp in the last received packet,
  /// at the time the last packet was received.
  ///
  /// [timestampDifference] is a 32 byte number , if the set value large than 4294967295, it will change
  /// value to `4294967295 & value`
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

  /// Data Extension
  Extension dataExtension;

  /// Payload start with
  ///
  /// Sometimes, the whole data bytes with `Header`(include `Extension`) and `Payload`,
  /// so it need not to split `Payload` into a new buffer. This field record
  /// the index `Payload` start with
  final int offset;

  UTPData(this.type, this.connectionId, this.timestamp,
      this.timestampDifference, this.wnd_size, this.seq_nr, this.ack_nr,
      {this.version = VERSION,
      this.dataExtension,
      this.payload,
      this.offset = 0}) {
    assert(type <= 15 && type >= 0, 'Bad type');
    assert(version <= 15 && version >= 0, 'Bad version');
    assert(connectionId != null && connectionId <= 65535, 'Bad connection id');
    assert(wnd_size != null && wnd_size <= 4294967295, 'Bad wnd_size');
    assert(seq_nr != null && seq_nr <= 65535, 'Bad seq_nr');
    assert(ack_nr != null && ack_nr <= 65535, 'Bad ack_nr');
    assert(timestamp != null && timestamp >= 0, 'Bad timestamp');
    if (timestamp > 4294967295) timestamp = timestamp.remainder(4294967295);
    assert(timestampDifference != null && timestampDifference >= 0,
        'Bad timestamp');
    if (timestampDifference > 4294967295) {
      timestampDifference = timestampDifference.remainder(4294967295);
    }
  }
}

class Extension {
  /// Extension ID
  final int id;

  bool get isUnKnownExtension {
    return !(id == 0 || id == 1);
  }

  /// Extension payload length
  int get length {
    if (payload == null) return 0;
    return end - start;
  }

  /// Payload data buffer.
  final Uint8List payload;

  /// Effect payload start from
  int start;

  /// Effect payload end of
  int end;
  Extension(this.id, [this.payload, this.start = 0, this.end]) {
    if (payload != null) {
      end ??= payload.length;
    }
  }

  factory Extension.newExtension(int id,
      [Uint8List payload, int start = 0, int end]) {
    if (id == 0) return null;
    if (id == 1) return SelectiveACK(payload, start, end);
    return Extension(id, payload, start, end);
  }
}

class SelectiveACK extends Extension {
  SelectiveACK([Uint8List payload, int start = 0, int end])
      : super(1, payload, start, end);
}

Uint8List createData(int type, int connectionId, int timestamp,
    int timestampDifference, int wnd_size, int seq_nr, int ack_nr,
    {int version = VERSION, Extension dataExtension, Uint8List payload}) {
  assert(type <= 15 && type >= 0, 'Bad type');
  assert(version <= 15 && version >= 0, 'Bad version');
  assert(
      connectionId != null && connectionId <= MAX_UINT16, 'Bad connection id');
  assert(wnd_size != null && wnd_size <= MAX_UINT32, 'Bad wnd_size');
  assert(seq_nr != null && seq_nr <= MAX_UINT16, 'Bad seq_nr');
  assert(ack_nr != null && ack_nr <= MAX_UINT16, 'Bad ack_nr');
  assert(timestamp != null && timestamp >= 0, 'Bad timestamp');
  timestamp &= MAX_UINT32;
  assert(
      timestampDifference != null && timestampDifference >= 0, 'Bad timestamp');
  timestampDifference &= MAX_UINT32;

  var offset = 2;
  Uint8List bytes;
  ByteData view;
  if (dataExtension == null || dataExtension.id == 0) {
    bytes = Uint8List(20);
    view = ByteData.view(bytes.buffer);
    view.setUint8(1, 0);
  } else {
    bytes = Uint8List(21 + dataExtension.length);
    view = ByteData.view(bytes.buffer);
    view.setUint8(1, dataExtension.id);
    view.setUint8(2, dataExtension.length);
    offset += 1;
    var ep = dataExtension.payload;
    for (var i = dataExtension.start; i < dataExtension.end; i++, offset++) {
      view.setUint8(offset, ep[i]);
    }
  }

  bytes[0] = (type * 16 | version);

  view.setUint16(offset, connectionId);
  view.setUint32(offset + 2, timestamp);
  view.setUint32(offset + 6, timestampDifference);
  view.setUint32(offset + 10, wnd_size);
  view.setUint16(offset + 14, seq_nr);
  view.setUint16(offset + 16, ack_nr);
  if (payload != null && payload.isNotEmpty) {
    var l = <int>[];
    l.addAll(bytes);
    l.addAll(payload);
    return Uint8List.fromList(l);
  }
  return bytes;
}

/// Parse bytes [data] to `UTPData` instance
UTPData parseData(Uint8List data) {
  var view = ByteData.view(data.buffer);
  var first = data[0];
  var type = first ~/ 16;
  var version = first.remainder(16);
  Extension dataExtension;
  var ext = data[1];
  var offset = 2;
  if (ext != 0) {
    var length = data[2];
    var start = offset + 1;
    offset = offset + 1 + length;
    var end = offset;
    dataExtension = Extension.newExtension(ext, data, start, end);
  }

  var cid = view.getUint16(offset);
  var ts = view.getUint32(offset + 2);
  var tsd = view.getUint32(offset + 6);
  var wnd = view.getUint32(offset + 10);
  var seq = view.getUint16(offset + 14);
  var ack = view.getUint16(offset + 16);
  return UTPData(type, cid, ts, tsd, wnd, seq, ack,
      version: version,
      dataExtension: dataExtension,
      payload: data,
      offset: offset + 18);
}
