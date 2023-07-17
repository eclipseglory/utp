/// UTP socket connection state.
enum UTPConnectState {
  /// UTP socket send then SYN message to another for connecting
  SYN_SENT,

  /// UTP socket receive a SYN message from another
  SYN_RECV,

  /// UTP socket was connected with another one.
  CONNECTED,

  /// UTP socket was closed
  CLOSED,

  /// UTP socket is closing
  CLOSING
}
