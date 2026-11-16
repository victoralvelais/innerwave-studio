import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'discovery.dart';
import 'model.dart';
import 'studio_view.dart';
import 'video_links.dart';

typedef ImportMedia = Future<Clip> Function(
    File file, String name, LayerType type, int at,
    {String? credit, bool Function()? cancelled, void Function()? onCommit});

Future<PlatformFile?> _pickVideo(bool gallery) async {
  final result = await FilePicker.platform.pickFiles(
      type: gallery ? FileType.video : FileType.custom,
      allowedExtensions: gallery
          ? null
          : [
              'mp4',
              'm4v',
              'mov',
              'webm',
              'mkv',
              'ogv',
              'avi',
              '3gp',
              'mpeg',
              'mpg'
            ]);
  return result?.files.single;
}

Future<bool> _openExternal(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

enum _Phase {
  idle,
  searching,
  choosing,
  picking,
  downloading,
  extracting,
  saving
}

class DiscoverPage extends StatefulWidget {
  const DiscoverPage(
      {super.key,
      required this.at,
      required this.cache,
      required this.importMedia,
      this.clientFactory = DiscoveryClient.new,
      this.pickVideo = _pickVideo,
      this.openLink = _openExternal});
  final int at;
  final Directory cache;
  final ImportMedia importMedia;
  final DiscoveryClient Function() clientFactory;
  final Future<PlatformFile?> Function(bool gallery) pickVideo;
  final Future<bool> Function(Uri) openLink;
  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  final query = TextEditingController();
  Timer? linkLookup;
  DiscoveryClient? client;
  List<DiscoveredMedia>? results;
  String searched = '', item = '';
  String? error;
  VoidCallback? retry;
  double? progress;
  int serial = 0;
  _Phase phase = _Phase.idle;
  bool get selecting => phase == _Phase.idle || phase == _Phase.searching;
  bool current(int request) => mounted && request == serial;
  VideoSourceLink? get link => VideoSourceLink.parse(query.text.trim());
  bool get unknownUrl {
    final uri = Uri.tryParse(query.text.trim());
    return uri != null && uri.hasAuthority && link == null;
  }

  @override
  void dispose() {
    serial++;
    linkLookup?.cancel();
    client?.close();
    query.dispose();
    super.dispose();
  }

  int begin(_Phase next, [String name = '']) {
    serial++;
    linkLookup?.cancel();
    client?.close();
    client = null;
    setState(() {
      phase = next;
      error = null;
      retry = null;
      item = name;
      progress = null;
    });
    return serial;
  }

  void fail(int op, Object cause, VoidCallback repeat) {
    if (!current(op)) return;
    setState(() {
      phase = _Phase.idle;
      error = cause is FormatException ? cause.message : cause.toString();
      retry = repeat;
    });
  }

  void changed(String _) {
    if (selecting) {
      begin(_Phase.idle);
      setState(() {
        searched = '';
        results = null;
      });
      if (link != null) {
        linkLookup = Timer(const Duration(milliseconds: 350), search);
      }
    }
  }

  Future<void> search([String? suggestion]) async {
    if (suggestion != null) query.text = suggestion;
    final text = query.text.trim();
    FocusScope.of(context).unfocus();
    final source = link;
    if (!selecting || text.isEmpty || unknownUrl) return;
    final op = begin(_Phase.searching);
    setState(() {
      searched = text;
      results = null;
    });
    final service = widget.clientFactory();
    client = service;
    try {
      final hits = source == null
          ? await service.search(text)
          : await service.findCopies(source);
      if (current(op))
        setState(() {
          results = hits;
          phase = _Phase.idle;
        });
    } catch (e) {
      fail(op, e, () => search(text));
    } finally {
      service.close();
      if (identical(client, service)) client = null;
    }
  }

  Future<void> open(Uri uri) async {
    try {
      if (!await widget.openLink(uri))
        throw const FormatException('No app could open this link.');
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<LayerType?> layer(String title, {String? credit}) =>
      showModalBottomSheet<LayerType>(
          context: context,
          isScrollControlled: true,
          builder: (ctx) => SafeArea(
              child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(15, 0, 15, 16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Add audio to a layer',
                            style: TextStyle(
                                fontSize: 22, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        Text(title,
                            maxLines: 3, overflow: TextOverflow.ellipsis),
                        Text('At ${timeOf(widget.at, fraction: true)}',
                            style: const TextStyle(color: softText)),
                        if (credit != null)
                          Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: SelectableText(credit,
                                  style: const TextStyle(
                                      fontSize: 12, color: softText))),
                        for (final type in LayerType.values)
                          ListTile(
                              leading: Icon(glyph(type), color: tone(type)),
                              title: Text(type.label),
                              trailing: const Icon(Icons.add_rounded, size: 18),
                              onTap: () => Navigator.pop(ctx, type)),
                      ]))));

  Future<void> chooseRemote(DiscoveredMedia hit) async {
    final op = begin(_Phase.choosing);
    final source = link;
    final credit = source == null
        ? hit.credit
        : '${hit.credit}\n${source.platform} source: ${source.url}';
    final type = await layer(hit.title, credit: credit);
    if (!current(op)) return;
    if (type == null) {
      begin(_Phase.idle);
      return;
    }
    await remote(hit, type, credit);
  }

  Future<void> remote(
      DiscoveredMedia hit, LayerType type, String credit) async {
    final op = begin(_Phase.downloading, hit.title);
    final service = widget.clientFactory();
    client = service;
    Directory? temp;
    try {
      temp = await widget.cache.createTemp('discover-');
      if (!current(op)) return;
      var lastUpdate = 0;
      final file =
          await service.download(hit, temp, onProgress: (bytes, total) {
        if (!current(op) || total == null || total <= 0) return;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastUpdate < 100 && bytes < total) return;
        lastUpdate = now;
        setState(() => progress = (bytes / total).clamp(0, 1));
      });
      if (current(op)) await extract(op, file, hit.title, type, credit);
    } catch (e) {
      fail(op, e, () => remote(hit, type, credit));
    } finally {
      service.close();
      if (identical(client, service)) client = null;
      if (temp != null && await temp.exists())
        await temp.delete(recursive: true);
    }
  }

  Future<void> local(bool gallery, VideoSourceLink? source) async {
    final op = begin(_Phase.picking);
    try {
      final picked = await widget.pickVideo(gallery);
      if (!current(op)) return;
      if (picked == null) {
        begin(_Phase.idle);
        return;
      }
      if (picked.path == null)
        throw const FormatException(
            'Save this video on your device and try again.');
      final name = picked.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
      final title = name.isEmpty ? 'Video audio' : name;
      final credit =
          source == null ? null : '${source.platform}\n${source.url}';
      setState(() => phase = _Phase.choosing);
      final type = await layer(title, credit: credit);
      if (!current(op)) return;
      if (type == null) {
        begin(_Phase.idle);
        return;
      }
      await extract(op, File(picked.path!), title, type, credit);
    } catch (e) {
      fail(op, e, () => local(gallery, source));
    }
  }

  Future<void> extract(
      int op, File file, String title, LayerType type, String? credit) async {
    setState(() {
      phase = _Phase.extracting;
      item = title;
      progress = null;
    });
    final clip = await widget.importMedia(file, title, type, widget.at,
        credit: credit,
        cancelled: () => !current(op),
        onCommit: () {
          if (current(op)) setState(() => phase = _Phase.saving);
        });
    if (current(op)) Navigator.pop(context, clip);
  }

  Widget saved(VideoSourceLink? source) => Card(
      color: panel,
      margin: EdgeInsets.zero,
      child: Padding(
          padding: const EdgeInsets.all(14),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                source == null
                    ? 'Import a saved video'
                    : 'Import from ${source.platform}',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            if (source != null) ...[
              const SizedBox(height: 6),
              Text(source.instructions,
                  style: const TextStyle(color: softText)),
              TextButton.icon(
                  onPressed: selecting ? () => open(source.url) : null,
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: Text('Open on ${source.platform}')),
            ],
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              OutlinedButton.icon(
                  onPressed: selecting ? () => local(true, source) : null,
                  icon: const Icon(Icons.video_library_outlined, size: 17),
                  label: const Text('Photos / Gallery')),
              OutlinedButton.icon(
                  onPressed: selecting ? () => local(false, source) : null,
                  icon: const Icon(Icons.folder_open_outlined, size: 17),
                  label: const Text('Files')),
            ]),
          ])));

  Widget result(DiscoveredMedia hit) {
    final video = hit.mimeType.startsWith('video/') ||
        hit.mediaUrl.path.toLowerCase().endsWith('.ogv');
    final size = (hit.bytes / 1000000).toStringAsFixed(1);
    return ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        leading: Icon(video ? Icons.movie_outlined : Icons.graphic_eq_rounded,
            color: video ? violet : mint),
        title: Text(hit.title, maxLines: 3, overflow: TextOverflow.ellipsis),
        subtitle: Text(
            [
              if (hit.creator.isNotEmpty) hit.creator,
              if (hit.license.isNotEmpty) hit.license,
              if (hit.bytes > 0) '$size MB'
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
        trailing: IconButton(
            tooltip: 'Source details for ${hit.title}',
            icon: const Icon(Icons.info_outline, size: 20),
            onPressed: !selecting
                ? null
                : () => showDialog<void>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                            title: const Text('Source credit'),
                            content: SingleChildScrollView(
                                child: SelectableText(hit.credit)),
                            actions: [
                              TextButton(
                                  onPressed: () => open(hit.sourcePage),
                                  child: const Text('Open source')),
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('Close'))
                            ]))),
        onTap: selecting ? () => chooseRemote(hit) : null);
  }

  @override
  Widget build(BuildContext context) {
    final source = link, text = query.text.trim();
    final loading = [
      _Phase.searching,
      _Phase.downloading,
      _Phase.extracting,
      _Phase.saving
    ].contains(phase);
    final message = switch (phase) {
      _Phase.searching => source == null
          ? 'Searching Wikimedia Commons…'
          : 'Looking for an importable copy…',
      _Phase.downloading => 'Downloading $item…',
      _Phase.extracting => 'Extracting audio from $item…',
      _Phase.saving => 'Adding the layer…',
      _ => '',
    };
    return PopScope<Clip>(
        canPop: phase != _Phase.saving,
        onPopInvokedWithResult: (popped, _) {
          if (popped) {
            serial++;
            client?.close();
          }
        },
        child: Scaffold(
            appBar: AppBar(title: const Text('Discover')),
            body: SafeArea(
                child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: ListView(
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                            children: [
                              TextField(
                                  controller: query,
                                  enabled: selecting,
                                  textInputAction: TextInputAction.search,
                                  onChanged: changed,
                                  onSubmitted: (_) => search(),
                                  decoration: InputDecoration(
                                      labelText:
                                          'Search sounds or paste a video link',
                                      prefixIcon:
                                          const Icon(Icons.search_rounded),
                                      suffixIcon: text.isEmpty
                                          ? null
                                          : IconButton(
                                              tooltip: 'Clear search',
                                              icon: const Icon(Icons.close),
                                              onPressed: () {
                                                query.clear();
                                                changed('');
                                              }))),
                              const SizedBox(height: 12),
                              if (source == null && !unknownUrl) ...[
                                Align(
                                    alignment: Alignment.centerLeft,
                                    child: FilledButton.icon(
                                        onPressed: selecting && text.isNotEmpty
                                            ? () => search()
                                            : null,
                                        icon:
                                            const Icon(Icons.search, size: 17),
                                        label: const Text(
                                            'Search Wikimedia Commons'))),
                                if (text.isNotEmpty)
                                  Wrap(spacing: 4, children: [
                                    for (final platform in [
                                      'YouTube',
                                      'TikTok'
                                    ])
                                      TextButton.icon(
                                          onPressed: selecting
                                              ? () => open(videoSearchUrl(
                                                  platform, text))
                                              : null,
                                          icon: const Icon(Icons.open_in_new,
                                              size: 13),
                                          label: Text('Search $platform')),
                                  ])
                                else
                                  Wrap(spacing: 6, children: [
                                    for (final hint in [
                                      'Rain',
                                      'Ocean waves',
                                      'Birdsong'
                                    ])
                                      ActionChip(
                                          label: Text(hint),
                                          onPressed: selecting
                                              ? () => search(hint)
                                              : null),
                                  ]),
                              ],
                              if (unknownUrl)
                                const Padding(
                                    padding: EdgeInsets.only(bottom: 10),
                                    child: Text(
                                        'Use a YouTube or TikTok video link, or import a saved file.',
                                        style: TextStyle(color: softText))),
                              if (source == null) ...[
                                const SizedBox(height: 6),
                                saved(null)
                              ],
                              if (loading) ...[
                                const SizedBox(height: 18),
                                LinearProgressIndicator(
                                    value: phase == _Phase.downloading
                                        ? progress
                                        : null),
                                Row(children: [
                                  Expanded(child: Text(message)),
                                  if (phase != _Phase.saving)
                                    TextButton(
                                        onPressed: () => begin(_Phase.idle),
                                        child: const Text('Cancel'))
                                ]),
                              ],
                              if (error != null) ...[
                                const SizedBox(height: 12),
                                Text(error!,
                                    style: const TextStyle(color: apricot)),
                                Align(
                                    alignment: Alignment.centerLeft,
                                    child: OutlinedButton(
                                        onPressed: retry,
                                        child: const Text('Retry'))),
                              ],
                              if (results != null && !unknownUrl) ...[
                                const SizedBox(height: 16),
                                Text(
                                    source == null
                                        ? 'Wikimedia Commons'
                                        : 'Importable copies on Wikimedia Commons',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                if (results!.isEmpty)
                                  Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 10),
                                      child: Text(source == null
                                          ? 'No audio or video found for “$searched”. Try a different search.'
                                          : 'No matching copy found. You can import a saved video below.')),
                                for (final hit in results!) result(hit),
                              ],
                              if (source != null) ...[
                                if (results == null &&
                                    !loading &&
                                    error == null)
                                  Align(
                                      alignment: Alignment.centerLeft,
                                      child: TextButton(
                                          onPressed:
                                              selecting ? () => search() : null,
                                          child: const Text(
                                              'Find an importable copy'))),
                                const SizedBox(height: 10),
                                saved(source),
                              ],
                            ]))))));
  }
}
