import 'package:ditto_live/ditto_live.dart';

import '../models/models.dart';

/// The three SDK keys, read from the repo-root `.env` via
/// `--dart-define-from-file=../.env` (mflix pattern, PLAN §4.3). Missing
/// config is a UI state, never a crash.
class DatabaseConfig {
  const DatabaseConfig({
    required this.databaseID,
    required this.developmentToken,
    required this.serverURL,
  });

  final String databaseID;
  final String developmentToken;
  final String serverURL;

  static const _databaseID = String.fromEnvironment('DITTO_DATABASE_ID');
  static const _developmentToken = String.fromEnvironment('DITTO_DEVELOPMENT_TOKEN');
  static const _serverURL = String.fromEnvironment('DITTO_SERVER_URL');

  /// Null when any of the three keys is empty.
  static DatabaseConfig? load() {
    final config = DatabaseConfig(
      databaseID: _databaseID,
      developmentToken: _developmentToken,
      serverURL: _serverURL,
    );
    if (config.databaseID.isEmpty ||
        config.developmentToken.isEmpty ||
        config.serverURL.isEmpty) {
      return null;
    }
    return config;
  }

  DittoConfig makeDittoConfig(String persistenceDirectory) {
    final uri = Uri.tryParse(serverURL);
    const validSchemes = ['https', 'http', 'wss', 'ws'];
    if (uri == null ||
        !validSchemes.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty) {
      throw AppError(
        "DITTO_SERVER_URL must be an absolute URL like "
        "https://<cluster>.cloud.dittolive.app (got: '$serverURL')",
      );
    }
    return DittoConfig(
      databaseID: databaseID,
      connect: DittoConfigConnectServer(url: serverURL),
      persistenceDirectory: persistenceDirectory,
    );
  }
}
