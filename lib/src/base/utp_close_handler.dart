import '../utp_socket_impl.dart';

abstract class UTPCloseHandler {
  void socketClosed(UTPSocketImpl socket);
}
