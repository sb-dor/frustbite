//! Tags and cover art, read with `lofty`.
//!
//! Unreadable or absent tags are not an error: they yield empty tags. Only a source that
//! cannot be opened at all is an `IoError`.

use std::fs::File;
use std::io::{BufReader, Cursor, Read, Seek};

use lofty::config::ParseOptions;
use lofty::file::{FileType, TaggedFile, TaggedFileExt};
use lofty::picture::{MimeType, PictureType};
use lofty::probe::Probe;
use lofty::tag::{Accessor, ItemKey, Tag};
use serde::Serialize;

use crate::error::FrustbiteErrorCode as Code;
use crate::probe::{FrustbiteAudio, FrustbiteContainer};
use crate::source::AudioSource;

/// The JSON shape handed to Dart. Every key is always present; missing values are `null`.
#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct Tags {
    title: Option<String>,
    artist: Option<String>,
    album: Option<String>,
    album_artist: Option<String>,
    genre: Option<String>,
    comment: Option<String>,
    year: Option<u32>,
    track: Option<u32>,
    track_total: Option<u32>,
    disc: Option<u32>,
    disc_total: Option<u32>,
}

/// Embedded cover art.
#[derive(Debug)]
pub(crate) struct Cover {
    pub(crate) mime: String,
    pub(crate) data: Vec<u8>,
}

/// Everything one read of the file's metadata yields; cached on the handle.
#[derive(Debug)]
pub(crate) struct TagData {
    /// UTF-8 JSON of `Tags`.
    pub(crate) json: Vec<u8>,
    pub(crate) cover: Option<Cover>,
}

fn lofty_type(container: FrustbiteContainer) -> Option<FileType> {
    match container {
        FrustbiteContainer::Mp3 => Some(FileType::Mpeg),
        FrustbiteContainer::Mp4 => Some(FileType::Mp4),
        FrustbiteContainer::Flac => Some(FileType::Flac),
        FrustbiteContainer::Wav => Some(FileType::Wav),
        FrustbiteContainer::Adts => Some(FileType::Aac),
        // Ogg could hold Vorbis or Opus (lofty tells them apart by content); Matroska is not
        // supported by lofty.
        FrustbiteContainer::Ogg | FrustbiteContainer::Mkv => None,
    }
}

fn read_tagged<R: Read + Seek>(reader: R, hint: Option<FrustbiteContainer>) -> Option<TaggedFile> {
    let options = ParseOptions::new().read_properties(false);
    let mut probe = Probe::new(reader).options(options).guess_file_type().ok()?;
    if probe.file_type().is_none()
        && let Some(file_type) = hint.and_then(lofty_type)
    {
        probe = probe.set_file_type(file_type);
    }
    probe.read().ok()
}

/// The primary tag first, then the others in file order.
fn ordered_tags(file: &TaggedFile) -> Vec<&Tag> {
    let primary = file.primary_tag();
    let others = file
        .tags()
        .iter()
        .filter(|tag| primary.is_none_or(|p| !std::ptr::eq(*tag, p)));
    primary.into_iter().chain(others).collect()
}

fn text(tags: &[&Tag], get: impl Fn(&Tag) -> Option<String>) -> Option<String> {
    tags.iter().find_map(|tag| {
        get(tag)
            .map(|s| s.trim().to_owned())
            .filter(|s| !s.is_empty())
    })
}

fn number(tags: &[&Tag], get: impl Fn(&Tag) -> Option<u32>) -> Option<u32> {
    tags.iter().find_map(|tag| get(tag))
}

fn sniff_mime(data: &[u8]) -> &'static str {
    if data.starts_with(&[0x89, b'P', b'N', b'G']) {
        "image/png"
    } else if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "image/jpeg"
    } else if data.starts_with(b"GIF8") {
        "image/gif"
    } else if data.starts_with(b"BM") {
        "image/bmp"
    } else {
        "application/octet-stream"
    }
}

fn cover(tags: &[&Tag]) -> Option<Cover> {
    let picture = tags
        .iter()
        .find_map(|tag| tag.get_picture_type(PictureType::CoverFront))
        .or_else(|| tags.iter().find_map(|tag| tag.pictures().first()))?;
    let mime = match picture.mime_type() {
        Some(MimeType::Unknown(_)) | None => sniff_mime(picture.data()).to_owned(),
        Some(mime) => mime.as_str().to_owned(),
    };
    Some(Cover {
        mime,
        data: picture.data().to_vec(),
    })
}

fn extract(file: &TaggedFile) -> TagData {
    let tags = ordered_tags(file);
    let tags = tags.as_slice();
    let key = |key: ItemKey| move |tag: &Tag| tag.get_string(key).map(str::to_owned);
    let parsed = Tags {
        title: text(tags, |t| t.title().map(|s| s.into_owned())),
        artist: text(tags, |t| t.artist().map(|s| s.into_owned())),
        album: text(tags, |t| t.album().map(|s| s.into_owned())),
        album_artist: text(tags, key(ItemKey::AlbumArtist)),
        genre: text(tags, |t| t.genre().map(|s| s.into_owned())),
        comment: text(tags, |t| t.comment().map(|s| s.into_owned())),
        year: number(tags, |t| t.date().map(|d| u32::from(d.year))).filter(|&y| y > 0),
        track: number(tags, |t| t.track()),
        track_total: number(tags, |t| t.track_total()),
        disc: number(tags, |t| t.disk()),
        disc_total: number(tags, |t| t.disk_total()),
    };
    TagData {
        // Serialising plain strings and integers cannot fail.
        json: serde_json::to_vec(&parsed).unwrap_or_else(|_| b"{}".to_vec()),
        cover: cover(tags),
    }
}

fn read(source: &AudioSource, hint: Option<FrustbiteContainer>) -> Result<TagData, Code> {
    let tagged = match source {
        AudioSource::Memory(bytes) => read_tagged(Cursor::new(bytes.clone()), hint),
        AudioSource::File(path) => {
            let file = File::open(path).map_err(|_| Code::IoError)?;
            read_tagged(BufReader::new(file), hint)
        }
    };
    Ok(tagged.as_ref().map(extract).unwrap_or_else(|| TagData {
        json: serde_json::to_vec(&Tags::default()).unwrap_or_else(|_| b"{}".to_vec()),
        cover: None,
    }))
}

impl FrustbiteAudio {
    /// Tags and cover; read on the first successful call and cached.
    pub(crate) fn tag_data(&self) -> Result<&TagData, Code> {
        if let Some(data) = self.tags_cache().get() {
            return Ok(data);
        }
        #[cfg(test)]
        self.tags_builds
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let data = read(self.source(), self.hint())?;
        Ok(self.tags_cache().get_or_init(|| data))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURES: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../packages/frustbite/test/fixtures/"
    );

    fn open(name: &str) -> FrustbiteAudio {
        FrustbiteAudio::open_file(format!("{FIXTURES}{name}"), None).unwrap()
    }

    fn json(audio: &FrustbiteAudio) -> serde_json::Value {
        serde_json::from_slice(&audio.tag_data().unwrap().json).unwrap()
    }

    #[cfg(feature = "mp3")]
    #[test]
    fn tags_mp3_full() {
        let tags = json(&open("tone.mp3"));
        assert_eq!(tags["title"], "frustbite tone");
        assert_eq!(tags["artist"], "frustbite");
        assert_eq!(tags["album"], "fixtures");
        assert_eq!(tags["genre"], "Test");
        assert_eq!(tags["year"], 2026);
        assert_eq!(tags["track"], 1);
        assert_eq!(tags["trackTotal"], 1);
        for key in ["albumArtist", "comment", "disc", "discTotal"] {
            assert!(tags.get(key).is_some(), "{key} key present");
        }
    }

    #[cfg(all(
        feature = "mp3",
        feature = "aac",
        feature = "flac",
        feature = "vorbis",
        feature = "opus"
    ))]
    #[test]
    fn tags_each_tagged_fixture() {
        for name in ["tone.mp3", "tone.m4a", "tone.flac", "tone.ogg", "tone.opus"] {
            let tags = json(&open(name));
            assert_eq!(tags["title"], "frustbite tone", "{name}");
            assert_eq!(tags["artist"], "frustbite", "{name}");
        }
    }

    #[cfg(feature = "wav")]
    #[test]
    fn tags_missing_returns_empty() {
        let tags = json(&open("notags.wav"));
        let object = tags.as_object().unwrap();
        assert_eq!(object.len(), 11);
        assert!(object.values().all(serde_json::Value::is_null), "{tags}");
    }

    #[cfg(feature = "mp3")]
    #[test]
    fn cover_png() {
        let audio = open("tone.mp3");
        let cover = audio.tag_data().unwrap().cover.as_ref().unwrap();
        assert_eq!(cover.mime, "image/png");
        assert!(cover.data.starts_with(&[0x89, 0x50, 0x4E, 0x47]));
    }

    #[cfg(all(
        feature = "mp3",
        feature = "aac",
        feature = "flac",
        feature = "vorbis",
        feature = "opus"
    ))]
    #[test]
    fn cover_each_fixture() {
        for name in ["tone.mp3", "tone.m4a", "tone.flac", "tone.ogg", "tone.opus"] {
            let audio = open(name);
            let cover = audio
                .tag_data()
                .unwrap()
                .cover
                .as_ref()
                .unwrap_or_else(|| panic!("{name}: no cover"));
            assert_eq!(cover.mime, "image/png", "{name}");
            assert!(cover.data.starts_with(&[0x89, 0x50, 0x4E, 0x47]), "{name}");
        }
    }

    #[cfg(feature = "wav")]
    #[test]
    fn cover_absent() {
        assert!(open("notags.wav").tag_data().unwrap().cover.is_none());
    }

    #[cfg(feature = "mp3")]
    #[test]
    fn tags_latin1_id3v1_title() {
        let tags = json(&open("id3v1_cp1251.mp3"));
        assert!(!tags["title"].as_str().unwrap().is_empty(), "{tags}");
    }

    #[cfg(feature = "mp3")]
    #[test]
    fn tags_from_memory_match_file() {
        let bytes = std::fs::read(format!("{FIXTURES}tone.mp3")).unwrap();
        let memory = FrustbiteAudio::open_memory(&bytes, None).unwrap();
        assert_eq!(json(&memory), json(&open("tone.mp3")));
        assert!(memory.tag_data().unwrap().cover.is_some());
    }

    #[cfg(feature = "mp3")]
    #[test]
    fn tags_are_cached() {
        use std::sync::atomic::Ordering;
        let audio = open("tone.mp3");
        audio.tag_data().unwrap();
        audio.tag_data().unwrap();
        assert_eq!(audio.tags_builds.load(Ordering::SeqCst), 1);
    }

    #[cfg(feature = "wav")]
    #[test]
    fn missing_file_after_open_is_io_error() {
        let path = std::env::temp_dir().join(format!("frustbite_tags_{}.wav", std::process::id()));
        std::fs::copy(format!("{FIXTURES}click.wav"), &path).unwrap();
        let audio = FrustbiteAudio::open_file(&path, None).unwrap();
        std::fs::remove_file(&path).unwrap();
        assert_eq!(audio.tag_data().err(), Some(Code::IoError));
    }
}
