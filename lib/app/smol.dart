import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Public (no-login) Smolish data.
/// Uses the jina reader proxy + oEmbed + CDN URL conventions so the
/// feed works without touching the signed /_/q gate.
class VideoItem {
  final String id;
  final String title;
  final String handle;
  final int likes;
  final int comments;
  final int views;

  String get videoUrl => 'https://cdn.smolish.com/videos/$id/1080p.mp4';
  String get thumbnail => 'https://cdn.smolish.com/videos/$id/thumb.jpg';
  String get authorName => '@$handle';
  String get pageUrl => 'https://smolish.com/v/$id';

  VideoItem({
    required this.id,
    required this.title,
    required this.handle,
    this.likes = 0,
    this.comments = 0,
    this.views = 0,
  });
}

class SmolishRepo {
  static Future<String> _jina(String path) async {
    Future<String> once() async {
      final r = await http.get(Uri.parse('https://r.jina.ai$path'));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      return r.body;
    }

    try {
      return await once().timeout(const Duration(seconds: 20));
    } catch (e) {
      // Reader proxy rate-limits bursts: one retry after a breather.
      final msg = '$e';
      if (msg.contains('429') || msg.contains('402')) {
        await Future.delayed(const Duration(seconds: 4));
        return await once().timeout(const Duration(seconds: 20));
      }
      rethrow;
    }
  }

  static final _videoLink =
      RegExp(r'\[([^\]]+)\]\(https://smolish\.com/v/(\d+)\)(?:\s*by\s*\[@([^\]]+)\])?');

  static List<VideoItem> _parseVideos(String md, {String? forceHandle}) {
    return _videoLink.allMatches(md).map((m) {
      var title = m.group(1)!.trim();
      if (title.isEmpty) title = 'Untitled';
      if (title.startsWith('Video ') && title.length < 12) title = 'Untitled';
      return VideoItem(
        id: m.group(2)!,
        title: title,
        handle: forceHandle ?? m.group(3) ?? 'unknown',
      );
    }).toList();
  }

  static Future<List<VideoItem>> homeFeed() async {
    final md = await _jina('/https://smolish.com');
    return _parseVideos(md);
  }

  /// A feed that differs every launch: merges the home list with a few
  /// rotating tag lists, dedups, and shuffles with a time-based seed.
  /// (The public home list is one global snapshot, so without login there
  /// is no per-user FYP - shuffling + multi-source keeps it fresh.)
  static Future<List<VideoItem>> freshFeed() async {
    final seedTags = <String>['fyp', 'funny', 'memes', 'edit', 'viral'];
    seedTags.shuffle();
    final lists = <List<VideoItem>>[];
    try {
      lists.add(await homeFeed());
    } catch (_) {}
    for (final t in seedTags.take(3)) {
      try {
        lists.add(await tagVideos(t));
      } catch (_) {}
    }
    final seen = <String>{};
    final out = <VideoItem>[];
    for (final l in lists) {
      for (final v in l) {
        if (seen.add(v.id)) out.add(v);
      }
    }
    out.shuffle();
    return out;
  }

  static Future<List<VideoItem>> tagVideos(String tag) async {
    final t = tag.startsWith('#') ? tag.substring(1) : tag;
    final md = await _jina('/https://smolish.com/tag/$t');
    return _parseVideos(md);
  }

  static Future<List<VideoItem>> profileVideos(String handle) async {
    final h = handle.startsWith('@') ? handle.substring(1) : handle;
    final md = await _jina('/https://smolish.com/@$h');
    final th = RegExp(
        r'cdn\.smolish\.com%2Fvideos%2F(\d+)%2Fthumb\.jpg[^)]*\)[0-9,]+ views,([^\]]+)\]\(https://smolish\.com/v/(\d+)');
    final items = <VideoItem>[];
    for (final m in th.allMatches(md)) {
      items.add(VideoItem(id: m.group(3)!, title: m.group(2)!.trim(), handle: h));
    }
    if (items.isEmpty) {
      for (final m in _videoLink.allMatches(md)) {
        items.add(VideoItem(
            id: m.group(2)!,
            title: m.group(1)!.trim().isEmpty ? 'Untitled' : m.group(1)!.trim(),
            handle: h));
      }
    }
    return items;
  }

  static Future<List<VideoItem>> searchVideos(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    if (q.startsWith('#')) return tagVideos(q);
    if (q.startsWith('@')) return profileVideos(q);
    // Public search page (server-rendered) via reader proxy.
    // NOTE: the site's param is `q`, not `query`.
    try {
      final md = await _jina('/https://smolish.com/search?q=${Uri.encodeComponent(q)}');
      final items = _parseVideos(md);
      if (items.isNotEmpty) return items;
    } catch (_) {}
    // Fallback: treat query as a tag.
    try {
      return await tagVideos(q.replaceAll(' ', ''));
    } catch (_) {
      return [];
    }
  }

  static Future<List<String>> popularTags() async {
    final md = await _jina('/https://smolish.com');
    final out = <String>{};
    for (final m in RegExp(r'\[#([^\]]+)\]\(https://smolish\.com/tag/').allMatches(md)) {
      out.add(m.group(1)!);
    }
    return out.toList();
  }

  static final _statsCache = <String, ({int likes, int comments, int views})>{};

  static void dropStats(String id) => _statsCache.remove(id);
  /// Real per-video counts via the public oEmbed endpoint
  /// (provider_name looks like "💬 3 ❤️ 12 👁️ 456").
  /// Cached for the session so the feed doesn't hammer it.
  static Future<({int likes, int comments, int views})> videoStats(
      String id) async {
    final hit = _statsCache[id];
    if (hit != null) return hit;
    const fallback = (likes: 0, comments: 0, views: 0);
    try {
      final r = await http.get(Uri.parse(
          'https://smolish.com/api/oembed?url=${Uri.encodeComponent('https://smolish.com/v/$id')}&format=json'));
      if (r.statusCode != 200) return fallback;
      final j = jsonDecode(r.body);
      final provider = j is Map ? '${j['provider_name'] ?? ''}' : '';
      final nums = RegExp(r'\d+')
          .allMatches(provider)
          .map((m) => int.tryParse(m.group(0)!) ?? 0)
          .toList();
      final res = (
        comments: nums.isNotEmpty ? nums[0] : 0,
        likes: nums.length > 1 ? nums[1] : 0,
        views: nums.length > 2 ? nums[2] : 0,
      );
      _statsCache[id] = res;
      return res;
    } catch (_) {
      return fallback;
    }
  }

  /// Per-video loudness (LUFS) from the video page's embedded data.
  /// Null when the site didn't measure that video. Persistently cached.
  /// Page loads are plain navigation (not gated), fetched with cookies.
  static Future<double?> videoLoudness(
      String id, Map<String, String> Function() headerFn) async {
    try {
      final p = await SharedPreferences.getInstance();
      final cached = p.getDouble('solmish_lufs_$id');
      if (cached != null) return cached;
    } catch (_) {}
    try {
      final r = await http
          .get(Uri.parse('https://smolish.com/v/$id'),
              headers: headerFn())
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return null;
      final m = RegExp(r'"loudnessLufs":(null|-?[\d.]+)')
          .firstMatch(r.body);
      if (m == null || m.group(1) == 'null') return null;
      final lufs = double.tryParse(m.group(1)!);
      if (lufs == null) return null;
      try {
        final p = await SharedPreferences.getInstance();
        await p.setDouble('solmish_lufs_$id', lufs);
      } catch (_) {}
      return lufs;
    } catch (_) {
      return null;
    }
  }
}

/// Playback preferences: master volume + normalization toggle.
class SolSettings {
  static Future<double> masterVolume() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getDouble('solmish_volume') ?? 1.0;
    } catch (_) {
      return 1.0;
    }
  }

  static Future<void> setMasterVolume(double v) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble('solmish_volume', v.clamp(0.0, 1.0));
    } catch (_) {}
  }

  static Future<bool> normalize() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getBool('solmish_normalize') ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setNormalize(bool v) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('solmish_normalize', v);
    } catch (_) {}
  }
}
