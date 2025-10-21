// lib/src/controller/dll_controller.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart'; // Clipboard
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:path/path.dart' as p;
import 'package:reboot_common/common.dart';
import 'package:reboot_launcher/main.dart';
import 'package:reboot_launcher/src/messenger/info_bar.dart';
import 'package:reboot_launcher/src/page/settings_page.dart';
import 'package:reboot_launcher/src/util/translations.dart';
import 'package:reboot_launcher/src/controller/game_controller.dart';
import 'package:reboot_launcher/src/controller/hosting_controller.dart';
import 'package:version/version.dart';

// -----------------------------------------------------------------------------
// Constants / paths
// -----------------------------------------------------------------------------

// Where we store the built reboot DLLs on disk (existing global from reboot_common)
final File rebootBeforeS20DllFile = File("${dllsDirectory.path}\\reboot.dll");
final File rebootAboveS20DllFile  = File("${dllsDirectory.path}\\rebootS20.dll");

// Default mirrors (same as your previous values)
const String kRebootBelowS20DownloadUrl =
    "https://nightly.link/Milxnor/Project-Reboot-3.0/workflows/msbuild/master/Reboot.zip";
const String kRebootAboveS20DownloadUrl =
    "https://nightly.link/Milxnor/Project-Reboot-3.0/workflows/msbuild/master/RebootS20.zip";

// Raw GitHub bases (use raw.githubusercontent.com, not /blob or /refs)
const String _autiesBase =
    'https://raw.githubusercontent.com/Auties00/reboot_launcher/master/gui/dependencies/dlls/';
const String _matAuthBase =
    'https://raw.githubusercontent.com/matdoslb/og_launcher/matfn/deps/';

// -----------------------------------------------------------------------------
// Rich error types + HTTP helpers (redirects, snippets, retries)
// -----------------------------------------------------------------------------

class _HttpDownloadError implements Exception {
  final Uri url;
  final int? status;
  final String message;
  final String? bodySnippet;
  _HttpDownloadError(this.url, this.message, {this.status, this.bodySnippet});

  @override
  String toString() {
    final b = StringBuffer()..writeln(message);
    b.writeln('URL: $url');
    if (status != null) b.writeln('HTTP: $status');
    if (bodySnippet != null && bodySnippet!.trim().isNotEmpty) {
      b.writeln('Body (first bytes):\n${bodySnippet!.trim()}');
    }
    return b.toString().trimRight();
  }
}

class _FollowedResponse {
  final HttpClientResponse resp;
  final Uri finalUrl;
  _FollowedResponse(this.resp, this.finalUrl);
}

Future<_FollowedResponse> _getWithRedirects(
  HttpClient client,
  Uri start, {
  int maxRedirects = 5,
  Duration? requestTimeout,
}) async {
  var url = start;
  for (var i = 0; i <= maxRedirects; i++) {
    final req = await client.getUrl(url);
    req.headers.set(HttpHeaders.acceptHeader, "*/*");
    req.headers.set(HttpHeaders.userAgentHeader, "RebootLauncher/1.0");
    req.headers.set(HttpHeaders.connectionHeader, "keep-alive");

    final fut = req.close();
    final resp = requestTimeout == null ? await fut : await fut.timeout(requestTimeout);

    final loc = resp.headers.value(HttpHeaders.locationHeader);
    final is3xx = resp.statusCode >= 300 && resp.statusCode < 400;
    if (is3xx && loc != null && i < maxRedirects) {
      final next = url.resolve(loc);
      try { await resp.drain(); } catch (_) {}
      url = next;
      continue;
    }
    return _FollowedResponse(resp, url);
  }
  throw _HttpDownloadError(start, "Too many redirects");
}

Future<String?> _readSnippet(HttpClientResponse resp, {int max = 1000}) async {
  final bytes = <int>[];
  await for (final chunk in resp) {
    final space = max - bytes.length;
    if (space <= 0) break;
    if (chunk.length <= space) {
      bytes.addAll(chunk);
    } else {
      bytes.addAll(chunk.sublist(0, space));
    }
  }
  if (bytes.isEmpty) return null;
  try {
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return null;
  }
}

// -----------------------------------------------------------------------------
// Controller
// -----------------------------------------------------------------------------

class DllController extends GetxController {
  static const String storageName = "v3_dll_storage";

  late final GetStorage? _storage;
  late final TextEditingController customGameServerDll;
  late final TextEditingController unrealEngineConsoleDll;
  late final TextEditingController backendDll;
  late final TextEditingController memoryLeakDll;
  late final TextEditingController gameServerPort;
  late final TextEditingController beforeS20Mirror;
  late final TextEditingController aboveS20Mirror;
  late final RxBool customGameServer;
  late final RxnInt timestamp;
  late final Rx<UpdateStatus> status;
  late final Map<GameDll, StreamSubscription?> _subscriptions;

  DllController() {
    _storage = appWithNoStorage ? null : GetStorage(storageName);

    customGameServerDll      = _createController("game_server",           GameDll.gameServer);
    unrealEngineConsoleDll   = _createController("unreal_engine_console", GameDll.console);
    backendDll               = _createController("backend",               GameDll.auth);
    memoryLeakDll            = _createController("memory_leak",           GameDll.memoryLeak);

    gameServerPort = TextEditingController(text: _storage?.read("game_server_port") ?? kDefaultGameServerPort);
    gameServerPort.addListener(() => _storage?.write("game_server_port", gameServerPort.text));

    beforeS20Mirror = TextEditingController(text: _storage?.read("before_s20_update_url") ?? kRebootBelowS20DownloadUrl);
    beforeS20Mirror.addListener(() => _storage?.write("before_s20_update_url", beforeS20Mirror.text));

    aboveS20Mirror = TextEditingController(text: _storage?.read("after_s20_update_url") ?? kRebootAboveS20DownloadUrl);
    aboveS20Mirror.addListener(() => _storage?.write("after_s20_update_url", aboveS20Mirror.text));

    status = Rx(UpdateStatus.waiting);

    customGameServer = RxBool(_storage?.read("custom_game_server") ?? false);
    customGameServer.listen((v) => _storage?.write("custom_game_server", v));

    timestamp = RxnInt(_storage?.read("ts"));
    timestamp.listen((v) => _storage?.write("ts", v));

    _subscriptions = {};
  }

  TextEditingController _createController(String key, GameDll dll) {
    final controller = TextEditingController(text: _storage?.read(key) ?? getDefaultDllPath(dll));
    controller.addListener(() => _storage?.write(key, controller.text));
    return controller;
  }

  void resetGame() {
    customGameServerDll.text     = getDefaultDllPath(GameDll.gameServer);
    unrealEngineConsoleDll.text  = getDefaultDllPath(GameDll.console);
    backendDll.text              = getDefaultDllPath(GameDll.auth);
  }

  void resetServer() {
    gameServerPort.text   = kDefaultGameServerPort;
    beforeS20Mirror.text  = kRebootBelowS20DownloadUrl;
    aboveS20Mirror.text   = kRebootAboveS20DownloadUrl;
    status.value          = UpdateStatus.waiting;
    customGameServer.value = false;
    timestamp.value       = null;
    updateGameServerDll();
  }

  Future<bool> updateGameServerDll({bool force = false, bool silent = false}) async {
    InfoBarEntry? info;
    try {
      if (customGameServer.value) {
        status.value = UpdateStatus.success;
        _listenToFileEvents(GameDll.gameServer);
        return true;
      }

      final needsUpdate = await hasRebootDllUpdate(timestamp.value, force: force);
      if (!needsUpdate) {
        status.value = UpdateStatus.success;
        _listenToFileEvents(GameDll.gameServer);
        return true;
      }

      if (!silent) {
        info = showRebootInfoBar(
          translations.downloadingDll("reboot"),
          loading: true,
          duration: null,
        );
      }

      final result = await Future.wait<bool>([
        downloadRebootDll(rebootBeforeS20DllFile, beforeS20Mirror.text, false),
        downloadRebootDll(rebootAboveS20DllFile,  aboveS20Mirror.text,  true ),
        Future.delayed(const Duration(seconds: 1)).then((_) => true),
      ], eagerError: false).then((values) => values.reduce((a, b) => a && b));

      if (!result) {
        status.value = UpdateStatus.error;
        showRebootInfoBar(
          translations.downloadDllAntivirus(antiVirusName ?? defaultAntiVirusName, "reboot"),
          duration: infoBarLongDuration,
          severity: InfoBarSeverity.error,
        );
        info?.close();
        return false;
      }

      timestamp.value = DateTime.now().millisecondsSinceEpoch;
      status.value = UpdateStatus.success;
      info?.close();

      if (!silent) {
        showRebootInfoBar(
          translations.downloadDllSuccess("reboot"),
          severity: InfoBarSeverity.success,
          duration: infoBarShortDuration,
        );
      }

      _listenToFileEvents(GameDll.gameServer);
      return true;
    } catch (e, st) {
      info?.close();
      final details = _formatError(e, st);
      status.value = UpdateStatus.error;

      log("[DLL] updateGameServerDll failed:\n$details");

      final c = Completer<bool>();
      InfoBarEntry? entry;
      entry = showRebootInfoBar(
        translations.downloadDllError("update failed", "reboot.dll"),
        duration: infoBarLongDuration,
        severity: InfoBarSeverity.error,
        onDismissed: () => c.complete(false),
        action: Button(
          onPressed: () {
            entry?.close();
            _showErrorDetails("Reboot DLL download error", details);
            c.complete(false);
          },
          child: const Text("Details"),
        ),
      );
      return c.future;
    }
  }

  (File, bool) getInjectableData(String version, GameDll dll) {
    final defaultPath = p.canonicalize(getDefaultDllPath(dll));
    switch (dll) {
      case GameDll.gameServer:
        if (customGameServer.value) {
          return (File(customGameServerDll.text), true);
        }
        return (_isS20(version) ? rebootAboveS20DllFile : rebootBeforeS20DllFile, false);

      case GameDll.console:
        final ue4ConsoleFile = File(unrealEngineConsoleDll.text);
        return (ue4ConsoleFile, p.canonicalize(ue4ConsoleFile.path) != defaultPath);

      case GameDll.auth:
        final backendFile = File(backendDll.text);
        return (backendFile, p.canonicalize(backendFile.path) != defaultPath);

      case GameDll.memoryLeak:
        final memoryFile = File(memoryLeakDll.text);
        return (memoryFile, p.canonicalize(memoryFile.path) != defaultPath);
    }
  }

  bool _isS20(String version) {
    try {
      return Version.parse(version).major >= 20;
    } on FormatException catch (_) {
      return version.trim().startsWith("20.");
    }
  }

  TextEditingController getDllEditingController(GameDll dll) {
    switch (dll) {
      case GameDll.console:
        return unrealEngineConsoleDll;
      case GameDll.auth:
        return backendDll;
      case GameDll.gameServer:
        return customGameServerDll;
      case GameDll.memoryLeak:
        return memoryLeakDll;
    }
  }

  String getDefaultDllPath(GameDll dll) {
    switch (dll) {
      case GameDll.console:
        return "${dllsDirectory.path}\\console.dll";
      case GameDll.auth:
        return "${dllsDirectory.path}\\cobalt.dll"; // on disk
      case GameDll.gameServer:
        return "${dllsDirectory.path}\\reboot.dll";
      case GameDll.memoryLeak:
        return "${dllsDirectory.path}\\memory.dll";
    }
  }

  Future<bool> download(GameDll dll, String filePath, {bool silent = false, bool force = false}) async {
    InfoBarEntry? info;
    try {
      if (dll == GameDll.gameServer) {
        return await updateGameServerDll(silent: silent);
      }

      if (!force && File(filePath).existsSync()) {
        _listenToFileEvents(dll);
        return true;
      }

      final name = p.basenameWithoutExtension(filePath);
      if (!silent) {
        info = showRebootInfoBar(
          translations.downloadingDll(name),
          loading: true,
          duration: null,
        );
      }

      final ok = await downloadDependency(dll, filePath);
      info?.close();

      if (!ok) {
        showRebootInfoBar(
          translations.downloadDllAntivirus(antiVirusName ?? defaultAntiVirusName, dll.name),
          duration: infoBarLongDuration,
          severity: InfoBarSeverity.error,
        );
        return false;
      }

      if (!silent) {
        showRebootInfoBar(
          translations.downloadDllSuccess(name),
          severity: InfoBarSeverity.success,
          duration: infoBarShortDuration,
        );
      }
      _listenToFileEvents(dll);
      return true;
    } catch (e, st) {
      info?.close();
      final details = _formatError(e, st);

      log("[DLL] download($dll) failed:\n$details");

      final c = Completer<bool>();
      InfoBarEntry? entry;
      entry = showRebootInfoBar(
        translations.downloadDllError("download failed", dll.name),
        duration: infoBarLongDuration,
        severity: InfoBarSeverity.error,
        onDismissed: () => c.complete(false),
        action: Button(
          onPressed: () {
            entry?.close();
            _showErrorDetails("${dll.name} download error", details);
            c.complete(false);
          },
          child: const Text("Details"),
        ),
      );
      return c.future;
    }
  }

  Future<void> downloadAndGuardDependencies() async {
    for (final injectable in GameDll.values) {
      final controller = getDllEditingController(injectable);
      final def = getDefaultDllPath(injectable);
      if (p.equals(controller.text, def)) {
        await download(injectable, controller.text);
      }
    }
  }

  void _listenToFileEvents(GameDll injectable) {
    final controller = getDllEditingController(injectable);
    final defaultPath = getDefaultDllPath(injectable);

    void onFileEvent(FileSystemEvent event, String filePath) {
      if (!p.equals(event.path, filePath)) return;

      if (p.equals(filePath, defaultPath)) {
        Get.find<GameController>().instance.value?.kill();
        Get.find<HostingController>().instance.value?.kill();
        showRebootInfoBar(
          translations.downloadDllAntivirus(antiVirusName ?? defaultAntiVirusName, injectable.name),
          duration: infoBarLongDuration,
          severity: InfoBarSeverity.error,
        );
      }
      _updateInput(injectable);
    }

    StreamSubscription subscribe(String filePath) => File(filePath)
        .parent
        .watch(events: FileSystemEvent.delete | FileSystemEvent.move)
        .listen((event) => onFileEvent(event, filePath));

    controller.addListener(() {
      _subscriptions[injectable]?.cancel();
      _subscriptions[injectable] = subscribe(controller.text);
    });
    _subscriptions[injectable] = subscribe(controller.text);
  }

  void _updateInput(GameDll injectable) {
    switch (injectable) {
      case GameDll.console:
        settingsConsoleDllInputKey.currentState?.validate();
        break;
      case GameDll.auth:
        settingsAuthDllInputKey.currentState?.validate();
        break;
      case GameDll.gameServer:
        settingsGameServerDllInputKey.currentState?.validate();
        break;
      case GameDll.memoryLeak:
        settingsMemoryDllInputKey.currentState?.validate();
        break;
    }
  }
}

enum UpdateStatus { waiting, started, success, error }

// -----------------------------------------------------------------------------
// PUBLIC download API (pure Dart HTTP, no aria2)
// -----------------------------------------------------------------------------

/// Decide if we should re-download reboot dlls.
/// True if forced, missing, or last update older than [hours].
Future<bool> hasRebootDllUpdate(int? lastUpdateMs, {int hours = 24, bool force = false}) async {
  final exists = await rebootBeforeS20DllFile.exists() && await rebootAboveS20DllFile.exists();
  if (force || !exists) return true;
  if (hours <= 0) return false;

  final last = lastUpdateMs != null ? DateTime.fromMillisecondsSinceEpoch(lastUpdateMs) : null;
  if (last == null) return true;
  final now = DateTime.now();
  return now.difference(last).inHours > hours;
}

/// Download a DLL (console/auth/memory) from the declared raw GitHub bases.
/// Returns true on success.
Future<bool> downloadDependency(GameDll dll, String outputPath) async {
  String? name;
  String? base;

  switch (dll) {
    case GameDll.console:
      name = "console.dll";
      base = _autiesBase;
      break;
    case GameDll.auth:
      name = "Cobalt.dll"; // repository file name
      base = _matAuthBase; // your raw GitHub
      break;
    case GameDll.memoryLeak:
      name = "memory.dll";
      base = _autiesBase;
      break;
    case GameDll.gameServer:
      return false; // handled by downloadRebootDll via mirror zip
  }

  final url = Uri.parse('$base$name');

  const tries = 4; // backoff
  final client = HttpClient()
    ..userAgent = "RebootLauncher/1.0 (Dart ${Platform.version})"
    ..autoUncompress = true
    ..maxConnectionsPerHost = 6;

  try {
    for (var attempt = 1; attempt <= tries; attempt++) {
      try {
        final followed = await _getWithRedirects(client, url, requestTimeout: const Duration(seconds: 25));
        final resp = followed.resp;
        final finalUrl = followed.finalUrl;

        log("[HTTP] GET $finalUrl -> ${resp.statusCode}");

        if (resp.statusCode != 200) {
          final snippet = await _readSnippet(resp);
          throw _HttpDownloadError(finalUrl, "Download failed", status: resp.statusCode, bodySnippet: snippet);
        }

        final file = File(outputPath);
        await file.parent.create(recursive: true);
        final sink = file.openWrite();
        try {
          await resp.forEach(sink.add);
          await sink.flush();
        } finally {
          await sink.close();
        }

        // simple read to detect AV/quarantine errors
        await file.readAsBytes();
        return true;
      } on TimeoutException catch (e) {
        if (attempt == tries) {
          throw _HttpDownloadError(url, "Network timeout: ${e.message}");
        }
        await Future.delayed(Duration(milliseconds: 400 * (1 << (attempt - 1))));
      } on SocketException catch (e) {
        if (attempt == tries) {
          throw _HttpDownloadError(url, "Socket error: ${e.message}");
        }
        await Future.delayed(Duration(milliseconds: 400 * (1 << (attempt - 1))));
      } on _HttpDownloadError {
        rethrow;
      } catch (e) {
        if (attempt == tries) {
          throw _HttpDownloadError(url, "Unexpected error: $e");
        }
        await Future.delayed(Duration(milliseconds: 400 * (1 << (attempt - 1))));
      }
    }
    return false;
  } finally {
    try { client.close(force: true); } catch (_) {}
  }
}

/// Downloads Reboot*.zip from a mirror, extracts the single .dll inside,
/// and writes it to [file]. Returns true on success.
Future<bool> downloadRebootDll(File file, String urlString, bool aboveS20) async {
  final url = Uri.parse(urlString);
  final client = HttpClient()
    ..userAgent = "RebootLauncher/1.0 (Dart ${Platform.version})"
    ..autoUncompress = true;

  Directory? tmpDir;
  try {
    // GET (with redirects)
    final followed = await _getWithRedirects(client, url, requestTimeout: const Duration(seconds: 30));
    final resp = followed.resp;

    log("[HTTP] GET ${followed.finalUrl} -> ${resp.statusCode}");

    if (resp.statusCode != 200) {
      final snippet = await _readSnippet(resp);
      throw _HttpDownloadError(followed.finalUrl, "Reboot zip download failed", status: resp.statusCode, bodySnippet: snippet);
    }

    // Save to temp zip
    tmpDir = await installationDirectory.createTemp("reboot_zip_");
    final zipPath = p.join(tmpDir.path, "reboot.zip");
    final zipFile = File(zipPath);
    await zipFile.parent.create(recursive: true);
    final sink = zipFile.openWrite();
    try {
      await resp.forEach(sink.add);
      await sink.flush();
    } finally {
      await sink.close();
    }

    // Decode zip and extract first .dll
    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    ArchiveFile? dllEntry;
    for (final entry in archive) {
      if (!entry.isFile) continue;
      if (p.extension(entry.name).toLowerCase() == '.dll') {
        dllEntry = entry;
        break;
      }
    }
    if (dllEntry == null) {
      throw _HttpDownloadError(followed.finalUrl, "Zip has no .dll inside");
    }

    await file.parent.create(recursive: true);
    await File(file.path).writeAsBytes(dllEntry.content as List<int>, flush: true);

    // AV/quarantine check
    await file.readAsBytes();
    return true;
  } on _HttpDownloadError {
    rethrow;
  } catch (e) {
    throw _HttpDownloadError(url, "Unexpected unzip/write error: $e");
  } finally {
    try { client.close(force: true); } catch (_) {}
    if (tmpDir != null) {
      try { delete(tmpDir); } catch (_) {}
    }
  }
}

// -----------------------------------------------------------------------------
// UI helpers (show full diagnostics on demand)
// -----------------------------------------------------------------------------

String _formatError(Object e, StackTrace st) {
  if (e is _HttpDownloadError) return e.toString();
  return "$e\n\n$st";
}

void _showErrorDetails(String title, String details) {
  final ctx = Get.context;
  if (ctx == null) {
    log("[UI] $title\n$details");
    return;
  }
  showDialog(
    context: ctx,
    barrierDismissible: true,
    builder: (context) {
      return ContentDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: Scrollbar(
            thumbVisibility: true,
            child: SingleChildScrollView(
              child: Text(details, style: FluentTheme.of(context).typography.body),
            ),
          ),
        ),
        actions: [
          FilledButton(
            child: const Text("Copy"),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: details));
              if (Navigator.canPop(context)) Navigator.pop(context);
            },
          ),
          Button(
            child: const Text("Close"),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      );
    },
  );
}
