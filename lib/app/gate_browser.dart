import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Runs Smolish's own page (with its signing gate) headless and performs
/// authenticated API calls through the page's `fetch`.
///
/// Direct HTTP calls to /api/* fail with "Request could not be verified"
/// because every call must be minted into a signed /_/q request by the
/// site's JS (PoW + xchacha sealing). Instead of reimplementing that,
/// we let the real page do it: `fetch` inside the page context is already
/// wrapped by the gate, so calls come out correctly signed with the
/// user's cookies attached.
class GateResult {
  final int status;
  final String body;
  GateResult(this.status, this.body);
}

class GateBrowser {
  static final GateBrowser instance = GateBrowser._();
  GateBrowser._();

  HeadlessInAppWebView? _hl;
  Future<void>? _starting;
  bool _ready = false;
  Future<void> _queue = Future.value();

  /// Drops the hidden page so the next call boots fresh (used when the
  /// cookie jar changes - login, re-paste, logout).
  void reset() {
    try {
      _hl?.dispose();
    } catch (_) {}
    _hl = null;
    _ready = false;
    _starting = null;
  }

  Future<void> ensureLoaded() {
    if (_ready) return Future.value();
    _starting ??= _start();
    return _starting!;
  }

  Future<void> _start() async {
    final loaded = Completer<void>();
    _hl = HeadlessInAppWebView(
      initialUrlRequest:
          URLRequest(url: WebUri('https://smolish.com/')),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        thirdPartyCookiesEnabled: true,
        sharedCookiesEnabled: true,
      ),
      onLoadStop: (_, __) async {
        if (!loaded.isCompleted) loaded.complete();
      },
    );
    await _hl!.run();
    await loaded.future.timeout(const Duration(seconds: 30));
    // Give the gate a moment to install its fetch wrapper.
    await Future.delayed(const Duration(seconds: 2));
    _ready = true;
  }

  Future<void> _reloadAndWait() async {
    final ctrl = _hl?.webViewController;
    if (ctrl == null) {
      _ready = false;
      _starting = null;
      await ensureLoaded();
      return;
    }
    final loaded = Completer<void>();
    // Re-arm via a one-shot: poll URL state instead of callbacks.
    unawaited(ctrl.loadUrl(
        urlRequest: URLRequest(url: WebUri('https://smolish.com/'))));
    // Wait until the page answers JS again.
    for (var i = 0; i < 30; i++) {
      await Future.delayed(const Duration(seconds: 1));
      try {
        final v = await ctrl
            .evaluateJavascript(source: 'document.readyState')
            .timeout(const Duration(seconds: 5));
        if ('$v'.contains('complete')) {
          loaded.complete();
          break;
        }
      } catch (_) {}
    }
    await loaded.future.timeout(const Duration(seconds: 35));
    await Future.delayed(const Duration(seconds: 2));
  }

  /// Serialized call through the page's signed fetch.
  Future<GateResult> api(
      String method, String path, Map<String, dynamic>? body) async {
    final prev = _queue;
    final done = Completer<void>();
    _queue = done.future;
    await prev;
    try {
      return await _apiInner(method, path, body, allowRetry: true)
          .timeout(const Duration(seconds: 60));
    } finally {
      done.complete();
    }
  }

  Future<GateResult> _apiInner(String method, String path,
      Map<String, dynamic>? body, {bool allowRetry = false}) async {
    await ensureLoaded();
    final ctrl = _hl?.webViewController;
    if (ctrl == null) throw Exception('Gate browser not ready.');
    final payload = body == null ? 'undefined' : jsonEncode(body);
    dynamic res;
    try {
      final raw = await ctrl.callAsyncJavaScript(functionBody: '''
try {
  const opts = {method: '$method', headers: {'content-type': 'application/json'}, credentials: 'include'};
  const p = $payload;
  if (p !== undefined) { opts.body = JSON.stringify(p); }
  const r = await fetch('$path', opts);
  const t = await r.text();
  return {status: r.status, body: t};
} catch (e) {
  return {status: 0, body: 'JSERR:' + ((e && e.message) ? e.message : ('' + e))};
}
''');
      if (raw is CallAsyncJavaScriptResult) {
        if (raw.error != null) throw Exception('JS error: ${raw.error}');
        res = raw.value;
      } else {
        res = raw;
      }
    } catch (e) {
      if (allowRetry) {
        await _reloadAndWait();
        return _apiInner(method, path, body, allowRetry: false);
      }
      rethrow;
    }
    if (res is Map) {
      final map = res.map((k, v) => MapEntry('$k', v));
      final status = int.tryParse('${map['status']}') ?? 0;
      final text = '${map['body'] ?? ''}';
      if (status == 0 && allowRetry) {
        await _reloadAndWait();
        return _apiInner(method, path, body, allowRetry: false);
      }
      return GateResult(status, text);
    }
    if (res is String) {
      // Some platforms hand back the JSON-encoded string instead.
      try {
        final j = jsonDecode(res);
        if (j is Map) {
          final map = j.map((k, v) => MapEntry('$k', v));
          final status = int.tryParse('${map['status']}') ?? 0;
          final text = '${map['body'] ?? ''}';
          if (status == 0 && allowRetry) {
            await _reloadAndWait();
            return _apiInner(method, path, body, allowRetry: false);
          }
          return GateResult(status, text);
        }
      } catch (_) {}
    }
    throw Exception(
        'Unexpected gate response (${res == null ? 'null' : res.runtimeType}).');
  }
}
