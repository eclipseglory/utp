import 'dart:math';

import 'package:utp/src/utp_collections.dart';
import 'package:utp/src/utp_data.dart';
import 'package:utp/src/utp_protocol_implement.dart';

void main(List<String> args) {
  var a = UTPPacket(0, 0, 0, 0, 0, 63345, Random().nextInt(63348));

  var b = UTPPacket(0, 0, 0, 0, 0, 2, Random().nextInt(63348));

  var l = [a, b];

  l.sort((a, b) {
    if (a == b) return 0;
    if (a > b) return 1;
    if (a < b) return -1;
  });

  print(l);
}

bool compare(OrderLinkedEntry<UTPPacket> a, OrderLinkedEntry<UTPPacket> b) {
  return compareSeqLess(a.id, b.id);
}

int getId(UTPPacket i) => i.seq_nr;
