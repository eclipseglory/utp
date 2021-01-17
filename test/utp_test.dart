import 'dart:math';
import 'dart:typed_data';

import 'package:utp/src/utp_data.dart';
import 'package:test/test.dart';

void main() {
  group('utp data test', () {
    test(' only header create/parse', () {
      var time = DateTime.now().millisecondsSinceEpoch;
      var p = UTPPacket(ST_RESET, 1, time, 2, 3, 4, 5);
      var data = p.getBytes();
      assert(data.length == 20);
      var header = parseData(data);
      assert(header.type == ST_RESET);
      assert(header.version == VERSION);
      assert(header.sendTime == time & MAX_UINT16);
      assert(header.timestampDifference == 2);
      assert(header.wnd_size == 3);
      assert(header.seq_nr == 4);
      assert(header.ack_nr == 5);
    });

    test(' only header with extension create/parse', () {
      var time = DateTime.now().millisecondsSinceEpoch;
      var packet = UTPPacket(ST_RESET, 1, time, 2, 3, 4, 5);
      var data = packet.getBytes();
      var header = parseData(data);
      assert(header.type == ST_RESET);
      assert(header.version == VERSION);
      assert(header.sendTime == time & MAX_UINT16);
      assert(header.timestampDifference == 2);
      assert(header.wnd_size == 3);
      assert(header.seq_nr == 4);
      assert(header.ack_nr == 5);
      assert(header.offset == data.length);
    });

    test(' only header with extension create/parse 2', () {
      var time = DateTime.now().millisecondsSinceEpoch;
      var packet = UTPPacket(ST_RESET, 1, time, 2, 3, 4, 5);
      var data = packet.getBytes();
      var header = parseData(data);
      assert(header.type == ST_RESET);
      assert(header.version == VERSION);
      assert(header.sendTime == time & MAX_UINT16);
      assert(header.timestampDifference == 2);
      assert(header.wnd_size == 3);
      assert(header.seq_nr == 4);
      assert(header.ack_nr == 5);
      assert(header.offset == data.length);
    });

    test(' Single SelectiveACK and parse', () {
      var ack = 2;

      var ext = SelectiveACK(ack, 4, Uint8List(4));
      assert(ext.getAckeds().isEmpty);
      ext.setAcked(2);
      assert(ext.getAckeds().isEmpty);
      ext.setAcked(12);
      ext.setAcked(7);
      assert(ext.getAckeds().isNotEmpty);
      var ackeds = ext.getAckeds();
      assert(ackeds.contains(12) && ackeds.contains(7));

      var packet = UTPPacket(ST_STATE, 1, 0, 0, 0, 1, 2);
      packet.addExtension(ext);

      var bytes = packet.getBytes();

      var packet1 = parseData(bytes);

      assert(packet1.type == packet.type);
      assert(packet1.version == VERSION);
      assert(packet1.sendTime == packet.sendTime);
      assert(packet1.timestampDifference == packet.timestampDifference);
      assert(packet1.wnd_size == packet.wnd_size);
      assert(packet1.seq_nr == packet.seq_nr);
      assert(packet1.ack_nr == packet.ack_nr);

      var ext1 = packet1.extensionList[0] as SelectiveACK;
      var ackeds1 = ext1.getAckeds();
      assert(ext1.id == ext.id);
      assert(ext1.length == ext.length);
      for (var i = 0; i < ackeds1.length; i++) {
        assert(ackeds1[i] == ackeds[i]);
      }
    });
  });
}

List<int> randomBytes(int a) {
  var l = <int>[];
  for (var i = 0; i < a; i++) {
    l.add(Random().nextInt(256));
  }
  return l;
}
