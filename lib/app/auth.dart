import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'gate_browser.dart';

/// Cookie-based auth for Solmish.
///
/// Smolish uses better-auth with an HttpOnly session cookie
/// (`__Secure-better-auth.session_token`) plus its own `sg` / `sgk`
/// signing cookies. There is no username/password API a native app can
/// call, so login works like this:
///  1. User logs in with Discord/Google in their normal browser.
///  2. They paste the cookie string into Solmish (Me tab).
///  3. Solmish stores it and sends it on every API call.
class AuthService {
  static const _kRaw = 'solmish_cookie_raw';
  static const _kSession = 'solmish_cookie_session';
  static const _kSg = 'solmish_cookie_sg';
  static const _kSgk = 'solmish_cookie_sgk';
  static const _kCf = 'solmish_cookie_cf';
  static const _kVd = 'solmish_cookie_vd';

  String _raw = '';
  final _listeners = <void Function()>[];

  String get raw => _raw;
  bool get isLoggedIn => sessionToken.isNotEmpty;

  String sessionToken = '';
  String sg = '';
  String sgk = '';
  String cfClearance = '';
  String vd = '';

  void addListener(void Function() l) => _listeners.add(l);
  void _notify() {
    for (final l in _listeners) {
      l();
    }
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _raw = p.getString(_kRaw) ?? '';
    sessionToken = p.getString(_kSession) ?? '';
    sg = p.getString(_kSg) ?? '';
    sgk = p.getString(_kSgk) ?? '';
    cfClearance = p.getString(_kCf) ?? '';
    vd = p.getString(_kVd) ?? '';
    if (_raw.isNotEmpty && sessionToken.isEmpty) _parse(_raw);
    // Re-seed the WebView jar: its session cookies are RAM-only and die
    // with the process, while ours live in prefs.
    await syncToWebView();
    _notify();
  }

  /// Accepts a full `Cookie:` header, a devtools cookie-table paste, or a
  /// single `name=value` pair. Unknown cookies are kept verbatim too.
  Future<void> saveCookieString(String input) async {
    _parse(input);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kRaw, _raw);
    await p.setString(_kSession, sessionToken);
    await p.setString(_kSg, sg);
    await p.setString(_kSgk, sgk);
    await p.setString(_kCf, cfClearance);
    await p.setString(_kVd, vd);
    // Manual pastes only touched prefs before - push everything into the
    // WebView jar too, or the gate browser keeps calling anonymously.
    await syncToWebView();
    _notify();
  }

  /// Pushes stored cookies into the platform WebView jar so the login
  /// sandbox and the hidden gate browser send the same session as the
  /// direct HTTP client.
  Future<void> syncToWebView() async {
    try {
      final url = WebUri('https://smolish.com/');
      Future<void> set(String name, String value,
          {bool httpOnly = false}) async {
        if (value.isEmpty) return;
        await CookieManager.instance().setCookie(
          url: url,
          name: name,
          value: value,
          path: '/',
          isSecure: true,
          isHttpOnly: httpOnly,
        );
      }

      await set('__Secure-better-auth.session_token', sessionToken,
          httpOnly: true);
      await set('sg', sg);
      await set('sgk', sgk);
      await set('cf_clearance', cfClearance, httpOnly: true);
      await set('smolish_vd', vd);
      // Force the hidden gate browser to reboot on next call so it picks
      // up the new jar instead of running on a stale anonymous page.
      GateBrowser.instance.reset();
    } catch (_) {}
  }

  void _parse(String input) {
    final found = <String, String>{};
    // Split on ;, newline, tab - covers header + table pastes.
    for (final part in input.split(RegExp(r'[;\n\t]'))) {
      final t = part.trim();
      if (t.isEmpty) continue;
      final eq = t.indexOf('=');
      if (eq <= 0) {
        // Bare token: assume it is the session token itself.
        if (sessionToken.isEmpty && t.length > 20) {
          found['__Secure-better-auth.session_token'] = t;
        }
        continue;
      }
      var name = t.substring(0, eq).trim();
      var value = t.substring(eq + 1).trim();
      // Devtools table pastes may include extra columns; keep first token.
      if (value.contains(' ')) value = value.split(' ').first;
      if (value.isEmpty) continue;
      found[name] = value;
    }
    String pick(List<String> names) {
      for (final n in names) {
        if (found.containsKey(n)) return found[n]!;
      }
      return '';
    }

    final sess = pick([
      '__Secure-better-auth.session_token',
      '__Secure-better-auth.session-token',
      'better-auth.session_token',
      'smolish.session_token',
      'session_token',
    ]);
    if (sess.isNotEmpty) sessionToken = sess;
    // Multi-session variant better-auth sometimes sets.
    for (final e in found.entries) {
      if (e.key.contains('session_token_multi-') && sessionToken.isEmpty) {
        sessionToken = e.value;
      }
    }
    final sgV = pick(['sg']);
    if (sgV.isNotEmpty) sg = sgV;
    final sgkV = pick(['sgk']);
    if (sgkV.isNotEmpty) sgk = sgkV;
    final cfV = pick(['cf_clearance']);
    if (cfV.isNotEmpty) cfClearance = cfV;
    final vdV = pick(['smolish_vd']);
    if (vdV.isNotEmpty) vd = vdV;

    // Rebuild a canonical header from known-good parts + leftovers.
    final parts = <String>[];
    if (cfClearance.isNotEmpty) parts.add('cf_clearance=$cfClearance');
    if (sg.isNotEmpty) parts.add('sg=$sg');
    if (sgk.isNotEmpty) parts.add('sgk=$sgk');
    if (vd.isNotEmpty) parts.add('smolish_vd=$vd');
    if (sessionToken.isNotEmpty) {
      parts.add('__Secure-better-auth.session_token=$sessionToken');
    }
    for (final e in found.entries) {
      if (e.key.contains('session_token_multi-')) {
        parts.add('${e.key}=${e.value}');
      }
    }
    if (parts.isNotEmpty) _raw = parts.join('; ');
  }

  String cookieHeader() => _raw;

  Map<String, String> headers({String? contentType}) => {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36 Solmish/1.0',
        'Accept': 'application/json, */*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Referer': 'https://smolish.com/',
        'Origin': 'https://smolish.com',
        if (contentType != null) 'Content-Type': contentType,
        if (_raw.isNotEmpty) 'Cookie': _raw,
      };

  /// better-auth session check. Note: this endpoint goes through the
  /// /_/q signing gate like everything else, so raw HTTP always gets
  /// "could not be verified" - real validation happens through the
  /// gate browser (see SmolishApi.testGateSession).
  Future<Map<String, dynamic>?> getSession() async {
    if (!isLoggedIn) return null;
    try {
      final r = await http
          .get(Uri.parse('https://smolish.com/api/auth/get-session'), headers: headers())
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200 || r.body.isEmpty) return null;
      if (!r.body.trimLeft().startsWith('{')) return null;
      return null; // parsed by caller via rawSessionJson
    } catch (_) {
      return null;
    }
  }

  Future<String?> rawSessionJson() async {
    if (!isLoggedIn) return null;
    try {
      final r = await http
          .get(Uri.parse('https://smolish.com/api/auth/get-session'), headers: headers())
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 200 && r.body.isNotEmpty) return r.body;
    } catch (_) {}
    return null;
  }

  Future<void> logout() async {
    try {
      await http
          .post(Uri.parse('https://smolish.com/api/auth/sign-out'),
              headers: headers(contentType: 'application/json'), body: '{}')
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
    sessionToken = '';
    sg = '';
    sgk = '';
    cfClearance = '';
    vd = '';
    _raw = '';
    final p = await SharedPreferences.getInstance();
    await p.remove(_kRaw);
    await p.remove(_kSession);
    await p.remove(_kSg);
    await p.remove(_kSgk);
    await p.remove(_kCf);
    await p.remove(_kVd);
    try {
      final url = WebUri('https://smolish.com/');
      for (final n in [
        '__Secure-better-auth.session_token',
        'sg',
        'sgk',
        'cf_clearance',
        'smolish_vd'
      ]) {
        await CookieManager.instance()
            .deleteCookie(url: url, name: n, path: '/');
      }
      GateBrowser.instance.reset();
    } catch (_) {}
    _notify();
  }
}

final authService = AuthService();
