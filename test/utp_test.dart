import 'dart:typed_data';

import 'package:dartorrent_common/dartorrent_common.dart';
import 'package:utp/src/utp_data.dart';
import 'package:test/test.dart';

void main() {
  group('utp data test', () {
    test(' only header create/parse', () {
      var time = DateTime.now().millisecondsSinceEpoch;
      var data = createData(ST_RESET, 1, time, 2, 3, 4, 5);
      assert(data.length == 20);
      var header = parseData(data);
      assert(header.type == ST_RESET);
      assert(header.version == VERSION);
      assert(header.timestamp == time.remainder(4294967295));
      assert(header.timestampDifference == 2);
      assert(header.wnd_size == 3);
      assert(header.seq_nr == 4);
      assert(header.ack_nr == 5);
    });

    test(' only header with extension create/parse', () {
      var time = DateTime.now().millisecondsSinceEpoch;
      var extPayload = Uint8List.fromList(randomBytes(20));
      var ext = Extension.newExtension(2, extPayload);
      var data = createData(ST_RESET, 1, time, 2, 3, 4, 5, dataExtension: ext);
      assert(data.length == 21 + extPayload.length);
      var header = parseData(data);
      assert(header.type == ST_RESET);
      assert(header.version == VERSION);
      assert(header.timestamp == time.remainder(4294967295));
      assert(header.timestampDifference == 2);
      assert(header.wnd_size == 3);
      assert(header.seq_nr == 4);
      assert(header.ack_nr == 5);
      assert(header.offset == data.length);
      var ext1 = header.dataExtension;
      assert(ext1.id == ext.id && ext1.id == data[1]);
      var index = 0;
      for (var i = ext1.start; i < ext1.length; i++, index++) {
        assert(ext1.payload[i] == extPayload[index]);
      }
    });

    test(' only header with extension create/parse 2', () {
      var time = DateTime.now().millisecondsSinceEpoch;
      var extPayload = Uint8List.fromList(randomBytes(26));
      var ext = Extension.newExtension(2, extPayload, 1, 13);
      var data = createData(ST_RESET, 1, time, 2, 3, 4, 5, dataExtension: ext);
      assert(data.length == 21 + 13 - 1);
      var header = parseData(data);
      assert(header.type == ST_RESET);
      assert(header.version == VERSION);
      assert(header.timestamp == time.remainder(4294967295));
      assert(header.timestampDifference == 2);
      assert(header.wnd_size == 3);
      assert(header.seq_nr == 4);
      assert(header.ack_nr == 5);
      assert(header.offset == data.length);
      var ext1 = header.dataExtension;
      assert(ext1.id == ext.id && ext1.id == data[1]);
      var index = 1;
      for (var i = ext1.start; i < ext1.length; i++, index++) {
        assert(ext1.payload[i] == extPayload[index]);
      }
    });
  });
}
