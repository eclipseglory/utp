import 'dart:typed_data';

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

const FN = 16;

/// uTP Header
class Header {
  final Uint8List _tail = Uint8List(18);

  int _tv;

  ByteData _tailView;

  Header(int type, int connectionId,
      {int version = VERSION,
      int ext,
      int timestamp,
      int timestampDifference,
      int wnd_size,
      int seq_nr,
      int ack_nr}) {
    _tailView = ByteData.view(_tail.buffer);
    assert(type <= 15 && type >= 0, 'Bad type');
    assert(version <= 15 && version >= 0, 'Bad version');
    var t = type * FN;
    _tv = t | version;
    this.connectionId = connectionId;
    this.timestamp = timestamp;
    this.timestampDifference = timestampDifference;
  }

  factory Header.createHeader(int type, int connectionId) {
    return Header(type, connectionId,
        timestamp: DateTime.now().microsecondsSinceEpoch,
        timestampDifference: 0);
  }

  /// The type field describes the type of packet.
  ///
  /// It can be one of:
  /// - [ST_DATA] 0
  /// - [ST_FIN] 1
  /// - [ST_STATE] 2
  /// - [ST_RESET] 3
  /// - [ST_SYN] 4
  int get type {
    return _tv ~/ FN;
  }

  set type(int t) {
    assert(t <= 15, 'Bad type');
    if (t == type) return;
    var t1 = type * FN;
    _tv = t1 | version;
  }

  /// Protocol version.
  int get version {
    return _tv.remainder(FN);
  }

  set version(int v) {
    assert(v <= 15, 'Bad version');
    if (v == version) return;
    var t = type * FN;
    _tv = t | version;
  }

  /// This is a random, unique, number identifying all the packets that belong to the same connection.
  int get connectionId {
    return _tailView.getUint16(0);
  }

  set connectionId(int id) {
    assert(id != null && id <= 65535, 'Bad connection id');
    if (id == connectionId) return;
    _tailView.setUint16(0, id);
  }

  /// This is the 'microseconds' parts of the timestamp of when this packet was sent.
  ///
  /// [timestamp] is a 32 byte number , if the set value large than 4294967295, it will change
  /// value to `4294967295 mod value`
  int get timestamp {
    return _tailView.getUint32(2);
  }

  set timestamp(int time) {
    assert(time != null, 'Bad timestamp');
    if (time == timestamp) return;
    if (time > 4294967295) time = time.remainder(4294967295);
    _tailView.setUint32(2, time);
  }

  /// This is the difference between the local time and the timestamp in the last received packet,
  /// at the time the last packet was received.
  ///
  /// [timestampDifference] is a 32 byte number , if the set value large than 4294967295, it will change
  /// value to `4294967295 & value`
  int get timestampDifference {
    return _tailView.getUint32(6);
  }

  set timestampDifference(int time) {
    assert(time != null, 'Bad timestamp');
    if (time > 4294967295) time &= 4294967295;
    _tailView.setUint32(6, time);
  }

  int get wnd_size {
    return _tailView.getUint32(10);
  }

  set wnd_size(int size) {
    assert(size != null && size <= 4294967295, 'Bad wnd_size');
    _tailView.setUint32(10, size);
  }

  int get seq_nr {
    return _tailView.getUint16(14);
  }

  set seq_nr(int size) {
    assert(size != null && size <= 65535, 'Bad seq_nr');
    _tailView.setUint16(14, size);
  }

  int get ack_nr {
    return _tailView.getUint16(16);
  }

  set ack_nr(int size) {
    assert(size != null && size <= 65535, 'Bad ack_nr');
    _tailView.setUint32(16, size);
  }

  List<int> get bytes {
    // TODO implement
  }
}
