import 'utp_protocol_implement.dart';

///
/// Record uTP socket with its remote address and remote port.
///
/// This mixin provide some methods to record/find/remove uTP socket
/// instance.
///
/// This mixin use two simple `Map` to record the socket instance currentlly
mixin UTPSocketRecorder {
  final Map<int, UTPSocket> indexMap = {};

  /// Get the `UTPSocket` via [connectionId]
  ///
  /// If not found , return `null`
  UTPSocket findUTPSocket(int connectionId) {
    return indexMap[connectionId];
  }

  /// Record the `UTPSocket` via [connectionId]
  ///
  /// If it have a instance already , it will replace it with the new instance
  void recordUTPSocket(int connectionId, UTPSocket s) {
    indexMap[connectionId] = s;
  }

  UTPSocket _removeUTPSocket(int connectionId) {
    return indexMap.remove(connectionId);
  }

  /// For each
  void forEach(void Function(UTPSocket socket) processer) {
    indexMap.forEach((key, value) {
      processer(value);
    });
  }

  /// clean the record map
  void clean() {
    indexMap.clear();
  }
}
