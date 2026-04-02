enum RemoteProviderType {
  customBackend('CUSTOM_BACKEND'),
  google('GOOGLE'),
  apple('APPLE');

  const RemoteProviderType(this.dbValue);
  final String dbValue;

  static RemoteProviderType fromDbValue(String value) {
    switch (value) {
      case 'CUSTOM_BACKEND':
        return RemoteProviderType.customBackend;
      case 'GOOGLE':
        return RemoteProviderType.google;
      case 'APPLE':
        return RemoteProviderType.apple;
      default:
        throw ArgumentError('Unsupported provider type: $value');
    }
  }
}

class UserRemoteIdentity {
  final int id;
  final int userId;
  final RemoteProviderType providerType;
  final String remoteUserId;
  final String? remoteEmail;
  final DateTime linkedAt;
  final DateTime? lastSyncAt;

  const UserRemoteIdentity({
    required this.id,
    required this.userId,
    required this.providerType,
    required this.remoteUserId,
    required this.remoteEmail,
    required this.linkedAt,
    required this.lastSyncAt,
  });

  factory UserRemoteIdentity.fromMap(Map<String, Object?> map) {
    return UserRemoteIdentity(
      id: map['id'] as int,
      userId: map['user_id'] as int,
      providerType: RemoteProviderType.fromDbValue(map['provider_type'] as String),
      remoteUserId: map['remote_user_id'] as String,
      remoteEmail: map['remote_email'] as String?,
      linkedAt: DateTime.parse(map['linked_at'] as String),
      lastSyncAt: map['last_sync_at'] == null
          ? null
          : DateTime.parse(map['last_sync_at'] as String),
    );
  }
}
