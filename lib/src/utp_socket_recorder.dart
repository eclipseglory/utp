import 'dart:io';

import 'utp_protocol_implement.dart';

///
/// Record uTP socket with its remote address and remote port.
///
/// This mixin provide some methods to record/find/remove uTP socket
/// instance.
///
/// This mixin use two simple `Map` to record the socket instance currentlly
mixin UTPSocketRecorder {
  final Map<InternetAddress, Map<int, UTPSocket>> _indexMap = {};

  /// Get the `UTPSocket` via [remoteAddress] and [remotePort]
  ///
  /// If not found , return `null`
  UTPSocket findUTPSocket(InternetAddress remoteAddress, int remotePort) {
    var m = _indexMap[remoteAddress];
    if (m != null) {
      return m[remotePort];
    }
    return null;
  }

  /// Record the `UTPSocket` via [remoteAddress] and [remotePort].
  ///
  /// If it have a instance already , it will replace it with the new instance
  void recordUTPSocket(UTPSocket s, InternetAddress address, int port) {
    _indexMap[address] ??= <int, UTPSocket>{};
    var m = _indexMap[address];
    m[port] = s;
  }

  UTPSocket _removeUTPSocket(InternetAddress remoteAddress, int remotePort) {
    var m = _indexMap[remoteAddress];
    if (m != null) {
      return m.remove(remotePort);
    }
    return null;
  }

  /// For each
  void forEach(void Function(UTPSocket socket) processer) {
    _indexMap.forEach((key, value) {
      value.forEach((key, value) {
        processer(value);
      });
    });
  }

  /// clean the record map
  void clean() {
    _indexMap.clear();
  }
}
