import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth.dart';
import 'gate_browser.dart';
import 'smol.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Thrown when Smolish refuses a call because it was not routed through
/// its JS signing gate (HTTP 404/412 + `x-sg-s: upgrade|stale`, body
/// "Request could not be verified."). Likes/comments/follows/search need
/// the gate's /_/q minting, which Solmish runs via the bundled signer;
/// until a fresh browser session seeds it, these calls raise this.
class GateException implements Exception {
  final String message;
  GateException([this.message = 'Smolish asked for a fresh signed request. Re-paste cookies from your browser (Me tab).']);
  @override
  String toString() => message;
}

class SmolComment {
  final String id;
  final String body;
  final String authorHandle;
  final String authorName;
  final String? avatar;
  final String createdAt;
  final int likeCount;
  final String? parentId;
  final List<String> images;
  final String gifSlug;

  SmolComment({
    required this.id,
    required this.body,
    required this.authorHandle,
    required this.authorName,
    this.avatar,
    this.createdAt = '',
    this.likeCount = 0,
    this.parentId,
    this.images = const [],
    this.gifSlug = '',
  });

  /// Image URLs attached to a comment, from any shape the API uses:
  /// gif objects, url fields, attachment lists, or markdown in the body.
  static List<String> _extractImages(Map<String, dynamic> j, String body) {
    final out = <String>[];
    void add(dynamic v) {
      if (v is String) {
        final u = v.trim();
        if (u.startsWith('http') && !out.contains(u)) out.add(u);
      }
    }

    final gif = j['gif'];
    if (gif is Map) {
      final g = gif.cast<String, dynamic>();
      add(g['url']);
      add(g['src']);
      add(g['preview']);
      add(g['previewUrl']);
      add(g['preview_url']);
    }
    add(j['gifUrl']);
    add(j['gifPreview']);
    for (final key in ['attachments', 'media', 'images']) {
      final v = j[key];
      if (v is List) {
        for (final e in v) {
          if (e is String) {
            add(e);
          } else if (e is Map) {
            final m = e.cast<String, dynamic>();
            add(m['url']);
            add(m['src']);
            add(m['imageUrl']);
            add(m['previewUrl']);
          }
        }
      }
    }
    for (final m
        in RegExp(r'!\[[^\]]*\]\((https?://[^)\s]+)\)').allMatches(body)) {
      add(m.group(1));
    }
    return out;
  }

  factory SmolComment.fromJson(Map<String, dynamic> j) {
    final a = (j['author'] as Map?)?.cast<String, dynamic>() ?? const {};
    final body = '${j['body'] ?? ''}';
    final gif = j['gif'];
    final gifMap =
        gif is Map ? gif.cast<String, dynamic>() : const <String, dynamic>{};
    return SmolComment(
      id: '${j['id'] ?? ''}',
      body: body,
      authorHandle: '${a['handle'] ?? j['authorHandle'] ?? 'unknown'}',
      authorName: '${a['displayName'] ?? a['name'] ?? j['authorName'] ?? 'unknown'}',
      avatar: a['avatar'] as String? ?? a['image'] as String?,
      createdAt: '${j['createdAt'] ?? ''}',
      likeCount: (j['likeCount'] ?? j['likesCount'] ?? 0) is int
          ? ((j['likeCount'] ?? j['likesCount'] ?? 0) as int)
          : int.tryParse('${j['likeCount'] ?? j['likesCount'] ?? 0}') ?? 0,
      parentId: j['parentId'] as String?,
      images: _extractImages(j, body),
      gifSlug: '${j['gifSlug'] ?? gifMap['slug'] ?? ''}',
    );
  }
}

class SmolProfile {
  final String handle;
  final String displayName;
  final String bio;
  final String avatar;
  final String joined;
  final int followers;
  final int videoCount;
  final String userId;

  SmolProfile({
    required this.handle,
    required this.displayName,
    this.bio = '',
    this.avatar = '',
    this.joined = '',
    this.followers = 0,
    this.videoCount = 0,
    this.userId = '',
  });
}

class SmolGif {
  final String slug;
  final String url;
  final String preview;
  SmolGif({required this.slug, required this.url, required this.preview});

  factory SmolGif.fromJson(Map<String, dynamic> j) {
    String str(dynamic v) => v is String ? v : '';
    final images = j['images'] is Map
        ? (j['images'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    return SmolGif(
      slug: '${j['slug'] ?? j['id'] ?? ''}',
      url: str(j['url'] ?? j['src'] ?? images['url']),
      preview: str(j['preview'] ??
          j['previewUrl'] ??
          images['preview'] ??
          j['url'] ??
          ''),
    );
  }
}

/// A favorited GIF (local only). Posting still needs the slug, so only
/// GIFs with a known slug can be favorited for reuse.
class GifFav {
  final String slug;
  final String url;
  GifFav({required this.slug, required this.url});

  Map<String, String> toJson() => {'slug': slug, 'url': url};

  factory GifFav.fromJson(Map j) =>
      GifFav(slug: '${j['slug'] ?? ''}', url: '${j['url'] ?? ''}');
}

class GifFavs {
  static const _k = 'solmish_gif_favs';

  static Future<List<GifFav>> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_k);
      if (raw == null || raw.isEmpty) return [];
      final j = jsonDecode(raw);
      if (j is! List) return [];
      return [
        for (final e in j)
          if (e is Map && '${e['slug'] ?? ''}'.isNotEmpty)
            GifFav.fromJson(e.cast<String, dynamic>()),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<bool> toggle(GifFav fav) async {
    final favs = await load();
    final i = favs.indexWhere((f) => f.slug == fav.slug);
    bool nowFav;
    if (i >= 0) {
      favs.removeAt(i);
      nowFav = false;
    } else {
      favs.insert(0, fav);
      nowFav = true;
    }
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_k,
          jsonEncode([for (final f in favs.take(200)) f.toJson()]));
    } catch (_) {}
    return nowFav;
  }

  static Future<bool> contains(String slug) async =>
      (await load()).any((f) => f.slug == slug);
}

/// Authenticated Smolish API (likes, comments, follows, bookmarks,
/// search). Reads cookies from [authService].
class SmolishApi {
  static void _throwIfGate(http.Response r) {
    final s = (r.headers['x-sg-s'] ?? '').toLowerCase();
    final body = r.body;
    if (s == 'upgrade' || s == 'stale' || body.contains('could not be verified')) {
      throw GateException();
    }
  }

  static String _hint(String body) {
    final t = body.trimLeft();
    if (t.startsWith('<')) {
      return 'Got a security/HTML page instead of JSON - refresh cookies via the Me tab login.';
    }
    final flat = body.replaceAll(RegExp(r'\s+'), ' ');
    return flat.length > 160 ? flat.substring(0, 160) : flat;
  }

  static Future<dynamic> _viaGate(String method, String path,
      Map<String, dynamic>? body) async {
    final g =
        await GateBrowser.instance.api(method, path, body);
    if (g.body.contains('could not be verified')) throw GateException();
    if (g.status == 401 || g.status == 403) {
      throw Exception(
          'Not logged in (HTTP ${g.status}). ${_hint(g.body)}');
    }
    if (g.status == 0) throw GateException('Gate browser call failed.');
    if (g.body.contains('could not be verified')) throw GateException();
    if (g.status >= 400) {
      String msg = 'Request failed (${g.status})';
      try {
        final j = jsonDecode(g.body);
        if (j is Map && j['error'] is String) msg = j['error'] as String;
      } catch (_) {}
      throw Exception(msg);
    }
    if (g.body.isEmpty) return null;
    try {
      return jsonDecode(g.body);
    } catch (_) {
      return null;
    }
  }

  static Future<dynamic> _get(String path) async {
    // Gated endpoints reject plain HTTP, so logged-in calls go through
    // the page's signed fetch. Direct HTTP stays as fallback.
    if (authService.isLoggedIn) {
      try {
        return await _viaGate('GET', path, null);
      } catch (e) {
        if (e is GateException) rethrow;
        // fall through to direct attempt below
      }
    }
    final r = await http
        .get(Uri.parse('https://smolish.com$path'), headers: authService.headers())
        .timeout(const Duration(seconds: 15));
    _throwIfGate(r);
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw Exception('Not logged in (HTTP ${r.statusCode}). ${_hint(r.body)}');
    }
    if (r.statusCode >= 400) throw Exception('Request failed (${r.statusCode})');
    if (r.body.isEmpty) return null;
    return jsonDecode(r.body);
  }

  static Future<dynamic> _send(String method, String path, Map<String, dynamic>? body) async {
    if (authService.isLoggedIn) {
      try {
        return await _viaGate(method, path, body);
      } catch (e) {
        if (e is GateException) rethrow;
        // fall through to direct attempt below
      }
    }
    final req = http.Request(method, Uri.parse('https://smolish.com$path'))
      ..headers.addAll(authService.headers(contentType: 'application/json'))
      ..body = jsonEncode(body ?? {});
    final streamed = await req.send().timeout(const Duration(seconds: 15));
    final r = await http.Response.fromStream(streamed);
    _throwIfGate(r);
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw Exception('Not logged in (HTTP ${r.statusCode}). ${_hint(r.body)}');
    }
    _throwIfGate(r);
    if (r.statusCode >= 400) {
      String msg = 'Request failed (${r.statusCode})';
      try {
        final j = jsonDecode(r.body);
        if (j is Map && j['error'] is String) msg = j['error'] as String;
      } catch (_) {}
      throw Exception(msg);
    }
    if (r.body.isEmpty) return null;
    try {
      return jsonDecode(r.body);
    } catch (_) {
      return null;
    }
  }

  // ---- comments ----------------------------------------------------------
  static Future<({List<SmolComment> comments, String? cursor})> comments(
    String videoId, {String? cursor, String? parentId}) async {
    final q = {
      'videoId': videoId,
      if (cursor != null) 'cursor': cursor,
      if (parentId != null) 'parentId': parentId,
    };
    final qs = q.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
    final j = await _get('/api/comments?$qs');
    final list = <SmolComment>[];
    String? next;
    if (j is Map) {
      next = j['nextCursor'] as String? ?? j['cursor'] as String?;
      final raw = j['comments'] ?? j['items'] ?? [];
      if (raw is List) {
        for (final c in raw) {
          if (c is Map) list.add(SmolComment.fromJson(c.cast<String, dynamic>()));
        }
      }
    } else if (j is List) {
      for (final c in j) {
        if (c is Map) list.add(SmolComment.fromJson(c.cast<String, dynamic>()));
      }
    }
    return (comments: list, cursor: next);
  }

  static Future<SmolComment?> postComment(String videoId, String body,
      {String? parentId, String? gifSlug}) async {
    final j = await _send('POST', '/api/comments', {
      'videoId': videoId,
      'body': body,
      if (parentId != null) 'parentId': parentId,
      if (gifSlug != null) 'gifSlug': gifSlug,
    });
    if (j is Map) {
      final c = j['comment'] ?? j;
      if (c is Map) return SmolComment.fromJson(c.cast<String, dynamic>());
    }
    return null;
  }

  static Future<void> deleteComment(String commentId) =>
      _send('DELETE', '/api/comments', {'commentId': commentId});

  static Future<void> reactComment(String commentId, String? emoji) =>
      _send('POST', '/api/comments/reactions', {'commentId': commentId, if (emoji != null) 'emoji': emoji});

  // ---- GIFs ---------------------------------------------------------------
  static Future<List<SmolGif>> gifs(String query, {int page = 1}) async {
    final q = {
      'page': '$page',
      if (query.trim().isNotEmpty) 'q': query.trim(),
    };
    final qs = q.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final j = await _get('/api/gifs?$qs');
    final out = <SmolGif>[];
    List raw = const [];
    if (j is Map) {
      for (final key in ['gifs', 'items', 'results', 'data']) {
        final v = j[key];
        if (v is List && v.isNotEmpty) {
          raw = v;
          break;
        }
      }
    } else if (j is List) {
      raw = j;
    }
    for (final e in raw) {
      if (e is Map) {
        final g = SmolGif.fromJson(e.cast<String, dynamic>());
        if (g.slug.isNotEmpty && g.url.isNotEmpty) out.add(g);
      }
    }
    return out;
  }

  // ---- likes / bookmarks / follows --------------------------------------
  /// Returns updated likes count when the server provides one.
  static Future<int?> toggleLike(String videoId, bool like) async {
    final j = await _send(like ? 'POST' : 'DELETE', '/api/likes', {'videoId': videoId});
    if (j is Map) {
      final v = j['likesCount'] ?? j['likeCount'] ?? j['count'];
      if (v is int) return v;
      return int.tryParse('$v');
    }
    return null;
  }

  static Future<void> toggleBookmark(String videoId, bool save) =>
      _send(save ? 'POST' : 'DELETE', '/api/bookmarks', {'videoId': videoId});

  static Future<void> toggleFollow(String userId, bool follow) =>
      _send(follow ? 'POST' : 'DELETE', '/api/follow', {'userId': userId});

  /// Personalized feed through the signed in-app browser.
  /// Same endpoint the site uses: /api/feed?cursor=&author=&hashtag=&friends=1
  static Future<({List<VideoItem> videos, String? cursor})> feed(
      {String? cursor,
      String? hashtag,
      String? author,
      bool friends = false}) async {
    final q = {
      if (cursor != null) 'cursor': cursor,
      if (author != null) 'author': author,
      if (hashtag != null) 'hashtag': hashtag,
      if (friends) 'friends': '1',
    };
    final qs = q.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final j = await _viaGate('GET', '/api/feed${qs.isEmpty ? '' : '?$qs'}', null);
    final videos = <VideoItem>[];
    String? next;
    List rawList = const [];
    if (j is Map) {
      next = j['nextCursor'] as String? ??
          j['cursor'] as String? ??
          j['next'] as String?;
      for (final key in ['videos', 'items', 'feed', 'results', 'list', 'data']) {
        final v = j[key];
        if (v is List && v.isNotEmpty) {
          rawList = v;
          break;
        }
      }
    } else if (j is List) {
      rawList = j;
    }
    for (final e in rawList) {
      if (e is! Map) continue;
      final m = e.cast<String, dynamic>();
      final id = '${m['id'] ?? m['videoId'] ?? m['video_id'] ?? ''}';
      if (!RegExp(r'^\d+$').hasMatch(id)) continue;
      final author = m['author'];
      final handle = author is Map
          ? '${author['handle'] ?? author['username'] ?? 'unknown'}'
          : '${m['authorHandle'] ?? m['handle'] ?? 'unknown'}';
      int num(dynamic v) =>
          v is int ? v : int.tryParse('$v') ?? 0;
      videos.add(VideoItem(
        id: id,
        title: '${m['title'] ?? m['caption'] ?? 'Untitled'}',
        handle: handle,
        likes: num(m['likesCount'] ?? m['likes'] ?? m['likeCount']),
        comments:
            num(m['commentsCount'] ?? m['comments'] ?? m['commentCount']),
        views: num(m['viewsCount'] ?? m['views'] ?? m['viewCount']),
      ));
    }
    return (videos: videos, cursor: next);
  }

  /// Full profile page through the signed in-app browser:
  /// meta tags carry name/bio/avatar/followers/joined, the message link
  /// carries the numeric userId needed for follow.
  static Future<SmolProfile> profile(String handle) async {
    final h =
        handle.startsWith('@') ? handle.substring(1) : handle.trim();
    final g = await GateBrowser.instance.api('GET', '/@$h', null);
    if (g.status == 404) throw Exception('No such user: @$h');
    if (g.status != 200) throw Exception('Profile failed (${g.status}).');
    final html = g.body;

    String meta(String name) {
      final m = RegExp(
              '<meta\\s+(?:property|name)="$name"\\s+content="([^"]*)"',
              caseSensitive: false)
          .firstMatch(html);
      if (m != null) return _unescape(m.group(1)!);
      // attributes may come in the other order
      final m2 = RegExp(
              '<meta\\s+content="([^"]*)"\\s+(?:property|name)="$name"',
              caseSensitive: false)
          .firstMatch(html);
      return m2 != null ? _unescape(m2.group(1)!) : '';
    }

    final ogTitle = meta('og:title');
    var displayName = h;
    final tm = RegExp(r'^(.*)\s+\(@([^)]+)\)\s*$').firstMatch(ogTitle);
    if (tm != null) displayName = tm.group(1)!.trim();

    final ogDesc = meta('og:description');
    final bio = ogDesc.split(RegExp(r'\n+')).first.trim();
    int followers = 0;
    int videoCount = 0;
    final fm =
        RegExp(r'(\d+)\s+followers?').firstMatch(ogDesc);
    if (fm != null) followers = int.tryParse(fm.group(1)!) ?? 0;
    final vm = RegExp(r'(\d+)\s+videos?').firstMatch(ogDesc);
    if (vm != null) videoCount = int.tryParse(vm.group(1)!) ?? 0;

    var avatar = meta('og:image');
    if (avatar.contains('logo.png')) avatar = '';

    var joined = meta('twitter:data2');
    if (joined.isEmpty) {
      final site = meta('og:site_name');
      final jm = RegExp(r'[Jj]oined\s+(.*)').firstMatch(site);
      if (jm != null) joined = jm.group(1)!.trim();
    }

    var userId = '';
    final um =
        RegExp(r'messages/new\?user=([A-Za-z0-9_-]+)').firstMatch(html);
    if (um != null) userId = um.group(1)!;

    return SmolProfile(
      handle: h,
      displayName: displayName.isEmpty ? h : displayName,
      bio: bio,
      avatar: avatar,
      joined: joined,
      followers: followers,
      videoCount: videoCount,
      userId: userId,
    );
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#x27;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  /// A user's videos via /api/feed?author= (handle first, userId fallback).
  static Future<List<VideoItem>> profileFeed(String handle,
      {String userId = ''}) async {
    final h =
        handle.startsWith('@') ? handle.substring(1) : handle.trim();
    try {
      final page = await feed(author: h);
      if (page.videos.isNotEmpty) return page.videos;
    } catch (_) {}
    if (userId.isNotEmpty && userId != h) {
      try {
        final page = await feed(author: userId);
        if (page.videos.isNotEmpty) return page.videos;
      } catch (_) {}
    }
    return [];
  }

  /// Raw gate-browser session probe for the Me tab diagnostics.
  static Future<GateResult> testGateSession() =>
      GateBrowser.instance.api('GET', '/api/auth/get-session', null);

  /// Raw direct-HTTP session probe for the Me tab diagnostics.
  static Future<String> testDirectSession() async {
    try {
      final r = await http
          .get(Uri.parse('https://smolish.com/api/auth/get-session'),
              headers: authService.headers())
          .timeout(const Duration(seconds: 15));
      final flat = r.body.replaceAll(RegExp(r'\s+'), ' ');
      final snippet = flat.length > 200 ? flat.substring(0, 200) : flat;
      return 'HTTP ${r.statusCode}: $snippet';
    } catch (e) {
      return '$e';
    }
  }

  /// Gated search. Site uses `q` (+ optional tab). Returns video items
  /// with whatever title/handle the API provides.
  static Future<List<VideoItem>> searchVideos(String query) async {
    final j = await _get('/api/search?q=${Uri.encodeComponent(query)}');
    final out = <VideoItem>[];
    List rawList = const [];
    if (j is Map) {
      for (final key in ['videos', 'results', 'items', 'videoIds']) {
        final v = j[key];
        if (v is List && v.isNotEmpty) {
          rawList = v;
          break;
        }
      }
    } else if (j is List) {
      rawList = j;
    }
    for (final e in rawList) {
      if (e is String && RegExp(r'^\d+$').hasMatch(e)) {
        out.add(VideoItem(id: e, title: 'Video $e', handle: 'unknown'));
      } else if (e is Map) {
        final m = e.cast<String, dynamic>();
        final id =
            '${m['id'] ?? m['videoId'] ?? ''}';
        if (!RegExp(r'^\d+$').hasMatch(id)) continue;
        final author = m['author'];
        final handle = author is Map
            ? '${author['handle'] ?? 'unknown'}'
            : '${m['authorHandle'] ?? m['handle'] ?? 'unknown'}';
        out.add(VideoItem(
          id: id,
          title: '${m['title'] ?? 'Untitled'}',
          handle: handle,
        ));
      }
    }
    return out;
  }

  static Future<List<String>> search(String query) async =>
      [for (final v in await searchVideos(query)) v.id];
}
