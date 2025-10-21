// lib/src/game/game_downloader.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:reboot_common/common.dart';

// =====================================================================
// Public API (unchanged)
// =====================================================================

const String kStopBuildDownloadSignal = "kill";

Future<void> stopDownloadServer() async {
  // kept for compatibility; no background server used here
}

final List<GameBuild> downloadableBuilds = [
  GameBuild(
    gameVersion: "7.20",
    link: "https://builds.rebootfn.org/7.20.rar",
    available: true,
  ),
];

// =====================================================================
// Progress / lifecycle helpers
// =====================================================================

void _emitProgress(
  SendPort port, {
  required double pct, // 0..100
  required int speedBps,
  required int etaMinutes, // -1 if unknown
}) {
  port.send(GameBuildDownloadProgress(
    progress: pct,
    extracting: false,
    timeLeft: etaMinutes < 0 ? null : etaMinutes,
    speed: speedBps,
  ));
}

void _emitExtractProgress(
  SendPort port, {
  required double pct, // 0..100
  int? etaMinutes, // nullable during extraction
}) {
  port.send(GameBuildDownloadProgress(
    progress: pct,
    extracting: true,
    timeLeft: etaMinutes,
    speed: 0,
  ));
}

void _emitError(SendPort port, String message) {
  port.send(message); // UI expects a String on error
}

Completer<dynamic> _setupLifecycle(GameBuildDownloadOptions options) {
  final stopped = Completer();
  final lifecyclePort = ReceivePort();
  lifecyclePort.listen((message) {
    if (message == kStopBuildDownloadSignal && !stopped.isCompleted) {
      lifecyclePort.close();
      stopped.complete();
    }
  });
  options.port.send(lifecyclePort.sendPort);
  return stopped;
}

// =====================================================================
// Curl-first downloader with stall watchdog (fallback: Dart+Range)
// =====================================================================

const Duration _stallTimeout = Duration(seconds: 20); // no byte growth => restart
const Duration _tickEvery = Duration(milliseconds: 500);

String? _whichCurl() {
  final envPath = Platform.environment['PATH'] ?? '';
  for (final dir in envPath.split(Platform.isWindows ? ';' : ':')) {
    final exe = File(p.join(dir, Platform.isWindows ? 'curl.exe' : 'curl'));
    if (exe.existsSync()) return exe.path;
  }
  if (Platform.isWindows) {
    final sys32 = File(r"C:\Windows\System32\curl.exe");
    if (sys32.existsSync()) return sys32.path;
  }
  return null;
}

Future<int?> _headContentLength(Uri url) async {
  final client = HttpClient()
    ..userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126 Safari/537.36"
    ..autoUncompress = true;
  try {
    final req = await client.openUrl("HEAD", url);
    req.headers.set(HttpHeaders.acceptHeader, "*/*");
    final resp = await req.close().timeout(const Duration(seconds: 20));
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final len = resp.headers.value(HttpHeaders.contentLengthHeader);
      final n = len == null ? null : int.tryParse(len);
      if (n != null && n > 0) return n;
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    try { client.close(force: true); } catch (_) {}
  }
}

Future<void> _downloadWithCurlPollProgress({
  required Uri url,
  required File outFile,
  required int? contentLength,
  required SendPort port,
  required Completer<dynamic> stopped,
}) async {
  final curl = _whichCurl();
  if (curl == null) throw "curl not found";

  await outFile.parent.create(recursive: true);

  final ua =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126 Safari/537.36";
  final baseArgs = <String>[
    "--location",
    "--fail",
    "--retry", "5",
    "--retry-delay", "2",
    "--continue-at", "-",
    "--user-agent", ua,
    "--header", "Accept: */*",
    "--output", outFile.path,
    url.toString(),
  ];

  // transient exit codes we will resume from
  bool _isTransient(int code) =>
      code == -1 || // killed by us (watchdog)
      <int>{7, 18, 26, 28, 47, 52, 55, 56, 92}.contains(code);

  // smoothing for Mbps
  final smoothing = <int>[];
  const maxSmooth = 8;

  const maxAttempts = 20;
  var attempt = 0;

  while (!stopped.isCompleted) {
    attempt++;

    // progress poller + stall watchdog state
    int lastSize = outFile.existsSync() ? outFile.lengthSync() : 0;
    var lastGrowth = DateTime.now();
    final tickWin = Stopwatch()..start();
    Timer? ticker;
    var killedByWatchdog = false;

    void startTicker(Process? proc) {
      ticker?.cancel();
      ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (stopped.isCompleted) return;

        int sizeNow;
        try {
          sizeNow = outFile.existsSync() ? outFile.lengthSync() : lastSize;
        } catch (_) {
          sizeNow = lastSize;
        }

        final dt = tickWin.elapsedMilliseconds / 1000.0;
        final delta = sizeNow - lastSize;
        final inst = dt > 0 ? (delta / dt).round() : 0;

        if (delta > 0) lastGrowth = DateTime.now();

        // smooth speed
        smoothing.add(inst);
        if (smoothing.length > maxSmooth) smoothing.removeAt(0);
        final speed = smoothing.isEmpty
            ? inst
            : (smoothing.reduce((a, b) => a + b) / smoothing.length).round();

        double pct = 0.0;
        int eta = -1;
        if (contentLength != null && contentLength > 0) {
          pct = (sizeNow / contentLength) * 100.0;
          final remain = contentLength - sizeNow;
          eta = speed > 0 ? ((remain / speed) / 60).ceil() : -1;
        }
        _emitProgress(port, pct: pct, speedBps: speed, etaMinutes: eta);

        // stall watchdog: if no growth for 20s, kill curl so we can resume
        if (DateTime.now().difference(lastGrowth) > const Duration(seconds: 20)) {
          killedByWatchdog = true;
          ticker?.cancel();
          try { proc?.kill(ProcessSignal.sigterm); } catch (_) {}
        }

        tickWin
          ..reset()
          ..start();
        lastSize = sizeNow;
      });
    }

    // run curl
    final args = List<String>.from(baseArgs);
    final stderrLines = <String>[];
    final proc = await Process.start(curl, args, runInShell: true);

    proc.stderr
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final t = line.trim();
      if (t.isNotEmpty) {
        stderrLines.add(t);
        if (stderrLines.length > 120) stderrLines.removeAt(0);
      }
    });

    startTicker(proc);

    final exitFut = proc.exitCode;
    await Future.any([stopped.future, exitFut]);
    ticker?.cancel();

    if (stopped.isCompleted) {
      try { proc.kill(ProcessSignal.sigterm); } catch (_) {}
      return;
    }

    final code = await exitFut;

    // If we reached full size, accept success regardless of exit code.
    if (contentLength != null &&
        contentLength > 0 &&
        (outFile.existsSync() ? outFile.lengthSync() >= contentLength : false)) {
      _emitProgress(port, pct: 100, speedBps: 0, etaMinutes: 0);
      return;
    }

    // Clean exit but still short: try resuming (server lied or no length)
    if (code == 0) {
      if (contentLength == null || contentLength <= 0) {
        // no length to compare against — accept as success
        return;
      }
      if (attempt >= maxAttempts) {
        throw "curl finished but file incomplete after $attempt attempts "
              "(${outFile.lengthSync()} of $contentLength bytes)";
      }
      await Future.any([
        Future.delayed(const Duration(seconds: 2)),
        stopped.future,
      ]);
      continue;
    }

    // Watchdog kill or known transient error — resume
    if (killedByWatchdog || _isTransient(code)) {
      if (attempt >= maxAttempts) {
        final tail = stderrLines.isEmpty ? "" : "\n${stderrLines.join('\n')}";
        throw "curl aborted (code $code) after $attempt attempts$tail";
      }
      await Future.any([
        Future.delayed(Duration(seconds: attempt.clamp(1, 8))),
        stopped.future,
      ]);
      continue;
    }

    // Non-transient: bubble up details
    final tail = stderrLines.isEmpty ? "" : "\n${stderrLines.join('\n')}";
    throw "curl exited with $code$tail";
  }
}


Future<void> _downloadWithDartHttp({
  required Uri url,
  required File outFile,
  required SendPort port,
  required Completer<dynamic> stopped,
  required int? knownTotalLength, // may be null
}) async {
  // We resume with Range, looping until complete or stopped.
  await outFile.parent.create(recursive: true);
  var offset = outFile.existsSync() ? outFile.lengthSync() : 0;

  // Keep a conservative “best known total”
  int? totalLength = knownTotalLength;

  final client = HttpClient()
    ..userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126 Safari/537.36"
    ..autoUncompress = true
    ..maxConnectionsPerHost = 8
    ..connectionTimeout = const Duration(seconds: 15);

  while (!stopped.isCompleted) {
    IOSink? sink;
    StreamSubscription<List<int>>? sub;
    Timer? stallTimer;

    void resetStallTimer() {
      stallTimer?.cancel();
      stallTimer = Timer(_stallTimeout, () {
        // no bytes for stallTimeout => tear down and resume
        try { sub?.cancel(); } catch (_) {}
        try { sink?.flush(); } catch (_) {}
        try { sink?.close(); } catch (_) {}
      });
    }

    try {
      final req = await client.getUrl(url);
      if (offset > 0) {
        req.headers.set(HttpHeaders.rangeHeader, "bytes=$offset-");
      }
      req.headers.set(HttpHeaders.acceptHeader, "*/*");
      final resp = await req.close();

      if (resp.statusCode != 200 && resp.statusCode != 206) {
        final body = await resp.fold<List<int>>(<int>[], (p, e) => p..addAll(e));
        final snippet = utf8.decode(body, allowMalformed: true);
        throw "HTTP ${resp.statusCode}\n${snippet.length > 600 ? snippet.substring(0,600) : snippet}";
      }

      // Parse total from Content-Range if available
      final cr = resp.headers.value(HttpHeaders.contentRangeHeader); // "bytes start-end/total"
      if (cr != null) {
        final totalStr = cr.split('/').last;
        final t = int.tryParse(totalStr);
        if (t != null && t > 0) totalLength = t;
      } else if (totalLength == null && resp.contentLength > 0) {
        // server ignored Range; treat as full response
        totalLength = resp.contentLength;
        offset = 0; // overwrite from scratch
        await outFile.writeAsBytes([], flush: true);
      }

      sink = outFile.openWrite(mode: FileMode.append);

      int winBytes = 0;
      final win = Stopwatch()..start();
      var lastTick = DateTime.now();

      // emit a first “started/resuming” tick
      _emitProgress(
        port,
        pct: totalLength == null || totalLength == 0 ? 0 : (offset / totalLength! * 100),
        speedBps: 0,
        etaMinutes: -1,
      );

      resetStallTimer();

      sub = resp.listen(
        (chunk) {
          sink!.add(chunk);
          offset += chunk.length;
          winBytes += chunk.length;
          resetStallTimer();

          final now = DateTime.now();
          if (now.difference(lastTick).inMilliseconds >= 300) {
            final dt = win.elapsedMilliseconds / 1000.0;
            final speed = dt > 0 ? (winBytes / dt).round() : 0;
            double pct = 0.0;
            int eta = -1;
            if (totalLength != null && totalLength! > 0) {
              pct = (offset / totalLength!) * 100.0;
              final remain = totalLength! - offset;
              eta = speed > 0 ? ((remain / speed) / 60).ceil() : -1;
            }
            _emitProgress(port, pct: pct, speedBps: speed, etaMinutes: eta);
            win
              ..reset()
              ..start();
            winBytes = 0;
            lastTick = now;
          }
        },
        onDone: () async {
          await sink?.flush();
          await sink?.close();
          stallTimer?.cancel();
        },
        onError: (_) async {
          try { await sink?.close(); } catch (_) {}
          stallTimer?.cancel();
        },
        cancelOnError: true,
      );

      await Future.any([stopped.future, sub.asFuture()]);

      if (stopped.isCompleted) return;

      // Completed?
      if (totalLength != null && offset >= totalLength!) {
        _emitProgress(port, pct: 100, speedBps: 0, etaMinutes: 0);
        return;
      }

      // otherwise: loop will resume (Range) after a short backoff
      await Future.delayed(const Duration(seconds: 2));
    } finally {
      try { await sub?.cancel(); } catch (_) {}
      try { await sink?.close(); } catch (_) {}
      stallTimer?.cancel();
    }
  }

  try { client.close(force: true); } catch (_) {}
}

// =====================================================================
// Single entry point
// =====================================================================

Future<void> downloadArchiveBuild(GameBuildDownloadOptions options) async {
  final url = Uri.parse(options.build.link);
  final fileName =
      options.build.link.substring(options.build.link.lastIndexOf("/") + 1);
  final tempOut = File("${options.destination.path}\\.build\\$fileName");
  final stopped = _setupLifecycle(options);

  try {
    await tempOut.parent.create(recursive: true);
    final probe = File(p.join(tempOut.parent.path, "__probe.tmp"));
    await probe.writeAsBytes([0x0], flush: true);
    await probe.delete();

    final totalLen = await _headContentLength(url);
    final hasCurl = _whichCurl() != null;

    if (hasCurl) {
      await _downloadWithCurlPollProgress(
        url: url,
        outFile: tempOut,
        contentLength: totalLen,
        port: options.port,
        stopped: stopped,
      );
      if (stopped.isCompleted) return;
    } else {
      await _downloadWithDartHttp(
        url: url,
        outFile: tempOut,
        port: options.port,
        stopped: stopped,
        knownTotalLength: totalLen,
      );
      if (stopped.isCompleted) return;
    }

    // Extract (with ETA)
    final ext = p.extension(fileName);
    await _extractArchive(stopped, ext, tempOut, options);

    // Cleanup
    try { if (tempOut.existsSync()) tempOut.deleteSync(); } catch (_) {}
  } catch (e) {
    _emitError(options.port, "Cannot download version: $e");
    try { if (tempOut.existsSync()) tempOut.deleteSync(); } catch (_) {}
  }
}

// =====================================================================
// Extraction with progress + ETA (7zip / WinRAR)
// =====================================================================

final RegExp _rarProgressRegex = RegExp(r"^((100)|(\d{1,2}(\.\d*)?))%$");
final RegExp _anyPct = RegExp(r'(\d+)%');

Future<void> _extractArchive(
  Completer<dynamic> stopped,
  String extension,
  File tempFile,
  GameBuildDownloadOptions options,
) async {
  Process? process;
  switch (extension.toLowerCase()) {
    case ".zip": {
      final sevenZip = File("${assetsDirectory.path}\\build\\7zip.exe");
      if (!sevenZip.existsSync()) throw "Missing 7zip.exe";
      process = await startProcess(
        executable: sevenZip,
        args: ["x", "-bsp1", '-o"${options.destination.path}"', "-y", '"${tempFile.path}"'],
      );
      var completed = false;
      final sw = Stopwatch()..start();
      int lastPct = 0;

      process.stdOutput.listen((data) {
        final lower = data.toLowerCase();
        if (lower.contains("everything is ok")) {
          completed = true;
          _emitExtractProgress(options.port, pct: 100, etaMinutes: 0);
          process?.kill(ProcessSignal.sigabrt);
          return;
        }
        final m = _anyPct.firstMatch(data);
        if (m != null) {
          final pct = int.tryParse(m.group(1) ?? "") ?? lastPct;
          lastPct = pct;
          final p = (pct.clamp(1, 100)) / 100.0;
          final totalMs = (sw.elapsedMilliseconds / p).round();
          final etaMs = totalMs - sw.elapsedMilliseconds;
          final etaMin = etaMs <= 0 ? 0 : (etaMs / 60000).ceil();
          _emitExtractProgress(options.port, pct: pct.toDouble(), etaMinutes: etaMin);
          return;
        }
        final trimmed = data.trim();
        if (trimmed.isNotEmpty) {
          _emitExtractProgress(options.port, pct: lastPct.toDouble());
        }
      });
      process.stdError.listen((data) {
        if (!data.isBlankOrEmpty) _emitError(options.port, data);
      });
      process.exitCode.then((code) {
        if (code != 0 && !completed) _emitError(options.port, "Zip extraction failed (exit $code)");
      });
      break;
    }
    case ".rar": {
      final winrar = File("${assetsDirectory.path}\\build\\winrar.exe");
      if (!winrar.existsSync()) throw "Missing winrar.exe";
      process = await startProcess(
        executable: winrar,
        args: ["x", "-o+", '"${tempFile.path}"', "*.*", '"${options.destination.path}"'],
      );
      var completed = false;
      final sw = Stopwatch()..start();
      int lastPct = 0;

      process.stdOutput.listen((data) {
        data = data.replaceAll("\r", "").replaceAll("\b", "").trim();
        if (data == "All OK") {
          completed = true;
          _emitExtractProgress(options.port, pct: 100, etaMinutes: 0);
          process?.kill(ProcessSignal.sigabrt);
          return;
        }
        final element = _rarProgressRegex.firstMatch(data)?.group(1);
        if (element != null) {
          final pct = int.tryParse(element) ?? lastPct;
          lastPct = pct;
          final p = (pct.clamp(1, 100)) / 100.0;
          final totalMs = (sw.elapsedMilliseconds / p).round();
          final etaMs = totalMs - sw.elapsedMilliseconds;
          final etaMin = etaMs <= 0 ? 0 : (etaMs / 60000).ceil();
          _emitExtractProgress(options.port, pct: pct.toDouble(), etaMinutes: etaMin);
        }
      });
      process.stdError.listen((data) {
        if (!data.isBlankOrEmpty) _emitError(options.port, data);
      });
      process.exitCode.then((code) {
        if (code != 0 && !completed) _emitError(options.port, "RAR extraction failed (exit $code)");
      });
      break;
    }
    default:
      throw ArgumentError("Unexpected file extension: $extension");
  }

  await Future.any([stopped.future, process!.exitCode]);
  try { process.kill(ProcessSignal.sigabrt); } catch (_) {}
}

// =====================================================================
// Small formatters (if you want them in UI)
// =====================================================================

String _fmtBytes(int b) {
  if (b <= 0) return "0 B";
  const kb = 1024.0, mb = kb * 1024, gb = mb * 1024;
  if (b >= gb) return "${(b / gb).toStringAsFixed(2)} GB";
  if (b >= mb) return "${(b / mb).toStringAsFixed(2)} MB";
  if (b >= kb) return "${(b / kb).toStringAsFixed(2)} KB";
  return "$b B";
}

String _fmtEta(int minutes) {
  if (minutes < 0) return "—";
  if (minutes == 0) return "<1m";
  return "${minutes}m";
}

String _fmtMbps(int bytesPerSec) {
  if (bytesPerSec <= 0) return "0 Mbps";
  final mbit = (bytesPerSec * 8) / 1e6;
  return "${mbit.toStringAsFixed(2)} Mbps";
}
