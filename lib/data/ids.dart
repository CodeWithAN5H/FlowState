import 'dart:math';

/// Generates an RFC 4122 version 4 UUID.
///
/// Milestone 2B needs stable cross-device identifiers, but not a new dependency:
/// this is 16 bytes from [Random.secure] with the version and variant bits set,
/// which is what the `uuid` package would do for the same purpose. Identifiers
/// are not secrets, so a secure source is a nicety rather than a requirement,
/// but it removes an entire class of guessability argument.
String generateUuidV4([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(
    16,
    (_) => source.nextInt(256),
    growable: false,
  );
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant (10xx)

  final buffer = StringBuffer();
  for (var index = 0; index < bytes.length; index++) {
    if (index == 4 || index == 6 || index == 8 || index == 10)
      buffer.write('-');
    buffer.write(bytes[index].toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

final RegExp _uuidV4Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// True when [value] is a lowercase, version 4, RFC 4122-variant UUID.
bool isUuidV4(String value) => _uuidV4Pattern.hasMatch(value);
