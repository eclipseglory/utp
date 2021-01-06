import 'package:utp/src/header.dart';
import 'package:test/test.dart';

void main() {
  group('header test', () {

    test('type/version test', () {
      var header = Header.createHeader(ST_DATA, 0);
      assert(header.type == ST_DATA && header.version == 1);
      header = Header.createHeader(ST_FIN, 0);
      assert(header.type == ST_FIN);
      header = Header.createHeader(ST_RESET, 0);
      assert(header.type == ST_RESET, 0);
      header = Header.createHeader(ST_STATE, 0);
      assert(header.type == ST_STATE);
      header = Header.createHeader(ST_SYN, 0);
      assert(header.type == ST_SYN, header.version == 1);
    });
  });
}
