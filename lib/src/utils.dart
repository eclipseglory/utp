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
  //     'Received ${TYPE_NAME[packetData.type]} packet from the other side: seq_nr:${packetData.seq_nr}, ack_nr: ${packetData.ack_nr}');
  // if (packetData.dataExtension != null) print('Has extension');
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

/// Handle Reset messages
///
/// After receiving this message, the Socket forcefully closes the connection
void _processResetMessage(UTPSocketImpl? socket) {
  // socket?.addError('Reset by remote');
  socket?.closeForce();
}

/// Handle FIN messages
void _processFINMessage(UTPSocketImpl? socket, UTPPacket packetData) async {
  if (socket == null || socket.isClosed || socket.isClosing) return;
  socket.remoteFIN(packetData.seq_nr);
  socket.lastRemotePktTimestamp = packetData.sendTime;
  socket.remoteWndSize = packetData.wnd_size;
  socket.addReceivePacket(packetData);
  socket.remoteAcked(packetData.ack_nr, packetData.timestampDifference, false);
}

/// Handle incoming SYN messages.
///
/// Every time a SYN message is received, a new connection should be established. However, if the connection ID already has a corresponding [socket], then it should notify the other party with a Reset
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
    socket.sendId = packetData
        .connectionId; // Ensure that the sent connection ID remains consistent
    socket.currentLocalSeq =
        Random().nextInt(MAX_UINT16); // Random sequence number
    socket.connectionState =
        UTPConnectState.SYN_RECV; // Modify the connection state
    socket.lastRemoteSeq = packetData.seq_nr;
    socket.remoteWndSize = packetData.wnd_size;
    socket.lastRemotePktTimestamp = packetData.sendTime;
    var packet = socket.newAckPacket();
    socket.sendPacket(packet, 0, false, false);
    if (newSocket != null) newSocket(socket);
  }
  return;
}

/// Send a RESET type message directly to the other party through the UDP socket
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

/// Read out the ack sequence number carried by the SelectiveAck Extension in the packet data
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

///Process the incoming Data message
///
///For the socket in SYN_RECV, if the sequence number is correct when the message is received , it means that the connection is successful
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
  // After receiving data in the connected state, remove the header and emit the payload as an event.
  if (socket.isConnected || socket.isClosing) {
    socket.remoteWndSize =
        packetData.wnd_size; // Update the window size of the peer.
    socket.lastRemotePktTimestamp = packetData.sendTime;
    socket.addReceivePacket(packetData);
    socket.remoteAcked(packetData.ack_nr, packetData.timestampDifference, false,
        selectiveAcks);

    return;
  }
}

/// Handling Ack messages
///
/// If the [socket] is in the SYN_SENT state, then at this point, if the sequence number is correct, it means the connection is successful.
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
    socket.remoteWndSize =
        packetData.wnd_size; // Update the window size of the peer.
    socket.lastRemotePktTimestamp = packetData.sendTime;
    socket.remoteAcked(
        packetData.ack_nr, packetData.timestampDifference, true, selectiveAcks);
  }
}
