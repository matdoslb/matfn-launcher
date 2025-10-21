import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart' as fluentIcons show FluentIcons;
import 'package:fluent_ui/fluent_ui.dart' hide FluentIcons;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding; // for addPostFrameCallback
import 'package:get/get.dart';
import 'package:reboot_launcher/src/util/os.dart';
import 'package:reboot_launcher/src/util/translations.dart';
import 'package:reboot_launcher/src/button/file_selector.dart';
import 'package:reboot_launcher/src/tile/setting_tile.dart';

const double _kButtonDimensions = 30;
const double _kButtonSpacing = 8;

/// Builds a SettingTile with a file selector and two buttons (browse/reset).
/// NOTE: validator is PURE. Any state (padding) update happens post-frame.
SettingTile createFileSetting({
  required GlobalKey<TextFormBoxState> key,
  required String title,
  required String description,
  required TextEditingController controller,
  required void Function() onReset,
}) {
  final RxnString errorTextRx = RxnString();    // reflects current validator result
  final RxBool selecting = RxBool(false);

  String? validate(String? text) {
    final result = _checkDll(text);              // PURE: compute message only
    // reflect error text AFTER the current frame (avoid setState during build)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      errorTextRx.value = result;
    });
    return result;
  }

  void revalidateAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      key.currentState?.validate();
    });
  }

  return SettingTile(
    icon: const Icon(FluentIcons.document_24_regular),
    title: Text(title),
    subtitle: Text(description),
    contentWidth: SettingTile.kDefaultContentWidth + _kButtonDimensions,
    content: Row(
      children: [
        Expanded(
          child: FileSelector(
            placeholder: translations.selectPathPlaceholder,
            windowTitle: translations.selectPathWindowTitle,
            controller: controller,
            validator: validate,
            extension: "dll",
            folder: false,
            validatorMode: AutovalidateMode.always,
            allowNavigator: false,
            validatorKey: key,
          ),
        ),
        const SizedBox(width: _kButtonSpacing),

        // Open file picker
        Obx(() {
          final hasError = errorTextRx.value != null;
          return Padding(
            padding: EdgeInsets.only(bottom: hasError ? 20.0 : 0.0),
            child: Tooltip(
              message: translations.selectFile,
              child: Button(
                style: ButtonStyle(padding: WidgetStateProperty.all(EdgeInsets.zero)),
                onPressed: () => _onPressed(selecting, controller, afterPick: revalidateAfterFrame),
                child: SizedBox.square(
                  dimension: _kButtonDimensions,
                  child: Icon(fluentIcons.FluentIcons.open_folder_horizontal),
                ),
              ),
            ),
          );
        }),
        const SizedBox(width: _kButtonSpacing),

        // Reset to default path
        Obx(() {
          final hasError = errorTextRx.value != null;
          return Padding(
            padding: EdgeInsets.only(bottom: hasError ? 20.0 : 0.0),
            child: Tooltip(
              message: translations.reset,
              child: Button(
                style: ButtonStyle(padding: WidgetStateProperty.all(EdgeInsets.zero)),
                onPressed: () {
                  onReset();
                  revalidateAfterFrame(); // <- validate after UI settles
                },
                child: SizedBox.square(
                  dimension: _kButtonDimensions,
                  child: const Icon(FluentIcons.arrow_reset_24_regular),
                ),
              ),
            ),
          );
        }),
      ],
    ),
  );
}

void _onPressed(
  RxBool selecting,
  TextEditingController controller, {
  VoidCallback? afterPick,
}) {
  if (selecting.value) return;

  selecting.value = true;
  compute(openFilePicker, "dll")
      .then((value) => _updateText(controller, value))
      .whenComplete(() => selecting.value = false)
      .whenComplete(() {
        // revalidate after the picker finishes
        if (afterPick != null) afterPick();
      });
}

void _updateText(TextEditingController controller, String? value) {
  final text = value ?? controller.text;
  controller.text = text;
  controller.selection = TextSelection.collapsed(offset: text.length);
}

String? _checkDll(String? text) {
  final v = text?.trim() ?? '';
  if (v.isEmpty) return translations.invalidDllPath;

  final file = File(v);
  try {
    file.readAsBytesSync(); // existence + readable check
  } catch (_) {
    return translations.dllDoesNotExist;
  }

  if (!v.toLowerCase().endsWith(".dll")) {
    return translations.invalidDllExtension;
  }
  return null;
}
