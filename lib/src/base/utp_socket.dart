import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// UTP socket
///
/// More details please take a look :
/// [UTP Micro_Transport_Protocol](http://en.wikipedia.org/wiki/Micro_Transport_Protocol)
abstract class UTPSocket extends Socket {
  /// Is UTP socket connected to remote
  bool get isConnected;

  /// 这是用于通讯的真正的UDP socket
  final RawDatagramSocket socket;

  /// The connection id between this socket with remote socket
  int? get connectionId;

  /// Another side socket internet address
  @override
  final InternetAddress remoteAddress;

  /// Another side socket internet port
  @override
  final int remotePort;

  @override
  InternetAddress get address => socket.address;

  /// Local internet port
  @override
  int get port => socket.port;

  /// The max window size. ready-only
  final int maxWindowSize;

  /// The encoding for encode/decode string message.
  ///
  /// See also [write]
  @override
  Encoding encoding;

  /// [_socket] is a UDP socket instance.
  ///
  /// [remoteAddress] and [remotePort] is another side uTP address and port
  ///
  UTPSocket(this.socket, this.remoteAddress, this.remotePort,
      {this.maxWindowSize = 1048576, this.encoding = utf8});

  /// Send ST_FIN message to remote and close the socket.
  ///
  /// If remote don't reply ST_STATE to local for ST_FIN message , this socket
  /// will wait when timeout happen and close itself force.
  ///
  /// If socket is closed , it can't connect agian , if need to reconnect
  /// new a socket instance.
  @override
  Future<dynamic> close([dynamic reason]);

  /// This socket was closed no not
  bool get isClosed;

  /// Useless method
  @deprecated
  @override
  bool setOption(SocketOption option, bool enabled) {
    // TODO: implement setOption
    return false;
  }

  /// Useless method
  @deprecated
  @override
  void setRawOption(RawSocketOption option) {
    // TODO: implement setRawOption
  }

  /// Useless method
  @deprecated
  @override
  Uint8List getRawOption(RawSocketOption option) {
    // TODO: implement getRawOption
    return socket.getRawOption(option);
  }
}
