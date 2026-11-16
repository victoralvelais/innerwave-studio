import 'dart:math' as math;

const sampleRate = 44100;
const double silentGainDb = -144;
const frameBytes = 4;
typedef LoopRange = ({int start, int end});
int frameAt(double seconds) => (seconds * sampleRate).round();
String makeId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 30)}';

enum LayerType { beat, texture, voice }

enum EarRoute { both, left, right }

int scaleFrames(int frames, int from, int to) =>
    (frames * to + from ~/ 2) ~/ from;

class BeatTone {
  const BeatTone({this.base = 250, this.beat = 4, double? left, double? right})
      : _left = left,
        _right = right;
  final double base, beat;
  final double? _left, _right;
  double get left => _left ?? leftHz(false);
  double get right => _right ?? rightHz(false);
  double leftHz(bool independent) =>
      independent ? left : math.max(1, base - beat / 2);
  double rightHz(bool independent) =>
      independent ? right : leftHz(false) + beat;
  BeatTone copyWith(
          {double? base, double? beat, double? left, double? right}) =>
      BeatTone(
          base: base ?? this.base,
          beat: beat ?? this.beat,
          left: left ?? _left,
          right: right ?? _right);
  Map<String, dynamic> toJson() => {
        'base': base,
        'beat': beat,
        if (_left != null) 'left': _left,
        if (_right != null) 'right': _right
      };
  factory BeatTone.fromJson(Map<String, dynamic> m) => BeatTone(
      base: (m['base'] as num).toDouble(),
      beat: (m['beat'] as num).toDouble(),
      left: (m['left'] as num?)?.toDouble(),
      right: (m['right'] as num?)?.toDouble());
  static const dusk = BeatTone(base: 183, beat: 6);
}

extension LayerLabel on LayerType {
  String get label => switch (this) {
        LayerType.beat => 'Binaural beat',
        LayerType.texture => 'ASMR texture',
        LayerType.voice => 'Voice',
      };
}

class Clip {
  Clip({
    required this.id,
    required this.source,
    required this.name,
    required this.type,
    required this.frames,
    required this.peaks,
    required this.length,
    this.start = 0,
    this.trim = 0,
    this.gain = -3,
    this.muted = false,
    this.warmth = 0,
    this.presence = 0,
    this.credit,
    this.tone,
    this.ear = EarRoute.both,
    this.sourceRate = sampleRate,
    this.sourceFrames,
    this.original,
    this.fadeOut = 0,
  });

  final String id;
  final String source;
  final int frames;
  final List<double> peaks;
  final String? credit;
  final BeatTone? tone;
  final EarRoute ear;
  final int sourceRate;
  final int? sourceFrames;
  final String? original;
  final int fadeOut;
  bool get floatingSource => source.endsWith('.f64');
  String fileAtRate(int rate) =>
      rate == sourceRate ? source : '$source.$rate.f64';

  Clip copyWith({EarRoute? ear, BeatTone? tone, int? frames, int? length}) =>
      Clip.fromJson({
        ...toJson(),
        if (ear != null) 'ear': ear.name,
        if (tone != null) 'tone': tone.toJson(),
        if (frames != null) 'frames': frames,
        if (length != null) 'length': length
      });
  String name;
  LayerType type;
  int start;
  int trim;
  int length;
  double gain;
  bool muted;
  double warmth;
  double presence;
  int get end => start + length;

  Map<String, dynamic> toJson() => {
        'id': id,
        'source': source,
        'name': name,
        'type': type.name,
        'frames': frames,
        'peaks': peaks,
        'start': start,
        'trim': trim,
        'length': length,
        'gain': gain,
        'muted': muted,
        'warmth': warmth,
        'presence': presence,
        if (credit != null) 'credit': credit,
        if (tone != null) 'tone': tone!.toJson(),
        if (ear != EarRoute.both) 'ear': ear.name,
        if (sourceRate != sampleRate) 'sourceRate': sourceRate,
        if (sourceFrames != null) 'sourceFrames': sourceFrames,
        if (original != null) 'original': original,
        if (fadeOut > 0) 'fadeOut': fadeOut,
      };

  factory Clip.fromJson(Map<String, dynamic> map) => Clip(
        id: map['id'],
        source: map['source'],
        name: map['name'],
        type: LayerType.values.byName(map['type']),
        frames: map['frames'],
        peaks:
            (map['peaks'] as List).map((p) => (p as num).toDouble()).toList(),
        start: map['start'],
        trim: map['trim'],
        length: map['length'],
        gain: (map['gain'] as num).toDouble(),
        muted: map['muted'],
        warmth: (map['warmth'] as num).toDouble(),
        presence: (map['presence'] as num).toDouble(),
        credit: map['credit'] as String?,
        tone: map['tone'] == null
            ? (map['source'] == 'dusk-carrier.pcm' ? BeatTone.dusk : null)
            : BeatTone.fromJson(map['tone']),
        ear: EarRoute.values.byName(map['ear'] ?? 'both'),
        sourceRate: map['sourceRate'] ?? sampleRate,
        sourceFrames: map['sourceFrames'],
        original: map['original'],
        fadeOut: map['fadeOut'] ?? 0,
      );
}

class Mix {
  Mix(this.id, this.name, this.clips, {Set<LayerType>? independentLayers})
      : independentLayers = {...?independentLayers};
  final Set<LayerType> independentLayers;
  bool independent(LayerType layer) => independentLayers.contains(layer);
  Mix withClips(List<Clip> next) =>
      Mix(id, name, next, independentLayers: independentLayers);
  bool get highPrecision =>
      clips.any((c) => c.tone != null || c.floatingSource);
  int get masterRate =>
      clips.fold(sampleRate, (rate, c) => math.max(rate, c.sourceRate));

  // Session edits use the historical reference clock. Convert only the render
  // snapshot, preserving the exact final native sample of an untrimmed source.
  Mix atRate(int rate) =>
      withClips([for (final c in clips) _scaleClip(c, rate)]);
  static Clip _scaleClip(Clip c, int rate) {
    int scale(int f) => scaleFrames(f, sampleRate, rate);
    final total = c.sourceFrames == null
        ? scale(c.frames)
        : scaleFrames(c.sourceFrames!, c.sourceRate, rate);
    final trim = scale(c.trim).clamp(0, total);
    final end = c.trim + c.length == c.frames
        ? total
        : scale(c.trim + c.length).clamp(trim, total);
    return Clip(
        id: c.id,
        name: c.name,
        type: c.type,
        source: c.fileAtRate(rate),
        frames: total,
        peaks: c.peaks,
        length: end - trim,
        start: scale(c.start),
        trim: trim,
        gain: c.gain,
        muted: c.muted,
        warmth: c.warmth,
        presence: c.presence,
        tone: c.tone,
        ear: c.ear,
        credit: c.credit,
        original: c.original,
        sourceRate: rate,
        fadeOut: scale(c.fadeOut));
  }

  final String id;
  String name;
  final List<Clip> clips;
  final List<(int, Clip)> removed = [];

  void removeLayer(Clip clip) {
    final index = clips.indexWhere((c) => c.id == clip.id);
    if (index >= 0) removed.add((index, clips.removeAt(index)));
  }

  Clip restoreLayer() {
    final (index, clip) = removed.removeLast();
    clips.insert(index.clamp(0, clips.length), clip);
    return clip;
  }

  int get end => clips.fold(0, (last, clip) => math.max(last, clip.end));
  Map<String, dynamic> toJson() => {
        'version': 1,
        'id': id,
        'name': name,
        'clips': clips.map((clip) => clip.toJson()).toList(),
        if (independentLayers.isNotEmpty)
          'independent': independentLayers.map((e) => e.name).toList(),
        if (removed.isNotEmpty)
          'removed': [
            for (final (index, clip) in removed)
              {'index': index, 'clip': clip.toJson()},
          ],
      };
  factory Mix.fromJson(Map<String, dynamic> map) {
    if (map['version'] != 1)
      throw const FormatException('Unknown session version.');
    final mix = Mix(
        map['id'],
        map['name'],
        (map['clips'] as List)
            .map((clip) => Clip.fromJson(clip as Map<String, dynamic>))
            .toList());
    for (final name in map['independent'] as List? ?? []) {
      mix.independentLayers.add(LayerType.values.byName(name));
    }
    for (final item in map['removed'] as List? ?? []) {
      mix.removed.add((item['index'] as int, Clip.fromJson(item['clip'])));
    }
    return mix;
  }
}
