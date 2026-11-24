//! Codec registry: Symphonia's enabled decoders plus our Opus decoder.

use std::sync::LazyLock;

use symphonia::core::codecs::registry::CodecRegistry;

static REGISTRY: LazyLock<CodecRegistry> = LazyLock::new(|| {
    let mut registry = CodecRegistry::new();
    symphonia::default::register_enabled_codecs(&mut registry);
    #[cfg(feature = "opus")]
    registry.register_audio_decoder::<crate::opus::OpusDecoder>();
    registry
});

/// The registry used for every decoder this crate creates.
pub fn registry() -> &'static CodecRegistry {
    &REGISTRY
}

/// Reads the first `count` bits at `pos`, MSB first.
fn read_bits(data: &[u8], pos: &mut usize, count: usize) -> Option<u32> {
    let mut value = 0u32;
    for _ in 0..count {
        let byte = *data.get(*pos / 8)?;
        value = (value << 1) | u32::from((byte >> (7 - *pos % 8)) & 1);
        *pos += 1;
    }
    Some(value)
}

/// Whether an AAC AudioSpecificConfig announces SBR (HE-AAC), which the AAC-LC decoder cannot
/// decode. Only explicit signalling is detectable here; implicit signalling shows up in the
/// stream itself.
pub fn aac_uses_sbr(config: &[u8]) -> bool {
    fn inspect(config: &[u8]) -> Option<bool> {
        let mut pos = 0;
        let object_type = read_bits(config, &mut pos, 5)?;
        if object_type == 5 || object_type == 29 {
            return Some(true); // explicit hierarchical SBR / PS
        }
        if object_type != 2 {
            return Some(false); // the decoder rejects anything but LC by itself
        }
        if read_bits(config, &mut pos, 4)? == 0xF {
            pos += 24;
        }
        let channel_config = read_bits(config, &mut pos, 4)?;
        if channel_config == 0 {
            return Some(false); // a program config element follows: not parsed
        }
        // GASpecificConfig: frameLengthFlag, dependsOnCoreCoder, extensionFlag.
        read_bits(config, &mut pos, 1)?;
        if read_bits(config, &mut pos, 1)? == 1 {
            pos += 14;
        }
        read_bits(config, &mut pos, 1)?;
        // Backward-compatible extension: sync word, object type 5, then the SBR flag.
        if read_bits(config, &mut pos, 11)? == 0x2B7 && read_bits(config, &mut pos, 5)? == 5 {
            return Some(read_bits(config, &mut pos, 1)? == 1);
        }
        Some(false)
    }
    inspect(config).unwrap_or(false)
}

/// Bit depth from an ALAC magic cookie (the 24-byte `ALACSpecificConfig`, possibly preceded by
/// the `alac` atom header).
pub fn alac_bit_depth(cookie: &[u8]) -> Option<u32> {
    let start = cookie.len().checked_sub(24)?;
    cookie.get(start + 5).map(|&depth| u32::from(depth))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_explicit_sbr() {
        assert!(aac_uses_sbr(&[19, 144, 86, 229, 160]));
    }

    #[test]
    fn plain_lc_has_no_sbr() {
        assert!(!aac_uses_sbr(&[18, 16, 86, 229, 0]));
        assert!(!aac_uses_sbr(&[18, 16]));
        assert!(!aac_uses_sbr(&[]));
    }

    #[test]
    fn reads_alac_bit_depth() {
        let mut cookie = vec![0u8; 24];
        cookie[5] = 16;
        assert_eq!(alac_bit_depth(&cookie), Some(16));
        assert_eq!(alac_bit_depth(&cookie[..10]), None);
    }
}
