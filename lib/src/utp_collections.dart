class OrderdLinkedList<T extends OrderLinkedEntry> {
  T first;

  bool get isEmpty => first == null;

  void forEach(void Function(T entry) action) {
    if (isEmpty) return;
    var next = first;
    while (next != null) {
      action(next);
      next = next.next;
    }
  }

  void add(T entry, [bool Function(T a, T b) lessCompare, bool noSame = true]) {
    lessCompare ??= (T a, T b) {
      return a.id < b.id;
    };
    if (first == null) {
      first = entry;
      return;
    }
    if (lessCompare(entry, first)) {
      entry.next = first;
      first = entry;
      return;
    } else {
      if (noSame && first == entry) {
        return;
      }
    }
    var next = first;
    var p;
    while (next != null && lessCompare(next, entry)) {
      p = next;
      next = next.next;
    }
    if (noSame && next == entry) {
      return;
    }
    if (p == null) {
      first = entry;
    } else {
      p.next = entry;
    }
    entry.next = next;
  }
}

class OrderLinkedEntry<T> {
  final T value;

  int Function(T t) idGetter;

  OrderLinkedEntry next;

  bool get hasNext => next != null;

  int get id => idGetter(value);

  OrderLinkedEntry(this.value, this.idGetter) {
    assert(value != null && idGetter != null);
  }

  @override
  int get hashCode => id.hashCode;

  @override
  bool operator ==(b) {
    if (b is OrderLinkedEntry) return b.id == id;
    return false;
  }
}
