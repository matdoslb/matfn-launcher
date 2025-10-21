import 'dart:async';
import 'dart:collection';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:get/get.dart';
import 'package:reboot_launcher/src/pager/page_type.dart';
import 'package:reboot_launcher/src/messenger/overlay.dart';
import 'package:reboot_launcher/src/pager/abstract_page.dart';
import 'package:reboot_launcher/src/page/play_page.dart';
import 'package:reboot_launcher/src/page/settings_page.dart';
import 'package:reboot_launcher/src/messenger/info_bar_area.dart';
import 'package:reboot_launcher/src/page/download.dart'; // <— add

final StreamController<void> pagesController = StreamController.broadcast();
bool hitBack = false;

// Only keep the two client pages
final List<AbstractPage> pages = [
  const PlayPage(),
  const SettingsPage(),
];

// If other code still uses PageType.*, map to visible indices here:
final List<PageType> _visiblePageTypes = [
  PageType.play,
  PageType.settings,
];

// Normalize any raw index to a safe one (default to 0 = Play)
int _norm(int i) => (i < 0 || i >= pages.length) ? 0 : i;

// Helper you can call anywhere instead of assigning .index directly
void setPageByType(PageType t) {
  final i = _visiblePageTypes.indexOf(t);
  pageIndex.value = i >= 0 ? i : 0;
}

// Create flyout keys matching pages length
final List<GlobalKey<OverlayTargetState>> _flyoutPageControllers =
    List.generate(pages.length, (_) => GlobalKey());

// Start on Play (0). Using 0 avoids old enum indices causing OOB.
final RxInt pageIndex = RxInt(0);

final HashMap<int, GlobalKey> _pageKeys = HashMap();

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey();

final GlobalKey<OverlayState> appOverlayKey = GlobalKey();

final GlobalKey<InfoBarAreaState> infoBarAreaKey = GlobalKey();

// Always use normalized index for keys/pages
GlobalKey get pageKey => getPageKeyByIndex(_norm(pageIndex.value));

GlobalKey getPageKeyByIndex(int index) {
  index = _norm(index);
  final key = _pageKeys[index];
  if (key != null) return key;

  final result = GlobalKey();
  _pageKeys[index] = result;
  return result;
}

// Guard .hasButton / currentPage with normalized index
bool get hasPageButton => currentPage.hasButton(currentPageStack.lastOrNull);

AbstractPage get currentPage => pages[_norm(pageIndex.value)];

// --- Back stack wiring (kept as-is, but clamp indices) ---
final Queue<Object?> appStack = _createAppStack();
Queue _createAppStack() {
  final queue = Queue();
  var lastValue = _norm(pageIndex.value);
  pageIndex.listen((index) {
    // Clamp invalid indices coming from elsewhere in the app
    final safeIndex = _norm(index);
    if (safeIndex != index) {
      hitBack = true;            // don't push to stack for a correction
      pageIndex.value = safeIndex;
      return;
    }

    if (!hitBack && lastValue != index) {
      queue.add(lastValue);
      pagesController.add(null);
    }

    hitBack = false;
    lastValue = index;
  });
  return queue;
}

// Per-page sub-stacks, sized to pages.length
final Map<int, Queue<String>> _pagesStack =
    Map.fromEntries(List.generate(pages.length, (i) => MapEntry(i, Queue<String>())));

Queue<String> get currentPageStack => _pagesStack[_norm(pageIndex.value)]!;

void addSubPageToCurrent(String pageName) {
  final i = _norm(pageIndex.value);
  appStack.add(pageName);
  _pagesStack[i]!.add(pageName);
  pagesController.add(null);
}

// Overlay target keys – also normalized
GlobalKey<OverlayTargetState> getOverlayTargetKeyByPage(int i) =>
    _flyoutPageControllers[_norm(i)];

GlobalKey<OverlayTargetState> get pageOverlayTargetKey =>
    _flyoutPageControllers[_norm(pageIndex.value)];
