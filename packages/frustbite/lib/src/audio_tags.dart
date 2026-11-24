import 'dart:typed_data';

/// Metadata tags of an audio source. Missing values are null.
final class AudioTags {
  const AudioTags({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.genre,
    this.comment,
    this.year,
    this.track,
    this.trackTotal,
    this.disc,
    this.discTotal,
  });

  /// Tags of a source that has none.
  static const empty = AudioTags();

  final String? title, artist, album, albumArtist, genre, comment;
  final int? year, track, trackTotal, disc, discTotal;

  @override
  String toString() =>
      'AudioTags(title: $title, artist: $artist, '
      'album: $album, year: $year)';
}

/// Parses the JSON object produced by the engine. Not exported.
AudioTags audioTagsFromJson(Map<String, Object?> json) => AudioTags(
  title: json['title'] as String?,
  artist: json['artist'] as String?,
  album: json['album'] as String?,
  albumArtist: json['albumArtist'] as String?,
  genre: json['genre'] as String?,
  comment: json['comment'] as String?,
  year: (json['year'] as num?)?.toInt(),
  track: (json['track'] as num?)?.toInt(),
  trackTotal: (json['trackTotal'] as num?)?.toInt(),
  disc: (json['disc'] as num?)?.toInt(),
  discTotal: (json['discTotal'] as num?)?.toInt(),
);

/// Embedded cover art.
final class AudioCover {
  const AudioCover({required this.data, required this.mimeType});

  /// Encoded image bytes.
  final Uint8List data;

  /// MIME type such as `image/png`.
  final String mimeType;
}
