enum AuthMode {
  local('LOCAL'),
  remote('REMOTE');

  const AuthMode(this.dbValue);
  final String dbValue;

  static AuthMode fromDbValue(String value) {
    switch (value) {
      case 'LOCAL':
        return AuthMode.local;
      case 'REMOTE':
        return AuthMode.remote;
      default:
        throw ArgumentError('Unsupported auth mode: $value');
    }
  }
}

class AppUser {
  final int id;
  final String localUuid;
  final String? displayName;
  final String? email;
  final AuthMode authMode;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  const AppUser({
    required this.id,
    required this.localUuid,
    required this.displayName,
    required this.email,
    required this.authMode,
    required this.isActive,
    required this.createdAt,
    required this.updatedAt,
  });

  factory AppUser.fromMap(Map<String, Object?> map) {
    return AppUser(
      id: map['id'] as int,
      localUuid: map['local_uuid'] as String,
      displayName: map['display_name'] as String?,
      email: map['email'] as String?,
      authMode: AuthMode.fromDbValue(map['auth_mode'] as String),
      isActive: (map['is_active'] as int) == 1,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }
}
