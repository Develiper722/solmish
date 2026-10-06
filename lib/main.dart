import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'app/api.dart';
import 'app/auth.dart';
import 'app/login_web.dart';
import 'app/smol.dart';

void main() {
  runApp(const SolmishApp());
}

class SolmishApp extends StatefulWidget {
  const SolmishApp({super.key});
  @override
  State<SolmishApp> createState() => _SolmishAppState();
}

class _SolmishAppState extends State<SolmishApp> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    authService.load().then((_) {
      if (mounted) setState(() => _ready = true);
    });
    authService.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Solmish',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.deepPurple,
      ),
      home: _ready
          ? const ShellPage()
          : const Scaffold(body: Center(child: CircularProgressIndicator())),
    );
  }
}

class ShellPage extends StatefulWidget {
  const ShellPage({super.key});
  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  int _tab = 0;
  List<VideoItem> _videos = [];
  bool _loading = true;
  String? _error;
  String? _cursor;
  bool _browserFeed = false;
  bool _loadingMore = false;
  int _feedGen = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  static String _shortErr(Object e) {
    final s = '$e'.replaceAll(RegExp(r'\s+'), ' ');
    return s.length > 140 ? s.substring(0, 140) : s;
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    // Race: real feed through the in-app browser (personalized when
    // logged in) against the public index. Whichever valid result lands
    // first wins; the browser gets 12s before we stop waiting for it.
    // Failures are kept so the error screen says something useful.
    String gateErr = 'not tried';
    String pubErr = 'not tried';
    final gateFuture = SmolishApi.feed()
        .timeout(const Duration(seconds: 12))
        .then<({List<VideoItem> videos, String? cursor})?>(
            (p) => p.videos.isEmpty ? null : p)
        .catchError((e) {
      gateErr = _shortErr(e);
      return null;
    });
    final publicFuture = SmolishRepo.freshFeed()
        .then<List<VideoItem>?>((items) => items.isEmpty ? null : items)
        .catchError((e) {
      pubErr = _shortErr(e);
      return null;
    });
    final gatePage = await gateFuture;
    if (!mounted) return;
    if (gatePage != null) {
      setState(() {
        _videos = gatePage.videos;
        _cursor = gatePage.cursor;
        _browserFeed = true;
        _feedGen++;
        _loading = false;
        _error = null;
      });
      return;
    }
    final items = await publicFuture;
    if (!mounted) return;
    if (items == null || items.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'Browser feed: $gateErr\nPublic feed: $pubErr';
      });
      return;
    }
    setState(() {
      _videos = items;
      _cursor = null;
      _browserFeed = false;
      _feedGen++;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _loadMore() async {
    if (!_browserFeed || _cursor == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await SmolishApi.feed(cursor: _cursor);
      if (!mounted) return;
      final seen = {for (final v in _videos) v.id};
      setState(() {
        for (final v in page.videos) {
          if (seen.add(v.id)) _videos.add(v);
        }
        _cursor = page.cursor;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final feedBody = _loading && _videos.isEmpty
        ? const Center(child: CircularProgressIndicator())
        : _error != null && _videos.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_outlined, size: 48),
                      const SizedBox(height: 12),
                      Text('Could not load feed.\n$_error',
                          textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(
                          onPressed: _refresh, child: const Text('Retry')),
                    ],
                  ),
                ),
              )
            : RefreshIndicator(
                onRefresh: _refresh,
                child: FeedSwipe(
                    // Stable across appends: only a real refresh re-keys,
                    // so loading more never throws you back to video one.
                    key: ValueKey('feed_${_browserFeed}_$_feedGen'),
                    videos: _videos,
                    onLoadMore: _loadMore),
              );
    return Scaffold(
      // IndexedStack keeps the feed alive across tabs, so checking
      // Search/Me and coming back doesn't lose your position either.
      body: IndexedStack(
        index: _tab,
        children: [
          feedBody,
          const SearchPage(),
          const MePage(),
          const SettingsPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.home_outlined), label: 'Feed'),
          const NavigationDestination(
              icon: Icon(Icons.search_outlined), label: 'Search'),
          NavigationDestination(
            icon: authService.isLoggedIn
                ? const Icon(Icons.person)
                : const Icon(Icons.person_outline),
            label: authService.isLoggedIn ? 'Me' : 'Log in',
          ),
          const NavigationDestination(
              icon: Icon(Icons.settings_outlined), label: 'Settings'),
        ],
        onDestinationSelected: (i) => setState(() => _tab = i),
      ),
      floatingActionButton: _tab == 0
          ? FloatingActionButton(
              onPressed: _refresh,
              tooltip: 'Fresh feed',
              child: const Icon(Icons.refresh),
            )
          : null,
    );
  }
}

// ---- feed ---------------------------------------------------------------

class FeedSwipe extends StatefulWidget {
  final List<VideoItem> videos;
  final VoidCallback? onLoadMore;
  const FeedSwipe({super.key, required this.videos, this.onLoadMore});

  @override
  State<FeedSwipe> createState() => _FeedSwipeState();
}

class _FeedSwipeState extends State<FeedSwipe> {
  final _pageCtrl = PageController();
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _pageCtrl,
      scrollDirection: Axis.vertical,
      onPageChanged: (i) {
        setState(() => _index = i);
        if (i >= widget.videos.length - 4) widget.onLoadMore?.call();
      },
      itemCount: widget.videos.length,
      itemBuilder: (ctx, i) =>
          VideoCard(item: widget.videos[i], active: i == _index),
    );
  }
}

class VideoCard extends StatefulWidget {
  final VideoItem item;
  final bool active;
  const VideoCard({super.key, required this.item, required this.active});

  @override
  State<VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends State<VideoCard> {
  late VideoPlayerController _ctrl;
  bool _ready = false;
  bool _muted = false;
  bool _userPaused = false;
  double _userVol = 1.0;
  double _normGain = 1.0;
  bool _lufsTried = false;
  bool _liked = false;
  bool _saved = false;
  int _likeCount = 0;
  int _commentCount = 0;
  bool _heartBurst = false;
  Offset? _downPos;
  DateTime? _downTime;
  DateTime? _lastTapUp;
  Offset? _lastTapPos;

  static const _targetLufs = -14.0;

  @override
  void initState() {
    super.initState();
    _likeCount = widget.item.likes;
    _commentCount = widget.item.comments;
    SolSettings.masterVolume().then((v) {
      if (!mounted) return;
      setState(() => _userVol = v);
      _applyVolume();
    });
    // Real counts: the public feed carries none, so fetch per video.
    SmolishApi.videoStats(widget.item.id).then((s) {
      if (!mounted) return;
      setState(() {
        _likeCount = s.likes + (_liked ? 1 : 0);
        _commentCount = s.comments;
      });
    }).catchError((_) {});
    _ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.item.videoUrl))
      ..addListener(() {
        if (mounted) setState(() {});
      })
      ..setLooping(true)
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() => _ready = true);
        _applyVolume();
        if (widget.active) {
          _ctrl.play();
          _maybeNormalize();
        }
      }).catchError((_) {});
  }

  @override
  void didUpdateWidget(covariant VideoCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready) return;
    if (widget.active) {
      // Respect an explicit user pause: rebuilds (tab switches, feed
      // appends, auth updates) must never restart a paused video.
      if (!_userPaused && !_ctrl.value.isPlaying) _ctrl.play();
      _maybeNormalize();
    } else {
      _ctrl.pause();
    }
  }

  void _applyVolume() {
    if (!_ready) return;
    final v = (_muted ? 0.0 : _userVol * _normGain).clamp(0.0, 1.0);
    _ctrl.setVolume(v);
  }

  /// Loudness normalization: attenuate videos measured hotter than the
  /// target so everything plays at roughly the same perceived volume.
  /// (Players cap at 1.0, so quiet videos just play at full volume.)
  Future<void> _maybeNormalize() async {
    if (_lufsTried) return;
    _lufsTried = true;
    try {
      if (!await SolSettings.normalize()) return;
      final lufs = await SmolishApi.videoLoudness(widget.item.id);
      if (!mounted || lufs == null) return;
      final gain =
          pow(10.0, (_targetLufs - lufs) / 20.0).toDouble().clamp(0.15, 1.0);
      setState(() => _normGain = gain);
      _applyVolume();
    } catch (_) {}
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _togglePause() {
    if (!_ready) return;
    if (_ctrl.value.isPlaying) {
      _ctrl.pause();
      _userPaused = true;
    } else {
      _ctrl.play();
      _userPaused = false;
    }
    setState(() {});
  }

  // Manual tap detection (Listener, not GestureDetector) so taps on the
  // mute/tune buttons, action rail and scrub bar never toggle playback.
  void _onPointerDown(PointerDownEvent e) {
    _downPos = e.localPosition;
    _downTime = DateTime.now();
  }

  void _onPointerUp(PointerUpEvent e) {
    final downPos = _downPos;
    final downTime = _downTime;
    _downPos = null;
    _downTime = null;
    if (downPos == null || downTime == null || !_ready) return;
    final up = e.localPosition;
    final dt = DateTime.now().difference(downTime).inMilliseconds;
    if (dt > 350 || (downPos - up).distance > 24) return;
    if (_inControlZone(up)) return;
    final now = DateTime.now();
    final lastT = _lastTapUp;
    final lastP = _lastTapPos;
    _lastTapUp = now;
    _lastTapPos = up;
    if (lastT != null &&
        now.difference(lastT).inMilliseconds < 350 &&
        lastP != null &&
        (lastP - up).distance < 60) {
      _lastTapUp = null; // consume the pair
      _doLike();
      return;
    }
    _togglePause();
  }

  bool _inControlZone(Offset p) {
    final s = MediaQuery.of(context).size;
    final topPad = MediaQuery.of(context).padding.top;
    // Mute + tune buttons, top-right.
    if (p.dx >= s.width - 120 && p.dy <= topPad + 72) return true;
    // Action rail, right side.
    if (p.dx >= s.width - 84 && p.dy >= s.height * 0.30) return true;
    // Scrub bar, bottom.
    if (p.dy >= s.height - 48) return true;
    return false;
  }

  void _toggleMute() {
    if (!_ready) return;
    setState(() => _muted = !_muted);
    _applyVolume();
  }

  Future<void> _volumeDialog() async {
    var vol = _userVol;
    var norm = await SolSettings.normalize();
    if (!mounted) return;
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Volume'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.volume_down_outlined),
                  Expanded(
                    child: Slider(
                      value: vol,
                      onChanged: (v) => setD(() => vol = v),
                    ),
                  ),
                  const Icon(Icons.volume_up_outlined),
                ],
              ),
              SwitchListTile(
                title: const Text('Normalize loud videos'),
                subtitle: const Text('Even out volume toward −14 LUFS'),
                value: norm,
                onChanged: (v) => setD(() => norm = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    if (res == true && mounted) {
      await SolSettings.setMasterVolume(vol);
      await SolSettings.setNormalize(norm);
      setState(() {
        _userVol = vol;
        if (!norm) {
          _normGain = 1.0;
          _lufsTried = true;
        } else {
          _lufsTried = false;
        }
      });
      _applyVolume();
      if (norm) _maybeNormalize();
    }
  }

  Future<void> _doLike() async {
    if (!authService.isLoggedIn) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Log in first (Me tab) to like videos.')));
      return;
    }
    final want = !_liked;
    setState(() {
      _liked = want;
      _likeCount += want ? 1 : -1;
    });
    if (want && mounted) {
      setState(() => _heartBurst = true);
      Future.delayed(const Duration(milliseconds: 700), () {
        if (mounted) setState(() => _heartBurst = false);
      });
    }
    try {
      final n = await SmolishApi.toggleLike(widget.item.id, want);
      if (mounted && n != null) setState(() => _likeCount = n);
    } on GateException catch (e) {
      if (!mounted) return;
      setState(() {
        _liked = !want;
        _likeCount -= want ? 1 : -1;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _liked = !want;
        _likeCount -= want ? 1 : -1;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Like failed: $e')));
    }
  }

  Future<void> _doSave() async {
    if (!authService.isLoggedIn) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Log in first (Me tab) to save videos.')));
      return;
    }
    final want = !_saved;
    setState(() => _saved = want);
    try {
      await SmolishApi.toggleBookmark(widget.item.id, want);
    } on GateException catch (e) {
      if (!mounted) return;
      setState(() => _saved = !want);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saved = !want);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  void _openComments() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CommentsSheet(video: widget.item),
    ).then((_) {
      // Refresh counts after the sheet closes (user may have posted).
      SmolishRepo.dropStats(widget.item.id);
      SmolishApi.videoStats(widget.item.id).then((s) {
        if (!mounted) return;
        setState(() {
          _likeCount = s.likes + (_liked ? 1 : 0);
          _commentCount = s.comments;
        });
      }).catchError((_) {});
    });
  }

  Future<void> _share() async {
    await Clipboard.setData(ClipboardData(text: widget.item.pageUrl));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Video link copied to clipboard.')));
  }

  @override
  Widget build(BuildContext context) {
    final t = MediaQuery.of(context).size;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      child: Stack(
        children: [
          SizedBox(
            width: t.width,
            height: t.height,
            child: _ready
                ? FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                        width: _ctrl.value.size.width,
                        height: _ctrl.value.size.height,
                        child: VideoPlayer(_ctrl)))
                : Image.network(widget.item.thumbnail,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const ColoredBox(color: Colors.black)),
          ),
          // Title + author.
          Positioned(
            left: 12,
            right: 84,
            bottom: 64,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => CreatorPage(
                              handle: widget.item.handle,
                              name: widget.item.authorName))),
                  child: Text('@${widget.item.handle}',
                      style: const TextStyle(
                          color: Colors.white70,
                          decoration: TextDecoration.underline)),
                ),
              ],
            ),
          ),
          // Mute + volume buttons, top-right.
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 12,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: _toggleMute,
                  tooltip: 'Mute',
                  icon: Icon(_muted ? Icons.volume_off : Icons.volume_up,
                      color: Colors.white),
                ),
                IconButton(
                  onPressed: _volumeDialog,
                  tooltip: 'Volume + normalization',
                  icon: const Icon(Icons.tune, color: Colors.white),
                ),
              ],
            ),
          ),
          // Right action rail.
          Positioned(
            right: 8,
            bottom: 110,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _RailButton(
                  icon: _liked ? Icons.favorite : Icons.favorite_border,
                  color: _liked ? Colors.pink : Colors.white,
                  label: '$_likeCount',
                  onTap: _doLike,
                ),
                const SizedBox(height: 10),
                _RailButton(
                  icon: Icons.chat_bubble_outline,
                  label: '$_commentCount',
                  onTap: _openComments,
                ),
                const SizedBox(height: 10),
                _RailButton(
                  icon: _saved ? Icons.bookmark : Icons.bookmark_border,
                  label: '',
                  onTap: _doSave,
                ),
                const SizedBox(height: 10),
                _RailButton(
                  icon: Icons.share_outlined,
                  label: '',
                  onTap: _share,
                ),
              ],
            ),
          ),
          // Scrub bar.
          if (_ready)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VideoProgressIndicator(_ctrl, allowScrubbing: true),
            ),
          // Pause icon.
          if (_ready && !_ctrl.value.isPlaying && !_heartBurst)
            Center(
                child: Icon(Icons.play_arrow_rounded,
                    size: 72,
                    color: Colors.white.withValues(alpha: 0.8))),
          // Double-tap heart burst.
          if (_heartBurst)
            const Center(
                child: Icon(Icons.favorite, size: 96, color: Colors.pink)),
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _RailButton(
      {required this.icon,
      required this.label,
      required this.onTap,
      this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
            onPressed: onTap,
            icon: Icon(icon, color: color, size: 30)),
        if (label.isNotEmpty)
          Text(label,
              style: const TextStyle(color: Colors.white, fontSize: 12)),
      ],
    );
  }
}

// ---- comments ------------------------------------------------------------

class CommentsSheet extends StatefulWidget {
  final VideoItem video;
  const CommentsSheet({super.key, required this.video});

  @override
  State<CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<CommentsSheet> {
  final _input = TextEditingController();
  List<SmolComment> _comments = [];
  bool _loading = true;
  bool _posting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!authService.isLoggedIn) {
      setState(() {
        _loading = false;
        _error = 'not-logged-in';
      });
      return;
    }
    try {
      final res = await SmolishApi.comments(widget.video.id);
      if (!mounted) return;
      setState(() {
        _comments = res.comments;
        _loading = false;
      });
    } on GateException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _send() async {
    await _sendWithGif(null);
  }

  Future<void> _sendWithGif(String? gifSlug) async {
    final text = _input.text.trim();
    if ((text.isEmpty && gifSlug == null) || _posting) return;
    setState(() => _posting = true);
    try {
      final c = await SmolishApi.postComment(widget.video.id, text,
          gifSlug: gifSlug);
      if (!mounted) return;
      _input.clear();
      setState(() {
        _posting = false;
        if (c != null) _comments = [..._comments, c];
      });
      if (c == null) _load();
    } on GateException catch (e) {
      if (!mounted) return;
      setState(() => _posting = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    } catch (e) {
      if (!mounted) return;
      setState(() => _posting = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Comment failed: $e')));
    }
  }

  /// Body text with markdown images stripped (they render as images).
  String _plainText(String body) => body
      .replaceAll(RegExp(r'!\[[^\]]*\]\((https?://[^)\s]+)\)'), '')
      .trim();

  void _viewImage(String url, {String slug = ''}) async {
    final isFav = slug.isNotEmpty ? await GifFavs.contains(slug) : false;
    if (!mounted) return;
    var fav = isFav;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => Dialog(
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(12),
          child: Stack(
            children: [
              InteractiveViewer(
                child: Image.network(
                  url,
                  errorBuilder: (_, __, ___) => const Padding(
                    padding: EdgeInsets.all(32),
                    child: Icon(Icons.broken_image_outlined,
                        color: Colors.white, size: 48),
                  ),
                ),
              ),
              if (slug.isNotEmpty)
                Positioned(
                  top: 4,
                  left: 4,
                  child: IconButton(
                    tooltip: 'Favorite GIF',
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final nowFav = await GifFavs.toggle(
                          GifFav(slug: slug, url: url));
                      setD(() => fav = nowFav);
                      messenger.showSnackBar(SnackBar(
                          content: Text(nowFav
                              ? 'Saved to GIF favorites.'
                              : 'Removed from GIF favorites.')));
                    },
                    icon: Icon(
                      fav ? Icons.favorite : Icons.favorite_border,
                      color: fav ? Colors.pink : Colors.white,
                    ),
                  ),
                ),
              Positioned(
                top: 4,
                right: 4,
                child: IconButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickGif() async {
    final slug = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GifSheet(videoId: widget.video.id),
    );
    if (slug != null && mounted) _sendWithGif(slug);
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height * 0.75;
    return Container(
      height: h,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey,
                  borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text('Comments · ${widget.video.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error == 'not-logged-in'
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                              'Log in (Me tab) to read and write comments.',
                              textAlign: TextAlign.center),
                        ),
                      )
                    : _error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(_error!,
                                      textAlign: TextAlign.center),
                                  const SizedBox(height: 8),
                                  FilledButton(
                                      onPressed: () {
                                        setState(() {
                                          _loading = true;
                                          _error = null;
                                        });
                                        _load();
                                      },
                                      child: const Text('Retry')),
                                ],
                              ),
                            ),
                          )
                        : _comments.isEmpty
                            ? const Center(
                                child: Text('No comments yet. Say something!'))
                            : ListView.builder(
                                itemCount: _comments.length,
                                itemBuilder: (_, i) {
                                  final c = _comments[i];
                                  return ListTile(
                                    leading: const CircleAvatar(
                                        child: Icon(Icons.person_outline)),
                                    title: Text(
                                        '${c.authorName} · @${c.authorHandle}',
                                        style: const TextStyle(fontSize: 12)),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (c.body.isNotEmpty)
                                          Text(_plainText(c.body)),
                                        if (c.images.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                top: 6),
                                            child: Wrap(
                                              spacing: 6,
                                              runSpacing: 6,
                                              children: [
                                                for (final url in c.images)
                                                  GestureDetector(
                                                    onTap: () => _viewImage(
                                                        url,
                                                        slug: c.gifSlug),
                                                    child: ClipRRect(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              8),
                                                      child: Image.network(
                                                        url,
                                                        height: 140,
                                                        fit: BoxFit.cover,
                                                        errorBuilder: (_, __,
                                                                ___) =>
                                                            const SizedBox(
                                                          height: 140,
                                                          width: 140,
                                                          child: Icon(Icons
                                                              .broken_image_outlined),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                    trailing: c.likeCount > 0
                                        ? Text('♥ ${c.likeCount}')
                                        : null,
                                  );
                                },
                              ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Attach a GIF',
                    onPressed:
                        authService.isLoggedIn && !_posting ? _pickGif : null,
                    icon: const Icon(Icons.gif_box_outlined),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: authService.isLoggedIn && !_posting,
                      decoration: const InputDecoration(
                        hintText: 'Add a comment…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed:
                        authService.isLoggedIn && !_posting ? _send : null,
                    icon: _posting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- GIF picker ------------------------------------------------------------

class GifSheet extends StatefulWidget {
  final String videoId;
  const GifSheet({super.key, required this.videoId});

  @override
  State<GifSheet> createState() => _GifSheetState();
}

class _GifSheetState extends State<GifSheet> {
  final _q = TextEditingController();
  List<SmolGif> _gifs = [];
  List<GifFav> _favs = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    GifFavs.load().then((f) {
      if (mounted) setState(() => _favs = f);
    });
    _search('');
  }

  Future<void> _reloadFavs() async {
    final f = await GifFavs.load();
    if (mounted) setState(() => _favs = f);
  }

  bool _isFav(String slug) => _favs.any((f) => f.slug == slug);

  Future<void> _toggleFav(SmolGif g) async {
    await GifFavs.toggle(GifFav(slug: g.slug, url: g.url));
    await _reloadFavs();
  }

  Widget _gifTile({
    required String imageUrl,
    required bool isFav,
    required VoidCallback onTap,
    required VoidCallback onFav,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const ColoredBox(
                  color: Colors.black,
                  child: Icon(Icons.broken_image_outlined)),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: IconButton(
              tooltip: 'Favorite GIF',
              onPressed: onFav,
              icon: Icon(
                isFav ? Icons.favorite : Icons.favorite_border,
                color: isFav ? Colors.pink : Colors.white,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _search(String query) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final gifs = await SmolishApi.gifs(query);
      if (!mounted) return;
      setState(() {
        _gifs = gifs;
        _loading = false;
      });
    } on GateException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.6,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey,
                  borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _q,
              textInputAction: TextInputAction.search,
              onSubmitted: _search,
              decoration: InputDecoration(
                hintText: 'Search GIFs…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                    onPressed: () => _search(_q.text),
                    icon: const Icon(Icons.arrow_forward)),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error!, textAlign: TextAlign.center),
                      ))
                    : _gifs.isEmpty && _favs.isEmpty
                        ? const Center(child: Text('No GIFs found.'))
                        : ListView(
                            padding: const EdgeInsets.all(8),
                            children: [
                              if (_favs.isNotEmpty) ...[
                                const Padding(
                                  padding:
                                      EdgeInsets.symmetric(vertical: 4),
                                  child: Text('Your favorites',
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold)),
                                ),
                                GridView.count(
                                  crossAxisCount: 3,
                                  mainAxisSpacing: 4,
                                  crossAxisSpacing: 4,
                                  shrinkWrap: true,
                                  physics:
                                      const NeverScrollableScrollPhysics(),
                                  children: [
                                    for (final f in _favs)
                                      _gifTile(
                                        imageUrl: f.url,
                                        isFav: true,
                                        onTap: () => Navigator.of(context)
                                            .pop(f.slug),
                                        onFav: () async {
                                          await GifFavs.toggle(f);
                                          await _reloadFavs();
                                        },
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                              ],
                              if (_gifs.isNotEmpty) ...[
                                if (_favs.isNotEmpty)
                                  const Padding(
                                    padding:
                                        EdgeInsets.symmetric(vertical: 4),
                                    child: Text('Browse',
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold)),
                                  ),
                                GridView.count(
                                  crossAxisCount: 3,
                                  mainAxisSpacing: 4,
                                  crossAxisSpacing: 4,
                                  shrinkWrap: true,
                                  physics:
                                      const NeverScrollableScrollPhysics(),
                                  children: [
                                    for (final g in _gifs)
                                      _gifTile(
                                        imageUrl: g.preview.isNotEmpty
                                            ? g.preview
                                            : g.url,
                                        isFav: _isFav(g.slug),
                                        onTap: () => Navigator.of(context)
                                            .pop(g.slug),
                                        onFav: () => _toggleFav(g),
                                      ),
                                  ],
                                ),
                              ],
                            ],
                          ),
          ),
        ],
      ),
    );
  }
}

// ---- search --------------------------------------------------------------

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _q = TextEditingController();
  List<String> _tags = [];
  List<VideoItem> _results = [];
  bool _searching = false;
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    SmolishRepo.popularTags()
        .then((t) => mounted ? setState(() => _tags = t) : null)
        .catchError((_) {});
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) return;
    // @user goes straight to the full profile page.
    if (q.startsWith('@')) {
      final h = q.substring(1).trim();
      if (h.isNotEmpty && mounted) {
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) =>
                    CreatorPage(handle: h, name: '@$h')));
      }
      return;
    }
    setState(() {
      _searching = true;
      _searched = true;
    });
    try {
      // Logged-in gated search first (real titles/handles when it works),
      // merged with the public index by id.
      List<VideoItem> gated = [];
      if (authService.isLoggedIn) {
        try {
          gated = await SmolishApi.searchVideos(q);
        } catch (_) {}
      }
      final pub = await SmolishRepo.searchVideos(q);
      final seen = <String>{};
      final merged = <VideoItem>[];
      for (final v in [...gated, ...pub]) {
        if (seen.add(v.id)) merged.add(v);
      }
      if (!mounted) return;
      setState(() {
        _results = merged;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _searching = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Search failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _q,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Search videos, #tags, @users',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                    onPressed: _search, icon: const Icon(Icons.arrow_forward)),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          if (!_searched) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Popular tags',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
            ),
            Expanded(
              child: _tags.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Wrap(
                            spacing: 8,
                            children: [
                              for (final t in _tags)
                                ActionChip(
                                  label: Text('#$t'),
                                  onPressed: () {
                                    _q.text = '#$t';
                                    _search();
                                  },
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ] else
            Expanded(
              child: _searching
                  ? const Center(child: CircularProgressIndicator())
                  : _results.isEmpty
                      ? const Center(child: Text('No results.'))
                      : GridView.count(
                          crossAxisCount: 3,
                          mainAxisSpacing: 2,
                          crossAxisSpacing: 2,
                          children: [
                            for (final v in _results)
                              GestureDetector(
                                onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => Scaffold(
                                              appBar:
                                                  AppBar(title: Text(v.title)),
                                              body: FeedSwipe(videos: [v]),
                                            ))),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Image.network(v.thumbnail,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) =>
                                            const ColoredBox(
                                                color: Colors.black)),
                                    Positioned(
                                      left: 4,
                                      right: 4,
                                      bottom: 4,
                                      child: Text(v.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 11)),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
            ),
        ],
      ),
    );
  }
}

// ---- me / login ----------------------------------------------------------

class MePage extends StatefulWidget {
  const MePage({super.key});
  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> {
  final _cookieCtrl = TextEditingController();
  bool _saving = false;
  String? _sessionInfo;

  @override
  void initState() {
    super.initState();
    _refreshSession();
  }

  Future<void> _refreshSession() async {
    if (!authService.isLoggedIn) {
      setState(() => _sessionInfo = null);
      return;
    }
    // get-session is behind the signing gate, so validate through the
    // in-app browser's signed fetch, not direct HTTP.
    try {
      final g = await SmolishApi.testGateSession();
      if (!mounted) return;
      if (g.status == 200) {
        try {
          final j = jsonDecode(g.body);
          final user = (j is Map ? j['user'] : null) as Map?;
          setState(() => _sessionInfo = user != null
              ? 'Logged in as ${user['name'] ?? user['email'] ?? 'Smolish user'}'
              : 'Session active.');
        } catch (_) {
          setState(() => _sessionInfo = 'Session active.');
        }
      } else if (g.status == 401 || g.status == 403) {
        setState(() => _sessionInfo =
            'Session rejected (HTTP ${g.status}). Re-login via the sandbox below.');
      } else {
        setState(
            () => _sessionInfo = 'Session check returned HTTP ${g.status}.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _sessionInfo = 'Session check failed: $e');
    }
  }

  Future<void> _openSiteLogin(String provider) async {
    // In-app sandbox: real smolish.com, user picks Discord/Google there,
    // Solmish auto-imports the session cookies when they land.
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LoginWebScreen()),
    );
    if (ok == true) {
      await _refreshSession();
      if (mounted) setState(() {});
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'No session captured - finish logging in with $provider, or paste cookies below.')));
    }
  }

  Future<void> _diagnose() async {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        title: Text('Testing session…'),
        content: SizedBox(
          height: 60,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );
    String direct = 'not run';
    String gate = 'not run';
    try {
      direct = await SmolishApi.testDirectSession();
    } catch (e) {
      direct = '$e';
    }
    try {
      final g = await SmolishApi.testGateSession();
      final flat = g.body.replaceAll(RegExp(r'\s+'), ' ');
      gate =
          'HTTP ${g.status}: ${flat.length > 160 ? flat.substring(0, 160) : flat}';
    } catch (e) {
      gate = '$e';
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Session test'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Direct:', style: TextStyle(fontWeight: FontWeight.bold)),
              SelectableText(direct),
              const SizedBox(height: 12),
              const Text('In-app browser:',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              SelectableText(gate),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {    final text = _cookieCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _saving = true);
    await authService.saveCookieString(text);
    await _refreshSession();
    if (!mounted) return;
    setState(() => _saving = false);
    _cookieCtrl.clear();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(authService.isLoggedIn
            ? 'Cookies saved. ${_sessionInfo ?? ''}'
            : 'Saved, but no session token found. Check what you pasted.')));
  }

  @override
  Widget build(BuildContext context) {
    if (!authService.isLoggedIn) {
      return SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('Log in to Solmish',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Tap a login button, finish logging in, then tap I\'m done.'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _openSiteLogin('Discord'),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Continue with Discord'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: () => _openSiteLogin('Google'),
              icon: const Icon(Icons.g_mobiledata),
              label: const Text('Continue with Google'),
            ),
            const SizedBox(height: 20),
            const Text('Or paste cookies',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _cookieCtrl,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'name=value; name=value',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save & log in'),
            ),
          ],
        ),
      );
    }
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Me', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(_sessionInfo ?? 'Logged in.',
              style: const TextStyle(color: Colors.green)),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.upload_outlined),
            title: const Text('Upload a video'),
            subtitle: const Text('Opens Smolish Studio in your browser'),
            onTap: () => launchUrl(Uri.parse('https://smolish.com/studio'),
                mode: LaunchMode.externalApplication),
          ),
          ListTile(
            leading: const Icon(Icons.cookie_outlined),
            title: const Text('Refresh cookies'),
            subtitle: const Text('Paste a fresh cookie string'),
            onTap: () async {
              await authService.logout();
              if (mounted) setState(() {});
            },
          ),
          ListTile(
            leading: const Icon(Icons.network_check_outlined),
            title: const Text('Test session'),
            subtitle:
                const Text('Checks login directly and through the app'),
            onTap: _diagnose,
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Log out'),
            onTap: () async {
              await authService.logout();
              if (mounted) setState(() => _sessionInfo = null);
            },
          ),
          const Divider(),
          const Text(
              'If something says you are not logged in, log in again with the buttons above.'),
        ],
      ),
    );
  }
}

// ---- profile -------------------------------------------------------------

class CreatorPage extends StatefulWidget {
  final String handle;
  final String name;
  const CreatorPage({super.key, required this.handle, required this.name});
  @override
  State<CreatorPage> createState() => _CreatorPageState();
}

class _CreatorPageState extends State<CreatorPage> {
  SmolProfile? _profile;
  List<VideoItem> _videos = [];
  bool _loading = true;
  String? _error;
  bool _following = false;
  bool _followBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Full profile from the real /@handle page through the browser.
      final p = await SmolishApi.profile(widget.handle);
      if (!mounted) return;
      setState(() => _profile = p);
      // Videos: author's feed first, public index as backup.
      List<VideoItem> vids = [];
      try {
        vids = await SmolishApi.profileFeed(widget.handle,
            userId: p.userId);
      } catch (_) {}
      if (vids.isEmpty) {
        try {
          vids = await SmolishRepo.profileVideos(widget.handle);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _videos = vids;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // Profile page failed (e.g. logged out + blocked): still try the
      // public video list so the page isn't empty.
      List<VideoItem> vids = [];
      try {
        vids = await SmolishRepo.profileVideos(widget.handle);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _videos = vids;
        _loading = false;
        if (vids.isEmpty) _error = '$e';
      });
    }
  }

  Future<void> _follow() async {
    if (!authService.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Log in first (Me tab) to follow creators.')));
      return;
    }
    final userId = _profile?.userId ?? '';
    if (userId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not resolve this user - try again later.')));
      return;
    }
    final want = !_following;
    setState(() {
      _following = want;
      _followBusy = true;
    });
    try {
      await SmolishApi.toggleFollow(userId, want);
    } on GateException catch (e) {
      if (!mounted) return;
      setState(() => _following = !want);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    } catch (e) {
      if (!mounted) return;
      setState(() => _following = !want);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Follow failed: $e')));
    } finally {
      if (mounted) setState(() => _followBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _profile;
    final title = p?.displayName ?? widget.name;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 32,
                          backgroundImage: p != null && p.avatar.isNotEmpty
                              ? NetworkImage(p.avatar)
                              : null,
                          child: p == null || p.avatar.isEmpty
                              ? const Icon(Icons.person_outline, size: 32)
                              : null,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title,
                                  style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold)),
                              Text('@${p?.handle ?? widget.handle}',
                                  style: const TextStyle(color: Colors.grey)),
                              if (p != null &&
                                  (p.followers > 0 ||
                                      p.videoCount > 0))
                                Padding(
                                  padding:
                                      const EdgeInsets.only(top: 4),
                                  child: Text(
                                    '${p.followers} followers · ${p.videoCount} videos',
                                    style: const TextStyle(
                                        color: Colors.grey, fontSize: 13),
                                  ),
                                ),
                              if (p != null && p.joined.isNotEmpty)
                                Padding(
                                  padding:
                                      const EdgeInsets.only(top: 2),
                                  child: Text(
                                    'Joined ${p.joined}',
                                    style: const TextStyle(
                                        color: Colors.grey, fontSize: 13),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        FilledButton(
                          onPressed: _followBusy ? null : _follow,
                          child: Text(
                              _following ? 'Following' : 'Follow'),
                        ),
                      ],
                    ),
                  ),
                  if (p != null && p.bio.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(p.bio),
                    ),
                  const SizedBox(height: 12),
                  if (_error != null && _videos.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, textAlign: TextAlign.center),
                    )
                  else if (_videos.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No videos yet.',
                          textAlign: TextAlign.center),
                    )
                  else
                    GridView.count(
                      crossAxisCount: 3,
                      mainAxisSpacing: 2,
                      crossAxisSpacing: 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        for (final v in _videos)
                          GestureDetector(
                            onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => Scaffold(
                                          appBar: AppBar(
                                              title: Text(v.title)),
                                          body:
                                              FeedSwipe(videos: [v]),
                                        ))),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.network(v.thumbnail,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        const ColoredBox(
                                            color: Colors.black)),
                                if (v.likes > 0 || v.comments > 0)
                                  Positioned(
                                    left: 4,
                                    bottom: 4,
                                    child: Text(
                                      '♥ ${v.likes} 💬 ${v.comments}',
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
    );
  }
}

// ---- settings ------------------------------------------------------------

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Solmish',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('A native Smolish client. Feed, search, profiles, likes, comments, saves.'),
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(authService.isLoggedIn
                ? 'Logged in - manage session'
                : 'Log in with Discord / Google / cookies'),
            onTap: () => DefaultTabController.of(context),
          ),
          ListTile(
            leading: const Icon(Icons.open_in_browser),
            title: const Text('Open smolish.com'),
            onTap: () => launchUrl(Uri.parse('https://smolish.com/'),
                mode: LaunchMode.externalApplication),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Log out / clear cookies'),
            onTap: () async {
              await authService.logout();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Logged out.')));
              }
            },
          ),
          const Divider(),
          const Text(
              'If the app says you are not logged in, log in again from the Me tab.'),
        ],
      ),
    );
  }
}
