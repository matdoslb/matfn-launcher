import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';
import 'package:dart_ipify/dart_ipify.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:get/get.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:path/path.dart';
import 'package:port_forwarder/port_forwarder.dart';
import 'package:reboot_common/common.dart';
import 'package:reboot_launcher/src/controller/backend_controller.dart';
import 'package:reboot_launcher/src/controller/dll_controller.dart';
import 'package:reboot_launcher/src/controller/game_controller.dart';
import 'package:reboot_launcher/src/controller/hosting_controller.dart';
import 'package:reboot_launcher/src/controller/server_browser_controller.dart';
import 'package:reboot_launcher/src/message/backend.dart';
import 'package:reboot_launcher/src/util/matchmaker.dart';
import 'package:reboot_launcher/src/util/translations.dart';
import 'package:reboot_launcher/src/messenger/dialog.dart';
import 'package:reboot_launcher/src/messenger/info_bar.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:version/version.dart';
import 'package:reboot_launcher/src/config.dart'; // +++ add

class LaunchButton extends StatefulWidget {
  final bool host;
  final String startLabel;
  final String stopLabel;

  const LaunchButton({Key? key, required this.host, required this.startLabel, required this.stopLabel}) : super(key: key);

  @override
  State<LaunchButton> createState() => _LaunchButtonState();
}

class _LaunchButtonState extends State<LaunchButton> {
  static const Duration _kRebootDelay = Duration(seconds: 10);

  final GameController _gameController = Get.find<GameController>();
  final HostingController _hostingController = Get.find<HostingController>();
  final BackendController _backendController = Get.find<BackendController>();
  final DllController _dllController = Get.find<DllController>();
  final ServerBrowserController _serverBrowserController = Get.find<ServerBrowserController>();

  InfoBarEntry? _gameClientInfoBar;
  InfoBarEntry? _gameServerInfoBar;
  CancelableOperation? _operation;
  Completer? _pingOperation;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.bottomCenter,
    child: SizedBox(
      width: double.infinity,
      child: Obx(() => SizedBox(
        height: 48,
        child: Button(
            onPressed: () => _operation = CancelableOperation.fromFuture(_toggle()),
            child: Align(
                alignment: Alignment.center,
                child: Text((widget.host ? _hostingController.started() : _gameController.started()) ? widget.stopLabel : widget.startLabel)
            )
        ),
      )),
    ),
  );

  void _setStarted(bool hosting, bool started) => hosting ? _hostingController.started.value = started : _gameController.started.value = started;

  Future<void> _toggle({bool? host}) async {
    host ??= widget.host;
    log("[${host ? 'HOST' : 'GAME'}] Toggling state");
    if (host ? _hostingController.started() : _gameController.started()) {
      log("[${host ? 'HOST' : 'GAME'}] User asked to close the current instance");
      _onStop(
          reason: _StopReason.normal,
          host: host
      );
      return;
    }

    final version = _gameController.selectedVersion.value;
    log("[${host ? 'HOST' : 'GAME'}] Version data: $version");
    if(version == null){
      log("[${host ? 'HOST' : 'GAME'}] No version selected");
      _onStop(
          reason: _StopReason.missingVersionError,
          host: host
      );
      return;
    }

    if (kClient) {
      // Make absolutely sure we launch against server
      _backendController.gameServerAddress.text = kClientBackendHost;
    }

    log("[${host ? 'HOST' : 'GAME'}] Setting started...");
    _setStarted(host, true);
    log("[${host ? 'HOST' : 'GAME'}] Set started");
    log("[${host ? 'HOST' : 'GAME'}] Checking dlls: ${GameDll.values}");
    for (final injectable in GameDll.values) {
      if(await _getDllFileOrStop(version.gameVersion, injectable, host) == null) {
        return;
      }
    }

    try {
      log("[${host ? 'HOST' : 'GAME'}] Checking backend(port: ${_backendController.type.value.name}, type: ${_backendController.type.value.name})...");
      bool backendResult;
      if (kClient) {
        // Force Remote backend that proxies to your server
        _backendController.type.value = AuthBackendType.remote;

        // If you put the scheme in config, keep it; otherwise plain host is fine.
        _backendController.host.text = kClientBackendHost;
        _backendController.port.text = kClientBackendPort.toString();

        // Actually start the remote proxy (binds locally to 127.0.0.1:3551 and forwards to xx
        backendResult = _backendController.started() || await _backendController.start(
          eventHandler: (type, event) {
            _backendController.started.value = event.type.isStart && !event.type.isError;
            if (event.type == AuthBackendResultType.startedImplementation) {
              _backendController.implementation = event.implementation;
            }
            return onBackendResult(type, event);
          },
          errorHandler: (error) {
            if (_backendController.started.value) {
              _backendController.stop();
              _gameController.instance.value?.kill();
              _hostingController.instance.value?.kill();
              onBackendError(error);
            }
          },
        );
      } else {
        backendResult = _backendController.started() || await _backendController.toggle(
          eventHandler: (type, event) {
            _backendController.started.value = event.type.isStart && !event.type.isError;
            if (event.type == AuthBackendResultType.startedImplementation) {
              _backendController.implementation = event.implementation;
            }
            return onBackendResult(type, event);
          },
          errorHandler: (error) {
            if (_backendController.started.value) {
              _backendController.stop();
              _gameController.instance.value?.kill();
              _hostingController.instance.value?.kill();
              onBackendError(error);
            }
          }
        );
      }

      if (!backendResult) {
        _onStop(reason: _StopReason.backendError, host: host);
        return;
      }

      log("[${host ? 'HOST' : 'GAME'}] Backend works");

      final headless = _hostingController.headless.value;
      log("[${host ? 'HOST' : 'GAME'}] Implicit game server metadata: headless($headless)");
      final linkedHostingInstance = await _startMatchMakingServer(version, host, headless, false);
      log("[${host ? 'HOST' : 'GAME'}] Implicit game server result: $linkedHostingInstance");
      final result = await _startGameProcesses(version, host, headless, linkedHostingInstance);
      final started = host ? _hostingController.started() : _gameController.started();
      if(!started) {
        result?.kill();
        return;
      }

      if(host || linkedHostingInstance != null) {
        if (_dllController.gameServerPort.text == kDefaultBackendPort.toString()) {
          _onStop(
              reason: _StopReason.gameServerPortError,
              host: host
          );
          return;
        }
      }

      if(!host) {
        _showLaunchingGameClientWidget(version, headless, linkedHostingInstance != null);
      }else {
        _showLaunchingGameServerWidget();
      }
    } on ProcessException catch (exception, stackTrace) {
      _onStop(
          reason: _StopReason.corruptedVersionError,
          error: exception.toString(),
          stackTrace: stackTrace,
          host: host
      );
    } catch (exception, stackTrace) {
      _onStop(
          reason: _StopReason.unknownError,
          error: exception.toString(),
          stackTrace: stackTrace,
          host: host
      );
    }
  }

  Future<GameInstance?> _startMatchMakingServer(GameVersion version, bool host, bool headless, bool forceLinkedHosting) async {
    log("[${host ? 'HOST' : 'GAME'}] Checking if a server needs to be started automatically...");
    if(host){
      log("[${host ? 'HOST' : 'GAME'}] The user clicked on Start hosting, so it's not necessary");
      return null;
    }

    if(!forceLinkedHosting && _backendController.type.value == AuthBackendType.embedded && !isLocalHost(_backendController.gameServerAddress.text)) {
      log("[${host ? 'HOST' : 'GAME'}] Backend is not set to embedded and/or not pointing to the local game server");
      return null;
    }

    if(_hostingController.started()){
      log("[${host ? 'HOST' : 'GAME'}] The user has already manually started the hosting server");
      return null;
    }

    final response = forceLinkedHosting || await _askForAutomaticGameServer(host);
    if(!response) {
      log("[${host ? 'HOST' : 'GAME'}] The user disabled the automatic server");
      return null;
    }

    log("[${host ? 'HOST' : 'GAME'}] Starting implicit game server...");
    final instance = await _startGameProcesses(version, true, headless, null);
    log("[${host ? 'HOST' : 'GAME'}] Started implicit game server...");
    _setStarted(true, true);
    log("[${host ? 'HOST' : 'GAME'}] Set implicit game server as started");
    return instance;
  }

Future<bool> _askForAutomaticGameServer(bool host) async {
  // Client build: never show the dialog and don't auto-start a local server.
  if (kClient) return false;

  if (host ? !_hostingController.started() : !_gameController.started()) {
    _onStop(reason: _StopReason.normal, host: host);
    return false;
  }

  final result = await showRebootDialog<bool>(
    builder: (context) => InfoDialog(
      text: translations.automaticGameServerDialogContent,
      buttons: [
        DialogButton(type: ButtonType.secondary, text: translations.automaticGameServerDialogIgnore),
        DialogButton(
          type: ButtonType.primary,
          text: translations.automaticGameServerDialogStart,
          onTap: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  ) ?? false;

  await Future.delayed(const Duration(seconds: 1));
  return result;
}


  Future<GameInstance?> _startGameProcesses(GameVersion version, bool host, bool headless, GameInstance? linkedHosting) async {
    final launcherProcess = await _createPausedProcess(version, host, kLauncherExe);
    final eacProcess = await _createPausedProcess(version, host, kEacExe);
    final gameProcess = await _createGameProcess(version, host, headless, linkedHosting);
    if(gameProcess == null) {
      log("[${host ? 'HOST' : 'GAME'}] No game process was created");
      return null;
    }

    log("[${host ? 'HOST' : 'GAME'}] Created game process: ${gameProcess}");
    final instance = GameInstance(
        version: version.gameVersion,
        host: host,
        gamePid: gameProcess,
        launcherPid: launcherProcess,
        eacPid: eacProcess,
        headless: host && headless,
        child: linkedHosting
    );
    if(host){
      _serverBrowserController.removeServer(_hostingController.uuid);
      _hostingController.instance.value = instance;
    }else{
      _gameController.instance.value = instance;
    }
    await _injectOrShowError(GameDll.auth, host);
    log("[${host ? 'HOST' : 'GAME'}] Finished creating game instance");
    return instance;
  }

  Future<int?> _createGameProcess(GameVersion version, bool host, bool headless, GameInstance? linkedHosting) async {
    log("[${host ? 'HOST' : 'GAME'}] Starting game process...");
    try {
      log("[${host ? 'HOST' : 'GAME'}] Deleting $kGFSDKAftermathLibDll...");
      final dlls = await findFiles(version.location, kGFSDKAftermathLibDll);
      log("[${host ? 'HOST' : 'GAME'}] Found ${dlls.length} to delete for $kGFSDKAftermathLibDll");
      for(final dll in dlls) {
        log("[${host ? 'HOST' : 'GAME'}] Deleting ${dll.path}...");
        final result = await delete(dll);
        if(result) {
          log("[${host ? 'HOST' : 'GAME'}] Deleted ${dll.path}");
        }else {
          log("[${host ? 'HOST' : 'GAME'}] Cannot delete ${dll.path}");
        }
      }
    }catch(_) {

    }
    final shippingExecutables = await findFiles(version.location, kShippingExe);
    if(shippingExecutables.isEmpty){
      log("[${host ? 'HOST' : 'GAME'}] No game executable found");
      _onStop(
          reason: _StopReason.missingExecutableError,
          error: kShippingExe,
          host: host
      );
      return null;
    }

    if(shippingExecutables.length != 1) {
      log("[${host ? 'HOST' : 'GAME'}] Too many game executables found");
      _onStop(
          reason: _StopReason.multipleExecutablesError,
          error: kShippingExe,
          host: host
      );
      return null;
    }

    log("[${host ? 'HOST' : 'GAME'}] Generating instance args...");
    final gameArgs = createRebootArgs(
        host ? _hostingController.accountUsername.text : _gameController.username.text,
        host ? _hostingController.accountPassword.text : _gameController.password.text,
        host,
        headless,
        false,
        host ? _hostingController.customLaunchArgs.text : _gameController.customLaunchArgs.text
    );
    log("[${host ? 'HOST' : 'GAME'}] Generated game args: ${gameArgs.join(" ")}");
    final gameProcess = await startProcess(
        executable: shippingExecutables.first,
        args: gameArgs,
        useTempBatch: false,
        name: "${version.gameVersion}-${host ? 'HOST' : 'GAME'}",
        environment: {
          "OPENSSL_ia32cap": "~0x20000000"
        }
    );
    final instance = host ? _hostingController.instance.value : _gameController.instance.value;
    void onGameOutput(String line, bool error) {
      log("[${host ? 'HOST' : 'GAME'}] ${error ? '[ERROR]' : '[MESSAGE]'} $line");
      handleGameOutput(
          line: line,
          host: host,
          onShutdown: () {
            log("[${host ? 'HOST' : 'GAME'}] Called shutdown");
            _onStop(reason: _StopReason.normal, host: host);
          },
          onTokenError: () {
            log("[${host ? 'HOST' : 'GAME'}] Called token error");
            _onStop(reason: _StopReason.tokenError, host: host);
          },
          onBuildCorrupted: () {
            if(instance == null) {
              log("[${host ? 'HOST' : 'GAME'}] Called build corrupted: no instance");
              return;
            }else if(!instance.launched) {
              log("[${host ? 'HOST' : 'GAME'}] Called build corrupted: not launched");
              _onStop(reason: _StopReason.corruptedVersionError, host: host);
            }else {
              log("[${host ? 'HOST' : 'GAME'}] Called build corrupted: crash");
              _onStop(reason: _StopReason.crash, host: host);
            }
          },
          onLoggedIn: () {
            log("[${host ? 'HOST' : 'GAME'}] Called logged in");
            _onLoggedIn(host);
          },
          onMatchEnd: () {
            log("[${host ? 'HOST' : 'GAME'}] Called match end");
            _onMatchEnd(version);
          }
      );
    }
    gameProcess.stdOutput.listen((line) => onGameOutput(line, false));
    gameProcess.stdError.listen((line) => onGameOutput(line, true));
    gameProcess.exitCode.then((_) async {
      final instance = host ? _hostingController.instance.value : _gameController.instance.value;
      instance?.killed = true;
      log("[${host ? 'HOST' : 'GAME'}] Called exit code(launched: ${instance?.launched}): stop signal");
      _onStop(
          reason: _StopReason.exitCode,
          host: host
      );
    });
    return gameProcess.pid;
  }

  Future<int?> _createPausedProcess(GameVersion version, bool host, String executableName) async {
    log("[${host ? 'HOST' : 'GAME'}] Starting $executableName...");
    final executables = await findFiles(version.location, executableName);
    if(executables.isEmpty){
      return null;
    }

    if(executables.length != 1) {
      log("[${host ? 'HOST' : 'GAME'}] Too many $executableName found: $executables");
      _onStop(
          reason: _StopReason.multipleExecutablesError,
          error: executableName,
          host: host
      );
      return null;
    }

    final process = await startProcess(
        executable: executables.first,
        useTempBatch: false,
        name: "${version.gameVersion}-${basenameWithoutExtension(executables.first.path)}",
        environment: {
          "OPENSSL_ia32cap": "~0x20000000"
        }
    );
    log("[${host ? 'HOST' : 'GAME'}] Started paused $executableName: $process");
    final pid = process.pid;
    suspend(pid);
    return pid;
  }

  void _onMatchEnd(GameVersion version) {
    if(_hostingController.autoRestart.value) {
      final notification = LocalNotification(
        title: translations.gameServerEnd,
        body: translations.gameServerRestart(_kRebootDelay.inSeconds),
      );
      notification.show();
      Future.delayed(_kRebootDelay).then((_) async {
        log("[RESTARTER] Stopping server...");
        await _onStop(
            reason: _StopReason.normal,
            host: true
        );
        log("[RESTARTER] Stopped server");
        log("[RESTARTER] Starting server...");
        await _toggle(
            host: true
        );
        log("[RESTARTER] Started server");
      });
    }else {
      final notification = LocalNotification(
          title: translations.gameServerEnd,
          body: translations.gameServerShutdown(_kRebootDelay.inSeconds)
      );
      notification.show();
      Future.delayed(_kRebootDelay).then((_) {
        log("[RESTARTER] Stopping server...");
        _onStop(
            reason: _StopReason.normal,
            host: true
        );
        log("[RESTARTER] Stopped server");
      });
    }
  }

  Future<void> _onLoggedIn(bool host) async {
    final instance = host ? _hostingController.instance.value : _gameController.instance.value;
    if(instance != null && !instance.launched) {
      instance.launched = true;
      instance.tokenError = false;
      if(_isChapterOne(instance.version)) {
        await _injectOrShowError(GameDll.memoryLeak, host);
      }
      if(!host){
        await _injectOrShowError(GameDll.console, host);
        _onGameClientInjected();
      }else {
        final gameServerPort = int.tryParse(_dllController.gameServerPort.text);
        if(gameServerPort != null) {
          await killProcessByPort(gameServerPort);
        }
        await _injectOrShowError(GameDll.gameServer, host);
        _onGameServerInjected();
      }
    }
  }

  bool _isChapterOne(String version) {
    try {
      return Version.parse(version).major < 10;
    } on FormatException catch(_) {
      return true;
    }
  }

  void _onGameClientInjected() {
    _gameClientInfoBar?.close();
    showRebootInfoBar(
        translations.gameClientStarted,
        severity: InfoBarSeverity.success,
        duration: infoBarLongDuration
    );
  }

  Future<void> _onGameServerInjected() async {
    if(_gameServerInfoBar != null) {
      _gameServerInfoBar?.close();
    }else {
      _gameClientInfoBar?.close();
    }

    try {
      final gameServerPort = _dllController.gameServerPort.text;
      final started = await _checkLocalGameServer(gameServerPort);
      if(!started) {
        if (_hostingController.instance.value?.killed != true) {
          showRebootInfoBar(
              translations.gameServerStartWarning,
              severity: InfoBarSeverity.error,
              duration: infoBarLongDuration
          );
        }
        return;
      }
      _backendController.gameServerAddress.text = kDefaultGameServerHost;

      final accessible = await _checkPublicGameServer(gameServerPort);
      if (!accessible) {
        showRebootInfoBar(
          translations.gameServerStartLocalWarning,
          severity: InfoBarSeverity.warning,
          duration: infoBarLongDuration,
          action: Button(
            onPressed: () => launchUrlString("https://github.com/Auties00/reboot_launcher/blob/master/documentation/$currentLocale/PortForwarding.md"),
            child: Text(translations.checkGameServerFixAction),
          ),
        );
        return;
      }

      final serverBrowserEntry = await _hostingController.createServerBrowserEntry();
      await _serverBrowserController.addServer(serverBrowserEntry);
      showRebootInfoBar(
          translations.gameServerStarted,
          severity: InfoBarSeverity.success,
          duration: infoBarLongDuration
      );
    }finally {
      _gameServerInfoBar?.close();
    }
  }

  Future<bool> _checkLocalGameServer(String gameServerPort) async {
    try {
      _gameServerInfoBar = showRebootInfoBar(
          translations.waitingForGameServer,
          loading: true,
          duration: null
      );
      final gameServerPort = _dllController.gameServerPort.text;
      final pingOperation = pingGameServerOrTimeout(
          "127.0.0.1:$gameServerPort",
          const Duration(minutes: 2)
      );
      this._pingOperation = pingOperation;
      final localPingResult = await pingOperation.future;
      _gameServerInfoBar?.close();
      return localPingResult;
    }catch(_) {
      _gameServerInfoBar?.close();
      return false;
    }
  }


  Future<bool> _checkPublicGameServer(String gameServerPort) async {
    try {
      _gameServerInfoBar = showRebootInfoBar(
          translations.checkingGameServer,
          loading: true,
          duration: null
      );
      final publicIp = await Ipify.ipv4();
      var pingOperation = await pingGameServerOrTimeout(
          "$publicIp:$gameServerPort",
          const Duration(seconds: 10)
      );
      _pingOperation = pingOperation;
      var publicPingResult = await pingOperation.future;
      if (publicPingResult) {
        _gameServerInfoBar?.close();
        return true;
      }

      final gateway = await Gateway.discover();
      if (gateway == null) {
        _gameServerInfoBar?.close();
        return false;
      }

      final forwarded = await gateway.openPort(
          protocol: PortType.udp,
          externalPort: int.parse(gameServerPort),
          portDescription: "Reboot Game Server"
      );
      if (!forwarded) {
        _gameServerInfoBar?.close();
        return false;
      }

      // Give the modem a couple of seconds just in case
      // This is not technically necessary, but I can't guarantee that the modem has no race conditions
      // So might as well wait
      await Future.delayed(const Duration(seconds: 5));

      pingOperation = await pingGameServerOrTimeout(
          "$publicIp:$gameServerPort",
          const Duration(seconds: 10)
      );
      _pingOperation = pingOperation;
      publicPingResult = await pingOperation.future;
      _gameServerInfoBar?.close();
      return publicPingResult;
    }catch(_) {
      _gameServerInfoBar?.close();
      return false;
    }
  }

  Future<void> _onStop({
    required _StopReason reason,
    required bool host,
    String? error,
    StackTrace? stackTrace,
    bool interactive = true
  }) async {
    if(host) {
      try {
        _pingOperation?.complete(false);
      } catch (_) {
        // Ignore: might have been already terminated, don't bother checking
      } finally {
        _pingOperation = null;
      }
    }

    await _operation?.cancel();
    _operation = null;

    final instance = host ? _hostingController.instance.value : _gameController.instance.value;

    if(host){
      _hostingController.instance.value = null;
    }else {
      _gameController.instance.value = null;
    }

    log("[${host ? 'HOST' : 'GAME'}] Called stop with reason $reason, error data $error $stackTrace");
    log("[${host ? 'HOST' : 'GAME'}] Caller: ${StackTrace.current}");
    if(host) {
      _serverBrowserController.removeServer(_hostingController.uuid);
    }

    if(reason == _StopReason.normal) {
      instance?.launched = true;
    }

    instance?.kill();
    final child = instance?.child;
    if(child != null) {
      await _onStop(
          reason: reason,
          host: child.host,
          error: error,
          stackTrace: stackTrace,
          interactive: false
      );
    }

    _setStarted(host, false);

    if(interactive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if(host == true) {
          _gameServerInfoBar?.close();
        }else {
          _gameClientInfoBar?.close();
        }
      });

      switch(reason) {
        case _StopReason.backendError:
        case _StopReason.matchmakerError:
        case _StopReason.normal:
          break;
        case _StopReason.missingVersionError:
          showRebootInfoBar(
            translations.missingVersionError,
            severity: InfoBarSeverity.error,
            duration: infoBarLongDuration,
          );
          break;
        case _StopReason.missingExecutableError:
          showRebootInfoBar(
            translations.missingExecutableError,
            severity: InfoBarSeverity.error,
            duration: infoBarLongDuration,
          );
          break;
        case _StopReason.multipleExecutablesError:
          showRebootInfoBar(
            translations.multipleExecutablesError(error ?? translations.unknown),
            severity: InfoBarSeverity.error,
            duration: infoBarLongDuration,
          );
          break;
        case _StopReason.exitCode:
          if(instance != null && !instance.launched) {
            final injectedDlls = instance.injectedDlls;
            showRebootInfoBar(
              translations.corruptedVersionError(injectedDlls.isEmpty ? translations.none : injectedDlls.map((element) => element.name).join(", ")),
              severity: InfoBarSeverity.error,
              duration: infoBarLongDuration,
            );
          }
          break;
        case _StopReason.corruptedVersionError:
          final injectedDlls = instance?.injectedDlls ?? [];
          showRebootInfoBar(
              translations.corruptedVersionError(injectedDlls.isEmpty ? translations.none : injectedDlls.map((element) => element.name).join(", ")),
              severity: InfoBarSeverity.error,
              duration: infoBarLongDuration,
              action: Button(
                onPressed: () => launchUrl(launcherLogFile.uri),
                child: Text(translations.openLog),
              )
          );
          break;
        case _StopReason.corruptedDllError:
          showRebootInfoBar(
            translations.corruptedDllError(error ?? translations.unknownError),
            severity: InfoBarSeverity.error,
            duration: infoBarLongDuration,
          );
          break;
        case _StopReason.missingCustomDllError:
          showRebootInfoBar(
            translations.missingCustomDllError(error!),
            severity: InfoBarSeverity.error,
            duration: infoBarLongDuration,
          );
          break;
        case _StopReason.tokenError:
          if (!kClient) {
    _backendController.stop();
  }
          final injectedDlls = instance?.injectedDlls;
          showRebootInfoBar(
              translations.tokenError(injectedDlls == null || injectedDlls.isEmpty ? translations.none : injectedDlls.map((element) => element.name).join(", ")),
              severity: InfoBarSeverity.error,
              duration: infoBarLongDuration,
              action: Button(
                onPressed: () => launchUrl(launcherLogFile.uri),
                child: Text(translations.openLog),
              )
          );
          break;
        case _StopReason.crash:
          showRebootInfoBar(
            translations.fortniteCrashError(host ? translations.gameServer : translations.client),
            severity: InfoBarSeverity.error,
            duration: infoBarLongDuration,
          );
          break;
        case _StopReason.unknownError:
          showRebootInfoBar(
            translations.unknownFortniteError(error ?? translations.unknownError),
            severity: InfoBarSeverity.error,
            duration: infoBarLongDuration,
          );
          break;
        case _StopReason.gameServerPortError:
          showRebootInfoBar(
            translations.gameServerPortEqualsBackendPort(kDefaultBackendPort),
            severity: InfoBarSeverity.error,
            duration: infoBarLongDuration,
          );
          break;
      }
    }
  }

  Future<void> _injectOrShowError(GameDll injectable, bool hosting) async {
    final instance = hosting ? _hostingController.instance.value : _gameController.instance.value;
    if (instance == null) {
      log("[${hosting ? 'HOST' : 'GAME'}] No instance found to inject ${injectable.name}");
      return;
    }

    try {
      final gameProcess = instance.gamePid;
      log("[${hosting ? 'HOST' : 'GAME'}] Injecting ${injectable.name} into process with pid $gameProcess");
      final dllPath = await _getDllFileOrStop(instance.version, injectable, hosting);
      log("[${hosting ? 'HOST' : 'GAME'}] File to inject for ${injectable.name} at path $dllPath");
      if (dllPath == null) {
        log("[${hosting ? 'HOST' : 'GAME'}] The file doesn't exist");
        return;
      }

      log("[${hosting ? 'HOST' : 'GAME'}] Trying to inject ${injectable
          .name}...");
      await injectDll(gameProcess, dllPath);
      instance.injectedDlls.add(injectable);
      log("[${hosting ? 'HOST' : 'GAME'}] Injected ${injectable.name}");
    } catch (error, stackTrace) {
      log("[${hosting ? 'HOST' : 'GAME'}] Cannot inject ${injectable.name}: $error $stackTrace");
      _onStop(
          reason: _StopReason.corruptedDllError,
          host: hosting,
          error: error.toString(),
          stackTrace: stackTrace
      );
    }
  }

  Future<File?> _getDllFileOrStop(String version, GameDll injectable, bool host) async {
    log("[${host ? 'HOST' : 'GAME'}] Checking dll ${injectable}...");
    final (file, customDll) = _dllController.getInjectableData(version, injectable);
    log("[${host ? 'HOST' : 'GAME'}] Path: ${file.path}, custom: $customDll");
    try {
      await file.readAsBytes();
      log("[${host ? 'HOST' : 'GAME'}] Path exists");
      return file;
    }catch(_) {

    }

    log("[${host ? 'HOST' : 'GAME'}] Path doesn't exist");
    if(customDll) {
      log("[${host ? 'HOST' : 'GAME'}] Custom dll -> no recovery");
      _onStop(
          reason: _StopReason.missingCustomDllError,
          error: injectable.name,
          host: host
      );
      return null;
    }

    log("[${host ? 'HOST' : 'GAME'}] Path does not exist, downloading critical dll again...");
    final result = await _dllController.download(injectable, file.path, force: true);
    if(result) {
      log("[${host ? 'HOST' : 'GAME'}] Downloaded critical dll");
      return file;
    }

    _onStop(reason: _StopReason.normal, host: host);
    return null;
  }

  InfoBarEntry _showLaunchingGameServerWidget() => _gameServerInfoBar = showRebootInfoBar(
      translations.launchingGameServer,
      loading: true,
      duration: null
  );

  InfoBarEntry _showLaunchingGameClientWidget(GameVersion version, bool headless, bool linkedHosting) {
    return _gameClientInfoBar = showRebootInfoBar(
        linkedHosting ? translations.launchingGameClientAndServer : translations.launchingGameClientOnly,
        loading: true,
        duration: null,
        action: Obx(() {
          if(_hostingController.started.value || linkedHosting) {
            return const SizedBox.shrink();
          }

          return Padding(
            padding: const EdgeInsets.only(
                bottom: 2.0
            ),
            child: Button(
              onPressed: () async {
                _backendController.gameServerAddress.text = kClient ? kClientBackendHost : kDefaultGameServerHost;

                if(!_hostingController.started.value) {
                  _gameController.instance.value?.child = await _startMatchMakingServer(version, false, headless, true);
                  _gameClientInfoBar?.close();
                  _showLaunchingGameClientWidget(version, headless, true);
                }
              },
              child: Text(translations.startGameServer),
            ),
          );
        })
    );
  }
}

enum _StopReason {
  normal,
  missingVersionError,
  missingExecutableError,
  multipleExecutablesError,
  corruptedVersionError,
  missingCustomDllError,
  corruptedDllError,
  backendError,
  matchmakerError,
  tokenError,
  unknownError,
  gameServerPortError,
  exitCode,
  crash;

  bool get isError => name.contains("Error");
}