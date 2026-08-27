part of '../tiff_viewer_page.dart';

/// A best-effort, in-process memory signal used to size decode/cache
/// budgets adaptively instead of leaning on one fixed constant everywhere.
///
/// There's no cross-platform way for a sandboxed app to see *system-wide*
/// free memory — iOS in particular never exposes it to an app at all, and
/// getting it on Android/desktop would mean a platform channel per OS. The
/// one portable signal `dart:io` offers is the app's own resident set size
/// ([ProcessInfo.currentRss]), which is what this tracks. [totalBudgetBytes]
/// is a self-imposed ceiling this app tries to keep its own memory under —
/// "available" here means "headroom under that ceiling", not "free RAM on
/// the device". [ProcessInfo.currentRss] covers the whole OS process, so
/// this reads the same regardless of which isolate calls it (a worker
/// isolate spawned via [Isolate.spawn] shares the main isolate's process).
class _MemoryMonitor {
  const _MemoryMonitor._();

  /// Suggested starting point for [totalBudgetBytes] — reasonable for a
  /// typical dev machine, but not a measurement of anything: there's no way
  /// for this app to know how loaded the rest of the machine actually is
  /// (see the class doc comment), so this is just a fixed, sane default the
  /// UI can offer and the user is free to override.
  static const defaultTotalBudgetBytes = 512 * 1024 * 1024;

  /// Smallest/largest value the UI lets a user set [totalBudgetBytes] to —
  /// below [_minTotalBudgetBytes] there's not enough headroom left for any
  /// adaptive budget to make real progress; above [_maxTotalBudgetBytes]
  /// there's no real benefit and it stops meaningfully protecting anything.
  static const _minTotalBudgetBytes = 64 * 1024 * 1024;
  static const _maxTotalBudgetBytes = 8192 * 1024 * 1024;

  /// Soft ceiling this app aims to keep its own RSS under — user-settable
  /// (see [setTotalBudgetBytes]), starting from [defaultTotalBudgetBytes].
  /// This only bounds *this app's own* footprint (see the class doc comment
  /// on why — no sandboxed app can see true system-wide free memory), so it
  /// says nothing about how much RAM the rest of a loaded machine has
  /// already claimed — a dev machine running a browser, an editor, and
  /// other background apps can be under real memory pressure well before
  /// this app claims anywhere near its own ceiling; a user who knows their
  /// machine is tight on RAM (or has plenty to spare) can dial this down
  /// (or up) accordingly.
  static int totalBudgetBytes = defaultTotalBudgetBytes;

  /// Sets [totalBudgetBytes], clamped to a sane range so a stray UI input
  /// can't produce a budget too small to make progress or large enough to
  /// stop meaning anything.
  static void setTotalBudgetBytes(int bytes) {
    totalBudgetBytes = bytes.clamp(_minTotalBudgetBytes, _maxTotalBudgetBytes);
  }

  /// Every adaptive budget derived from [availableBudgetBytes] is clamped
  /// to at least this — even right at the ceiling, a decode call still
  /// needs *some* memory to make progress, and 0 would mean an infinite
  /// loop (a band/chunk height of 0 never advances).
  static const _minBudgetBytes = 16 * 1024 * 1024;

  static bool? _supported;

  /// Whether [currentRssBytes] returns a real reading on this platform.
  /// `ProcessInfo.currentRss` isn't implemented everywhere (Windows in
  /// particular) — callers should fall back to a fixed budget when this is
  /// false rather than trust a bogus reading.
  static bool get isSupported {
    final cached = _supported;
    if (cached != null) return cached;
    bool supported;
    try {
      // A real process is never actually 0 bytes RSS — treat that as "no
      // real implementation behind this" too, not just an outright throw.
      supported = ProcessInfo.currentRss > 0;
    } catch (_) {
      supported = false;
    }
    _supported = supported;
    return supported;
  }

  /// The app's current resident set size, or 0 if unavailable — check
  /// [isSupported] before trusting a 0 as a real measurement.
  static int currentRssBytes() {
    if (!isSupported) return 0;
    try {
      return ProcessInfo.currentRss;
    } catch (_) {
      return 0;
    }
  }

  /// Headroom under [totalBudgetBytes] — shrinks as the app's own memory
  /// use climbs, grows back as it's freed. Falls back to the full budget
  /// when [isSupported] is false, which is exactly the old fixed-constant
  /// behavior every adaptive budget replaces.
  static int availableBudgetBytes() {
    if (!isSupported) return totalBudgetBytes;
    final headroom = totalBudgetBytes - currentRssBytes();
    return math.max(_minBudgetBytes, headroom);
  }

  /// Headroom under [totalBudgetBytes] given an already-known RSS reading —
  /// the same arithmetic as [availableBudgetBytes], for a caller (the live
  /// UI readout) that wants to display headroom computed from a *cached*
  /// reading instead of triggering another [ProcessInfo.currentRss] call of
  /// its own. Flutter's `build()` runs far more often than the UI actually
  /// needs a fresh reading — polling from a slower ticker and reading that
  /// cached value here keeps `build()` itself free of any real syscall.
  static int availableBudgetFor(int rssBytes) => math.max(_minBudgetBytes, totalBudgetBytes - rssBytes);

  /// Scales one slice of [availableBudgetBytes] by [fraction], clamped to
  /// `[minBytes, maxBytes]` — the shape every call site here needs: a
  /// budget for *one* decode call/cache slot that shrinks under memory
  /// pressure without ever going below what's needed to make progress or
  /// above what a single call has any business using.
  static int budgetFor({required double fraction, required int minBytes, required int maxBytes}) {
    final target = (availableBudgetBytes() * fraction).round();
    return target.clamp(minBytes, maxBytes);
  }
}

String _formatMemoryBytes(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
