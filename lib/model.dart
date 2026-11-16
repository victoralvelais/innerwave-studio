import 'dart:math' as math;

const sampleRate = 44100;
const frameBytes = 4;
int frameAt(double seconds) => (seconds * sampleRate).round();
String makeId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 30)}';

enum LayerType { beat, texture, voice }

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
  });

  final String id;
  final String source;
  final int frames;
  final List<double> peaks;
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
      );
}

class Mix {
  Mix(this.id, this.name, this.clips);
  final String id;
  String name;
  final List<Clip> clips;
  int get end => clips.fold(0, (last, clip) => math.max(last, clip.end));
  Map<String, dynamic> toJson() => {
        'version': 1,
        'id': id,
        'name': name,
        'clips': clips.map((clip) => clip.toJson()).toList(),
      };
  factory Mix.fromJson(Map<String, dynamic> map) {
    if (map['version'] != 1)
      throw const FormatException('Unknown session version.');
    return Mix(
        map['id'],
        map['name'],
        (map['clips'] as List)
            .map((clip) => Clip.fromJson(clip as Map<String, dynamic>))
            .toList());
  }
}
