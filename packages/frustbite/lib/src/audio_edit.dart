part of 'frustbite_base.dart';

/// A lazy list of editing operations on a [Frustbite], started with
/// [Frustbite.edit] or [Frustbite.concat].
///
/// Each method returns a new [AudioEdit]; nothing is decoded until a terminal
/// call ([render], [toWav], [saveWav] or their async forms) runs the whole list
/// in one native call. The source is never changed. Operations apply in order,
/// each to the result of the previous ones, so positions and durations refer to
/// the audio as it is at that step.
///
/// ```dart
/// final voice = Frustbite.fromFile('voice.m4a');
/// final clean = voice.edit()
///     .trimSilence()
///     .fadeIn(const Duration(milliseconds: 200))
///     .fadeOut(const Duration(milliseconds: 500))
///     .normalize()
///     .render();
/// clean.saveWav('voice.wav');
/// clean.dispose();
/// voice.dispose();
/// ```
///
/// Everything happens in memory: the source and every [append]ed or [mix]ed
/// source are decoded whole. Invalid arguments throw
/// [InvalidParameterException] at the call that receives them.
final class AudioEdit {
  AudioEdit._(this._source, this._ops, this._sources);

  final Frustbite _source;
  final List<Map<String, Object?>> _ops;

  /// Extra sources, by index in the JSON (`append` / `mix`).
  final List<Frustbite> _sources;

  /// The number of operations in this edit.
  int get length => _ops.length;

  AudioEdit _with(Map<String, Object?> op, [Frustbite? extra]) {
    final sources = [..._sources];
    if (extra != null) {
      var index = sources.indexWhere((s) => identical(s, extra));
      if (index == -1) {
        index = sources.length;
        sources.add(extra);
      }
      op['source'] = index;
    }
    return AudioEdit._(_source, [..._ops, op], sources);
  }

  static Never _invalid(String message) =>
      throw frustbiteError(FrustbiteErrorCode.invalidParameter, message);

  static int _micros(Duration value, String name) {
    if (value.isNegative) _invalid('$name must not be negative');
    return value.inMicroseconds;
  }

  static void _checkDb(double value, String name, {bool atMostZero = false}) {
    if (!value.isFinite) _invalid('$name must be finite');
    if (atMostZero && value > 0) _invalid('$name must be <= 0');
  }

  /// Keeps the part from [start] to [end] (to the end when null). Positions
  /// past the end are clamped, so the result may be empty.
  AudioEdit trim({Duration start = Duration.zero, Duration? end}) {
    final startUs = _micros(start, 'start');
    final endUs = end == null ? null : _micros(end, 'end');
    if (endUs != null && endUs < startUs) {
      _invalid('end must not be before start');
    }
    return _with({'op': 'trim', 'start_us': startUs, 'end_us': endUs});
  }

  /// Changes the volume by [db] decibels (`-6` is about half the amplitude).
  /// No limiter: a positive gain can push samples past full scale.
  AudioEdit gain(double db) {
    _checkDb(db, 'db');
    return _with({'op': 'gain', 'db': db});
  }

  /// Scales the audio so its loudest sample peaks at [peakDb] dBFS (`<= 0`).
  /// Silence is left unchanged.
  AudioEdit normalize({double peakDb = -1}) {
    _checkDb(peakDb, 'peakDb', atMostZero: true);
    return _with({'op': 'normalize', 'peak_db': peakDb});
  }

  /// Fades in linearly from silence over [duration] (the whole audio if it
  /// is shorter).
  AudioEdit fadeIn(Duration duration) =>
      _with({'op': 'fade_in', 'duration_us': _micros(duration, 'duration')});

  /// Fades out linearly to silence over the last [duration] (the whole audio
  /// if it is shorter).
  AudioEdit fadeOut(Duration duration) =>
      _with({'op': 'fade_out', 'duration_us': _micros(duration, 'duration')});

  /// Converts to [sampleRate] Hz (1..768000) with a high-quality FFT
  /// resampler. A no-op at the current rate.
  AudioEdit resample(int sampleRate) {
    if (sampleRate < 1 || sampleRate > 768000) {
      _invalid('sampleRate must be in 1..768000');
    }
    return _with({'op': 'resample', 'sample_rate': sampleRate});
  }

  /// Mixes every channel down to one (their average).
  AudioEdit toMono() => _with({'op': 'to_mono'});

  /// Two channels: mono is duplicated, stereo is unchanged, and from more
  /// than two channels the first two are kept.
  AudioEdit toStereo() => _with({'op': 'to_stereo'});

  /// Removes the silence at the start and the end: frames where every channel
  /// stays below [thresholdDb] dBFS (`<= 0`). Audio that is silent throughout
  /// becomes empty.
  AudioEdit trimSilence({double thresholdDb = -50}) {
    _checkDb(thresholdDb, 'thresholdDb', atMostZero: true);
    return _with({'op': 'trim_silence', 'threshold_db': thresholdDb});
  }

  /// Appends [other] after the current audio. [other] is converted to the
  /// current sample rate and channel count first. With a [crossfade], the
  /// two overlap by that much (at most the shorter of the two) with an
  /// equal-power crossfade, so the result is shorter by the overlap.
  AudioEdit append(Frustbite other, {Duration crossfade = Duration.zero}) {
    other._checkDisposed();
    return _with({
      'op': 'append',
      'crossfade_us': _micros(crossfade, 'crossfade'),
    }, other);
  }

  /// Mixes [other] into the current audio, starting at [offset], scaled by
  /// [gainDb]. [other] is converted to the current sample rate and channel
  /// count first, and the result is as long as the longer of the two. The sum
  /// can exceed full scale: follow with [normalize] when that matters.
  AudioEdit mix(
    Frustbite other, {
    double gainDb = 0,
    Duration offset = Duration.zero,
  }) {
    other._checkDisposed();
    _checkDb(gainDb, 'gainDb');
    return _with({
      'op': 'mix',
      'gain_db': gainDb,
      'offset_us': _micros(offset, 'offset'),
    }, other);
  }

  Uint8List get _json => utf8.encode(jsonEncode(_ops));

  void _checkSources() {
    _source._checkDisposed();
    for (final source in _sources) {
      source._checkDisposed();
    }
  }

  List<BackendAudio> get _backends => [
    for (final source in _sources) source._backend,
  ];

  /// Runs [body] with every involved [Frustbite] marked busy, so none can be
  /// disposed while the native call runs.
  Future<T> _busy<T>(Future<T> Function() body) async {
    _checkSources();
    final all = [_source, ..._sources];
    for (final f in all) {
      f._busy++;
    }
    try {
      return await body();
    } finally {
      for (final f in all) {
        f._busy--;
      }
    }
  }

  /// Runs the edit and returns the result as a new [Frustbite] (held in
  /// memory as 32-bit float WAV, so no precision is lost). Dispose it when
  /// done. Heavy: prefer [renderAsync] on the UI thread.
  Frustbite render() {
    _checkSources();
    return Frustbite._(_source._backend.render(_backends, _json));
  }

  /// Like [render], on a background isolate (on web: in a later event-loop
  /// turn). None of the involved sources can be disposed while it runs.
  Future<Frustbite> renderAsync() => _busy(
    () async =>
        Frustbite._(await _source._backend.renderAsync(_backends, _json)),
  );

  /// Runs the edit and encodes the result as a WAV file in [format], without
  /// creating an intermediate [Frustbite].
  Uint8List toWav({WavFormat format = WavFormat.pcm16}) {
    _checkSources();
    return _source._backend.renderWav(_backends, _json, format);
  }

  /// Like [toWav], on a background isolate (on web: in a later event-loop
  /// turn).
  Future<Uint8List> toWavAsync({WavFormat format = WavFormat.pcm16}) =>
      _busy(() => _source._backend.renderWavAsync(_backends, _json, format));

  /// Runs the edit and writes the result to [path] as WAV, replacing any
  /// file there. Throws [FrustbiteIoException] when the file cannot be
  /// written. On web it throws [UnsupportedError]; use [toWav].
  void saveWav(String path, {WavFormat format = WavFormat.pcm16}) {
    BackendAudio.ensureSaveSupported();
    BackendAudio.writeFile(path, toWav(format: format));
  }

  /// Like [saveWav], encoding on a background isolate.
  Future<void> saveWavAsync(
    String path, {
    WavFormat format = WavFormat.pcm16,
  }) async {
    BackendAudio.ensureSaveSupported();
    await BackendAudio.writeFileAsync(path, await toWavAsync(format: format));
  }
}
