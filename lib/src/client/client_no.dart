int parseClientNo(Object? value) {
  if (value == null) return 0;
  if (value is int) return value;
  if (value is num) return value.toInt();
  final s = value.toString().trim();
  if (s.isEmpty) return 0;
  return int.parse(s);
}
