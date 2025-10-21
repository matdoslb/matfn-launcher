import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart' hide FluentIcons;
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:reboot_common/common.dart';
import 'package:reboot_launcher/main.dart';
import 'package:reboot_launcher/src/util/keyboard.dart';
import 'package:reboot_launcher/src/messenger/info_bar.dart';
import 'package:reboot_launcher/src/config.dart';

typedef BackendInteractiveEventHandler = InfoBarEntry? Function(
    AuthBackendType, AuthBackendResult);

class BackendController extends GetxController {
  static const String storageName = "v3_backend_storage";
  static const PhysicalKeyboardKey _kDefaultConsoleKey =
      PhysicalKeyboardKey(0x00070041);

  late final GetStorage? _storage;
  late final TextEditingController host;
  late final TextEditingController port;
  late final Rx<AuthBackendType> type;
  late final TextEditingController gameServerAddress;
  late final FocusNode gameServerAddressFocusNode;
  late final Rx<PhysicalKeyboardKey> consoleKey;
  late final RxBool started;
  late final RxBool detached;
  AuthBackendImplementation? implementation;
  StreamSubscription? _worker;
  InfoBarEntry? _interactiveEntry;

  BackendController() {
    _storage = appWithNoStorage ? null : GetStorage(storageName);
    started = RxBool(false);

    // Load type from storage, but force REMOTE in client builds
    type = Rx(AuthBackendType.values.elementAt(_storage?.read("type") ?? 0));
    if (kClient) {
      type.value = AuthBackendType.remote;
      _storage?.write("type", type.value.index);
    }
    type.listen((value) {
      host.text = _readHost();
      port.text = _readPort();
      _storage?.write("type", value.index);
    });

    host = TextEditingController(text: _readHost());
    host.addListener(() => _storage?.write("${type.value.name}_host", host.text));

    port = TextEditingController(text: _readPort());
    port.addListener(() => _storage?.write("${type.value.name}_port", port.text));

    // Force remote host/port in client builds
    if (kClient) {
      type.value = AuthBackendType.remote;
      host.text = kClientBackendHost;
      port.text = kClientBackendPort.toString();
      _storage?.write("${type.value.name}_host", host.text);
      _storage?.write("${type.value.name}_port", port.text);
    }

    detached = RxBool(_storage?.read("detached") ?? false);
    if (kClient) detached.value = false; // never run detached backend on client
    detached.listen((value) => _storage?.write("detached", value));

    // ---- Force the game server / matchmaking address in client builds ----
    final saved = _storage?.read("game_server_address");
    if (kClient) {
      gameServerAddress = TextEditingController(text: kClientBackendHost);
      _storage?.write("game_server_address", kClientBackendHost);
      writeAuthBackendMatchmakingIp(kClientBackendHost);

      // If someone edits the field, immediately snap it back
      gameServerAddress.addListener(() {
        final want = kClientBackendHost;
        if (gameServerAddress.text != want) {
          gameServerAddress.text = want;
          gameServerAddress.selection =
              TextSelection.collapsed(offset: want.length);
          _storage?.write("game_server_address", want);
          writeAuthBackendMatchmakingIp(want);
        }
      });
    } else {
      // original behaviour for non-client(local/host) builds
      gameServerAddress = TextEditingController(
        text: (saved == null || saved.isEmpty)
            ? kDefaultBackendHost
            : saved,
      );

      var lastValue = gameServerAddress.text;
      writeAuthBackendMatchmakingIp(lastValue);
      gameServerAddress.addListener(() {
        final newValue = gameServerAddress.text;
        if (newValue.trim().toLowerCase() ==
            lastValue.trim().toLowerCase()) {
          return;
        }
        lastValue = newValue;
        gameServerAddress.selection =
            TextSelection.collapsed(offset: newValue.length);
        _storage?.write("game_server_address", newValue);
        writeAuthBackendMatchmakingIp(newValue);
      });

      watchMatchmakingIp().listen((event) {
        if (event != null && gameServerAddress.text != event) {
          gameServerAddress.text = event;
        }
      });
    }

    gameServerAddressFocusNode = FocusNode();

    consoleKey = Rx(() {
      final consoleKeyValue = _storage?.read("console_key");
      if (consoleKeyValue == null) return _kDefaultConsoleKey;

      final consoleKeyNumber = int.tryParse(consoleKeyValue.toString());
      if (consoleKeyNumber == null) return _kDefaultConsoleKey;

      final consoleKey = PhysicalKeyboardKey(consoleKeyNumber);
      if (!consoleKey.isUnrealEngineKey) return _kDefaultConsoleKey;

      return consoleKey;
    }());
    _writeConsoleKey(consoleKey.value);
    consoleKey.listen((newValue) {
      _storage?.write("console_key", newValue.usbHidUsage);
      _writeConsoleKey(newValue);
    });

    // Helpful debug so you can see what the game will use
    log("[BACKEND] mode=${type.value} host=${host.text}:${port.text} gameServerAddress=${gameServerAddress.text}");
  }

  Future<void> _writeConsoleKey(PhysicalKeyboardKey keyValue) async {
    final defaultInput =
        File("${backendDirectory.path}\\CloudStorage\\DefaultInput.ini");
    await defaultInput.parent.create(recursive: true);
    await defaultInput.writeAsString(
      "[/Script/Engine.InputSettings]\n+ConsoleKeys=Tilde\n+ConsoleKeys=${keyValue.unrealEngineName}",
      flush: true,
    );
  }

  String _readHost() {
    final stored = _storage?.read("${type.value.name}_host");
    if (kClient) return kClientBackendHost;
    if (stored != null && stored.isNotEmpty) return stored;
    if (type.value != AuthBackendType.remote) return kDefaultBackendHost;
    return "";
  }

  String _readPort() {
    if (kClient) return kClientBackendPort.toString();
    return _storage?.read("${type.value.name}_port") ?? kDefaultBackendPort.toString();
  }

  void reset() async {
    type.value = AuthBackendType.values.elementAt(0);
    if (kClient) type.value = AuthBackendType.remote;

    for (final t in AuthBackendType.values) {
      _storage?.write("${t.name}_host", null);
      _storage?.write("${t.name}_port", null);
    }

    if (kClient) {
      host.text = kClientBackendHost;
      port.text = kClientBackendPort.toString();
      gameServerAddress.text = kClientBackendHost;
    } else {
      host.text = type.value != AuthBackendType.remote ? kDefaultBackendHost : "";
      port.text = kDefaultBackendPort.toString();
      gameServerAddress.text = kDefaultBackendHost;
    }

    consoleKey.value = _kDefaultConsoleKey;
    detached.value = false;
  }

  Future<bool> toggle({
    BackendInteractiveEventHandler? eventHandler,
    BackendErrorHandler? errorHandler,
  }) {
    if (started.value) {
      return stop(eventHandler: eventHandler);
    } else {
      return start(eventHandler: eventHandler, errorHandler: errorHandler);
    }
  }

  Future<bool> start({
    BackendInteractiveEventHandler? eventHandler,
    BackendErrorHandler? errorHandler,
  }) async {
    // Client build: never start embedded backend
    if (kClient) {
      log("[BACKEND] Client build -> skip embedded backend start");
      started.value = true;
      return true;
    }

    if (started.value) return true;

    _cancel();
    final stream = startAuthBackend(
      type: type.value,
      host: host.text,
      port: port.text,
      detached: detached.value,
      onError: errorHandler,
    );
    final completer = Completer<bool>();
    _worker = stream.listen((event) {
      _interactiveEntry?.close();
      _interactiveEntry = eventHandler?.call(type.value, event);
      if (event.type.isError) {
        completer.complete(false);
      } else if (event.type.isSuccess) {
        completer.complete(true);
      }
    });
    return await completer.future;
  }

  Future<bool> stop({
    BackendInteractiveEventHandler? eventHandler,
  }) async {
    // Client build: never stop/free embedded backend
    if (kClient) {
      log("[BACKEND] Client build -> skip embedded backend stop");
      started.value = false;
      return true;
    }

    if (!started.value) return true;

    _cancel();
    final stream = stopAuthBackend(
      type: type.value,
      implementation: implementation,
    );
    final completer = Completer<bool>();
    _worker = stream.listen((event) {
      _interactiveEntry?.close();
      _interactiveEntry = eventHandler?.call(type.value, event);
      if (event.type.isError) {
        completer.complete(false);
      } else if (event.type.isSuccess) {
        completer.complete(true);
      }
    });
    return await completer.future;
  }

  void _cancel() {
    _worker?.cancel(); // Do not await or it will hang
    _interactiveEntry?.close();
  }
}
