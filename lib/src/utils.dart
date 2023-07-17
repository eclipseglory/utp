import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'enums/utp_connection_state.dart';
import 'utp_data.dart';
import 'utp_socket_impl.dart';

///
/// uTP protocol receive data process
///
/// Include init connection and other type data process , both of Server socket and client socket
void processReceiveData(
    RawDatagramSocket? rawSocket,
    InternetAddress remoteAddress,
    int remotePort,
    UTPPacket packetData,
    UTPSocketImpl? socket,
    {void Function(UTPSocketImpl socket)? onConnected,
    void Function(UTPSocketImpl socket)? newSocket,
    void Function(UTPSocketImpl socket, dynamic error)? onError}) {
  // print(
  //     '收到对方${TYPE_NAME[packetData.type]}包:seq_nr:${packetData.seq_nr} , ack_nr : ${packetData.ack_nr}');
  // if (packetData.dataExtension != null) print('有Extension');
  if (socket != null && socket.isClosed) return;
  // dev.log(
  //     'Receive(${_Type2Map[packetData.type]}) : seq : ${packetData.seq_nr} , ack : ${packetData.ack_nr}',
  //     name: 'utp_protocol_impelement');
  switch (packetData.type) {
    case ST_SYN:
      _processSYNMessage(
          socket, rawSocket, remoteAddress, remotePort, packetData, newSocket);
      break;
    case ST_DATA:
      processDataMessage(socket, packetData, onConnected, onError);
      break;
    case ST_STATE:
      processStateMessage(socket, packetData, onConnected, onError);
      break;
    case ST_FIN:
      _processFINMessage(socket, packetData);
      break;
    case ST_RESET:
      _processResetMessage(socket);
      break;
  }
}

/// 处理Reset消息。
///
/// Socket接收到此消息后强行关闭连接
void _processResetMessage(UTPSocketImpl? socket) {
  // socket?.addError('Reset by remote');
  socket?.closeForce();
}

/// 处理FIN消息
void _processFINMessage(UTPSocketImpl? socket, UTPPacket packetData) async {
  if (socket == null || socket.isClosed || socket.isClosing) return;
  socket.remoteFIN(packetData.seq_nr);
  socket.lastRemotePktTimestamp = packetData.sendTime;
  socket.remoteWndSize = packetData.wnd_size;
  socket.addReceivePacket(packetData);
  socket.remoteAcked(packetData.ack_nr, packetData.timestampDifference, false);
}

/// 处理进来的SYN消息
///
/// 每次收到SYN消息，都要新建一个连接。但是如果该连接ID已经有对应的[socket]，那就应该通知对方Reset
void _processSYNMessage(UTPSocketImpl? socket, RawDatagramSocket? rawSocket,
    InternetAddress remoteAddress, int remotePort, UTPPacket packetData,
    [void Function(UTPSocketImpl socket)? newSocket]) {
  if (socket != null) {
    sendResetMessage(
        packetData.connectionId, rawSocket, remoteAddress, remotePort);
    // dev.log(
    //     'Duplicated connection id or error data type , reset the connection',
    //     name: 'utp_protocol_implement');
    return;
  }
  var connId = (packetData.connectionId + 1) & MAX_UINT16;
  if (rawSocket != null) {
    socket = UTPSocketImpl(rawSocket, remoteAddress, remotePort);
    // init receive_id and sent_id
    socket.receiveId = connId;
    socket.sendId = packetData.connectionId; // 保证发送的conn id一致
    socket.currentLocalSeq = Random().nextInt(MAX_UINT16); // 随机seq
    socket.connectionState = UTPConnectState.SYN_RECV; // 更改连接状态
    socket.lastRemoteSeq = packetData.seq_nr;
    socket.remoteWndSize = packetData.wnd_size;
    socket.lastRemotePktTimestamp = packetData.sendTime;
    var packet = socket.newAckPacket();
    socket.sendPacket(packet, 0, false, false);
    if (newSocket != null) newSocket(socket);
  }
  return;
}

/// 通过UDP套接字直接发送一个RESET类型消息给对方
Future sendResetMessage(int connId, RawDatagramSocket? rawSocket,
    InternetAddress remoteAddress, int remotePort,
    [UTPPacket? packet, Completer? completer]) {
  if (rawSocket == null) return Future.value();
  packet ??= UTPPacket(ST_RESET, connId, 0, 0, 0, 1, 0);
  var bytes = packet.getBytes();
  completer ??= Completer();
  var s = rawSocket.send(bytes, remoteAddress, remotePort);
  if (s > 0) {
    completer.complete();
    return completer.future;
  } else {
    Timer.run(() => sendResetMessage(
        connId, rawSocket, remoteAddress, remotePort, packet, completer));
  }
  return completer.future;
}

/// 将packet数据中的SelectiveAck Extension带的ack序列号读出
List<int> _readSelectiveAcks(UTPPacket packetData) {
  var selectiveAcks = <int>[];
  if (packetData.extensionList.isNotEmpty) {
    selectiveAcks = <int>[];
    for (var ext in packetData.extensionList) {
      if (ext.isUnKnownExtension) continue;
      var s = ext as SelectiveACK;
      selectiveAcks.addAll(s.getAckeds());
    }
  }
  return selectiveAcks;
}

/// 处理进来的Data消息
///
/// 对于处于SYN_RECV的socket来说，此时收到消息如果序列号正确，那就是真正连接成功
void processDataMessage(UTPSocketImpl? socket, UTPPacket packetData,
    [void Function(UTPSocketImpl)? onConnected,
    void Function(UTPSocketImpl source, dynamic error)? onError]) {
  if (socket == null) {
    return;
  }
  var selectiveAcks = _readSelectiveAcks(packetData);
  if (socket.connectionState == UTPConnectState.SYN_RECV &&
      (socket.currentLocalSeq - 1) & MAX_UINT16 == packetData.ack_nr) {
    socket.connectionState = UTPConnectState.CONNECTED;
    socket.startKeepAlive();
    socket.remoteWndSize = packetData.wnd_size;
    if (onConnected != null) onConnected(socket);
  }
  // 已连接状态下收到数据后去掉header，把payload以事件发出
  if (socket.isConnected || socket.isClosing) {
    socket.remoteWndSize = packetData.wnd_size; // 更新对方的window size
    socket.lastRemotePktTimestamp = packetData.sendTime;
    socket.addReceivePacket(packetData);
    socket.remoteAcked(packetData.ack_nr, packetData.timestampDifference, false,
        selectiveAcks);

    return;
  }
}

/// 处理Ack消息
///
/// 如果[socket]处于SYN_SENT状态，那么此时如果序列号正确即表示连接成功
void processStateMessage(UTPSocketImpl? socket, UTPPacket packetData,
    [void Function(UTPSocketImpl)? onConnected,
    void Function(UTPSocketImpl source, dynamic error)? onError]) {
  if (socket == null) return;
  var selectiveAcks = _readSelectiveAcks(packetData);
  if (socket.connectionState == UTPConnectState.SYN_SENT &&
      (socket.currentLocalSeq - 1) & MAX_UINT16 == packetData.ack_nr) {
    socket.connectionState = UTPConnectState.CONNECTED;
    socket.lastRemoteSeq = packetData.seq_nr;
    socket.lastRemoteSeq = socket.lastRemoteSeq - 1;

    socket.remoteWndSize = packetData.wnd_size;
    socket.startKeepAlive();
    if (onConnected != null) onConnected(socket);
  }
  if (socket.isConnected || socket.isClosing) {
    socket.remoteWndSize = packetData.wnd_size; // 更新对方的window size
    socket.lastRemotePktTimestamp = packetData.sendTime;
    socket.remoteAcked(
        packetData.ack_nr, packetData.timestampDifference, true, selectiveAcks);
  }
}
