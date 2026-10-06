import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth.dart';

/// In-app login sandbox.
///
/// Opens the real smolish.com in an embedded browser. The user taps
/// "Log in" on the site and completes Discord/Google OAuth there.
/// Solmish watches the cookie jar and says when a session appears, but
/// only imports when the user taps "I'm done" - never auto-closes.
class LoginWebScreen extends StatefulWidget {
  const LoginWebScreen({super.key});

  @override
  State<LoginWebScreen> createState() => _LoginWebScreenState();
}

class _LoginWebScreenState extends State<LoginWebScreen> {
  InAppWebViewController? _web;
  bool _done = false;
  bool _checking = false;
  double _progress = 0;
  bool _challenge = false;
  String? _loadError;

  static final _site = WebUri('https://smolish.com/');

  /// Reads cookies once, only when the user taps "I'm done".
  /// Nothing is watched or polled before that.
  Future<void> _importNow() async {
    if (_done || _checking) return;
    setState(() => _checking = true);
    try {
      final found = await _readCookies();
      final hasSession =
          found.keys.any((k) => k.contains('session_token'));
      if (found.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'No cookies found yet - finish logging in on the site first.')));
        }
        return;
      }
      _done = true;
      final header =
          found.entries.map((e) => '${e.key}=${e.value}').join('; ');
      await authService.saveCookieString(header);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(hasSession
              ? 'Logged in! Session imported.'
              : 'Imported ${found.length} cookies - validating session…')));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Cookie read failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<Map<String, String>> _readCookies() async {
    final found = <String, String>{};
    final jar = await CookieManager.instance().getCookies(url: _site);
    for (final c in jar) {
      if ((c.value ?? '').isNotEmpty) found[c.name] = c.value as String;
    }
    // Supplement via in-page JS (non-HttpOnly only, but harmless).
    try {
      final js =
          await _web?.evaluateJavascript(source: 'document.cookie');
      if (js is String && js.isNotEmpty) {
        for (final part in js.split(';')) {
          final eq = part.indexOf('=');
          if (eq > 0) {
            final k = part.substring(0, eq).trim();
            final v = part.substring(eq + 1).trim();
            if (k.isNotEmpty && v.isNotEmpty) found.putIfAbsent(k, () => v);
          }
        }
      }
    } catch (_) {}
    return found;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Log in with Smolish'),
        actions: [
          IconButton(
            tooltip: 'Reload page',
            onPressed: () => _web?.reload(),
            icon: const Icon(Icons.refresh),
          ),
          TextButton(
            onPressed: _importNow,
            child: _checking
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text("I'm done"),
          ),
        ],
        bottom: _progress < 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: _progress),
              )
            : null,
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(10),
            child: Text(
              'Tap "Log in", finish logging in, then tap I\'m done.',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: _site),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                thirdPartyCookiesEnabled: true,
                sharedCookiesEnabled: true,
                supportMultipleWindows: true,
              ),
              onWebViewCreated: (c) => _web = c,
              onProgressChanged: (_, p) =>
                  setState(() => _progress = p / 100),
              onReceivedError: (_, request, error) {
                // Subresources (ads, trackers, iframes) fail all the time;
                // only the main page failing matters.
                if (request.isForMainFrame != true) return;
                if (mounted) {
                  setState(() => _loadError =
                      'Page failed: ${error.type} ${error.description}'.trim());
                }
              },
              onReceivedHttpError: (_, request, response) {
                if (request.isForMainFrame != true) return;
                if (mounted) {
                  setState(() => _loadError =
                      'Page returned HTTP ${response.statusCode}.');
                }
              },
              onLoadStop: (_, __) async {
                if (mounted && _loadError != null) {
                  setState(() => _loadError = null);
                }
                // Cloudflare sometimes parks the embedded browser on a
                // "checking" page. Flag it so the user knows to wait or
                // use the system browser instead.
                try {
                  final title = await _web?.evaluateJavascript(
                      source: 'document.title');
                  final t = '$title'.toLowerCase();
                  final hit = t.contains('just a moment') ||
                      t.contains('checking') ||
                      t.contains('challenge') ||
                      t.contains('attention required');
                  if (mounted && hit != _challenge) {
                    setState(() => _challenge = hit);
                  }
                } catch (_) {}
              },
            ),
          ),
          if (_loadError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Text(
                _loadError!,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center,
              ),
            ),
          if (_challenge)
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Smolish is checking this browser. Wait a moment, or log in below instead.',
                    style: TextStyle(color: Colors.orange),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  OutlinedButton(
                    onPressed: () => launchUrl(_site.uriValue,
                        mode: LaunchMode.externalApplication),
                    child: const Text('Open in system browser'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
