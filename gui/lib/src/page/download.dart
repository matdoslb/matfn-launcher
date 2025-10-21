// lib/src/page/download_page.dart
import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart' hide FluentIcons;
import 'package:fluentui_system_icons/fluentui_system_icons.dart' as sys;
import 'package:reboot_launcher/src/messenger/info_bar.dart';
import 'package:reboot_launcher/src/pager/abstract_page.dart';
import 'package:reboot_launcher/src/pager/page_type.dart';
import 'package:reboot_launcher/src/tile/setting_tile.dart';

// --- Customize these for your build ---
const String _kBuildLabel   = 'Fortnite Build';
const String _kBuildVersion = 'v7.20';
const String _kBuildRarUrl  = 'https://public.simplyblk.xyz/7.20.rar';
const String _kBuildRarName = '7.20.rar';

// Simple installed check — adjust to your layout if needed
bool _isInstalledAt(String dir) {
  final exe = File(
    '$dir\\FortniteGame\\Binaries\\Win64\\FortniteClient-Win64-Shipping.exe',
  );
  return exe.existsSync();
}

class DownloadPage extends AbstractPage {
  const DownloadPage({Key? key}) : super(key: key);

  @override
  String get name => 'Downloads';

  // Point to any icon you already ship
  @override
  String get iconAsset => 'assets/images/download.png';

  @override
  PageType get type => PageType.download;

  @override
  bool hasButton(String? pageName) => false;

  @override
  AbstractPageState<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends AbstractPageState<DownloadPage> {
  late final ValueNotifier<String> _dir;
  late final ValueNotifier<bool> _busy;
  late final ValueNotifier<double> _progress; // 0..1, or 0 while indeterminate
  late final ValueNotifier<String> _status;

  @override
  void initState() {
    super.initState();
    _dir = ValueNotifier<String>(_defaultDir());
    _busy = ValueNotifier<bool>(false);
    _progress = ValueNotifier<double>(0);
    _status = ValueNotifier<String>('');
  }

  @override
  void dispose() {
    _dir.dispose();
    _busy.dispose();
    _progress.dispose();
    _status.dispose();
    super.dispose();
  }

  @override
  List<Widget> get settings => [
        _summaryTile,
        _directoryTile,
        _downloadTile,
      ];

  @override
  Widget? get button => null;

  // ---- tiles ----

  SettingTile get _summaryTile => SettingTile(
        icon: const Icon(sys.FluentIcons.arrow_download_24_regular),
        title: Text('$_kBuildLabel • $_kBuildVersion'),
        subtitle: const Text('Build status'),
        children: [
          ValueListenableBuilder<String>(
            valueListenable: _dir,
            builder: (_, d, __) => Text(
              _isInstalledAt(d) ? 'Installed at selected folder' : 'Not installed',
              style: FluentTheme.of(context).typography.body,
            ),
          ),
        ],
      );

  SettingTile get _directoryTile => SettingTile(
        icon: const Icon(sys.FluentIcons.folder_24_regular),
        title: const Text('Install directory'),
        subtitle: const Text('Choose where the build will be extracted'),
        contentWidth: SettingTile.kDefaultContentWidth + 30,
        content: Row(
          children: [
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: _dir,
                builder: (_, v, __) => TextFormBox(
                  placeholder: 'C:\\Users\\You\\Documents\\FortniteBuild',
                  controller: TextEditingController(text: v)
                    ..selection = TextSelection.collapsed(offset: v.length),
                  onChanged: (t) => _dir.value = t,
                ),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<bool>(
              valueListenable: _busy,
              builder: (_, isBusy, __) => Button(
                onPressed: isBusy ? null : _pickDir,
                child: const Text('Browse…'),
              ),
            ),
            const SizedBox(width: 8),
            Button(
              onPressed: () =>
                  Process.run('explorer.exe', [_dir.value], runInShell: true),
              child: const Text('Open'),
            ),
          ],
        ),
      );

  SettingTile get _downloadTile => SettingTile(
        icon: Icon(sys.FluentIcons.arrow_download_24_regular),
        title: const Text('Download & Install'),
        subtitle: const Text('Fetch the archive and extract it with 7-Zip'),
        children: [
          Row(
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: _busy,
                builder: (_, isBusy, __) {
                  final installed = _isInstalledAt(_dir.value);
                  return FilledButton(
                    onPressed: (isBusy || installed) ? null : _downloadAndExtract,
                    child: Text(installed ? 'Installed' : 'Download & Install'),
                  );
                },
              ),
              const SizedBox(width: 12),
              ValueListenableBuilder<double>(
                valueListenable: _progress,
                builder: (_, p, __) => ValueListenableBuilder<bool>(
                  valueListenable: _busy,
                  builder: (_, isBusy, __) => isBusy
                      ? Expanded(child: ProgressBar(value: p > 0 ? p : null))
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<String>(
            valueListenable: _status,
            builder: (_, s, __) => s.isEmpty
                ? const SizedBox.shrink()
                : Text(s, style: FluentTheme.of(context).typography.caption),
          ),
        ],
      );

  // ---- actions ----

  Future<void> _pickDir() async {
    final chosen = await _askForFolder(context, _dir.value);
    if (chosen != null && chosen.isNotEmpty) _dir.value = chosen;
  }

  Future<void> _downloadAndExtract() async {
    try {
      _busy.value = true;
      _status.value = 'Downloading…';
      _progress.value = 0;

      final target = Directory(_dir.value);
      await target.create(recursive: true);
      final rarPath = '${target.path}\\$_kBuildRarName';

      // download with progress
      final uri = Uri.parse(_kBuildRarUrl);
      final req = await HttpClient().getUrl(uri);
      final res = await req.close();
      if (res.statusCode != 200) {
        throw 'HTTP ${res.statusCode} while fetching $_kBuildRarUrl';
      }
      final total = res.contentLength; // may be -1
      final sink = File(rarPath).openWrite();
      var received = 0;
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) _progress.value = received / total;
      }
      await sink.close();

      // extract with 7-Zip
      _status.value = 'Extracting…';
      final sevenZip = _find7z();
      if (sevenZip == null) {
        throw '7-Zip not found. Install 7-Zip or place 7z.exe next to the launcher.';
      }
      final proc = await Process.start(
        sevenZip,
        ['x', rarPath, '-o${target.path}', '-y'],
        runInShell: true,
      );
      proc.stdout.transform(SystemEncoding().decoder).listen((s) {
        final t = s.trim();
        if (t.isNotEmpty) _status.value = 'Extracting… $t';
      });
      proc.stderr.transform(SystemEncoding().decoder).listen((s) {
        final t = s.trim();
        if (t.isNotEmpty) _status.value = 'Extracting… $t';
      });
      final code = await proc.exitCode;
      if (code != 0) throw '7-Zip failed with exit code $code';

      // clean up archive (optional)
      try {
        await File(rarPath).delete();
      } catch (_) {}

      _status.value = 'Done!';
      showRebootInfoBar('$_kBuildLabel $_kBuildVersion installed',
          severity: InfoBarSeverity.success);
      setState(() {}); // re-evaluate "Installed" state
    } catch (e) {
      _status.value = 'Failed';
      showRebootInfoBar('Download failed: $e', severity: InfoBarSeverity.error);
    } finally {
      _busy.value = false;
      _progress.value = 0;
    }
  }
}

// ---- helpers ----

Future<String?> _askForFolder(BuildContext context, String current) async {
  final controller = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (ctx) => ContentDialog(
      title: const Text('Choose folder'),
      content: TextBox(controller: controller),
      actions: [
        Button(child: const Text('Cancel'), onPressed: () => Navigator.pop(ctx)),
        FilledButton(
          child: const Text('OK'),
          onPressed: () => Navigator.pop(ctx, controller.text),
        ),
      ],
    ),
  );
}

String? _find7z() {
  final candidates = <String>[
    '${Directory.current.path}\\7z.exe',
    'C:\\Program Files\\7-Zip\\7z.exe',
    'C:\\Program Files (x86)\\7-Zip\\7z.exe',
  ];
  for (final p in candidates) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

String _defaultDir() {
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      Directory.current.path;
  return '$home\\Documents\\FortniteBuild';
}
