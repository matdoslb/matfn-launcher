// gui/lib/src/config.dart

/// Build-time switch: pass --dart-define=CLIENT=true for client builds
const bool kClient = bool.fromEnvironment('CLIENT', defaultValue: false);

/// Where the *remote* backend actually lives (your server)
const String kClientBackendHost = 'yourip';

/// Remote backend port (3551 if you terminate HTTP there; 443 if HTTPS)
const int kClientBackendPort = 3551;

// If you serve HTTPS only, you can embed the scheme into the host like:
// const String kClientBackendHost = '';
// const int kClientBackendPort = 443;
