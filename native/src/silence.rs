//! Silence detection: runs of quiet frames, found while decoding, without keeping the PCM.

use crate::decode::PacketDecoder;
use crate::error::FrustbiteErrorCode as Code;
use crate::probe::FrustbiteAudio;

/// A run of silent frames, `[start, end)`, in frames of the decoded output.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SilentRun {
    pub start: u64,
    pub end: u64,
}

/// Collects runs of frames whose every channel is below a threshold.
struct RunFinder {
    threshold: f32,
    min_frames: u64,
    position: u64,
    run_start: Option<u64>,
    runs: Vec<SilentRun>,
}

impl RunFinder {
    fn push(&mut self, frame: &[f32]) {
        let silent = frame.iter().all(|x| x.abs() < self.threshold);
        if silent {
            self.run_start.get_or_insert(self.position);
        } else {
            self.close();
        }
        self.position += 1;
    }

    fn close(&mut self) {
        if let Some(start) = self.run_start.take()
            && self.position - start >= self.min_frames
        {
            self.runs.push(SilentRun {
                start,
                end: self.position,
            });
        }
    }
}

impl FrustbiteAudio {
    /// Finds runs of at least `min_duration_ms` in which every channel stays below
    /// `threshold_db` dBFS (`<= 0`). Returns the runs and the decoded sample rate.
    pub fn detect_silence(
        &self,
        threshold_db: f32,
        min_duration_ms: u32,
    ) -> Result<(Vec<SilentRun>, u32), Code> {
        if !threshold_db.is_finite() || threshold_db > 0.0 {
            return Err(Code::InvalidParameter);
        }
        let mut decoder = PacketDecoder::open(self)?;
        let rate = decoder.sample_rate();
        let channels = decoder.channels().max(1);
        let mut finder = RunFinder {
            threshold: 10f32.powf(threshold_db / 20.0),
            min_frames: (u64::from(min_duration_ms) * u64::from(rate))
                .div_ceil(1000)
                .max(1),
            position: 0,
            run_start: None,
            runs: Vec::new(),
        };
        while let Some(chunk) = decoder.next_chunk()? {
            for frame in chunk.chunks_exact(channels) {
                finder.push(frame);
            }
        }
        finder.close();
        Ok((finder.runs, rate))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn finder(threshold: f32, min_frames: u64) -> RunFinder {
        RunFinder {
            threshold,
            min_frames,
            position: 0,
            run_start: None,
            runs: Vec::new(),
        }
    }

    #[test]
    fn finds_runs_of_minimum_length_including_the_tail() {
        let mut f = finder(0.1, 2);
        for x in [0.0, 0.0, 0.5, 0.0, 0.5, 0.05, -0.05, 0.0] {
            f.push(&[x]);
        }
        f.close();
        assert_eq!(
            f.runs,
            vec![
                SilentRun { start: 0, end: 2 },
                SilentRun { start: 5, end: 8 }
            ]
        );
    }

    #[test]
    fn a_loud_channel_breaks_the_run() {
        let mut f = finder(0.1, 1);
        for frame in [[0.0, 0.0], [0.0, 0.9], [0.0, 0.0]] {
            f.push(&frame);
        }
        f.close();
        assert_eq!(
            f.runs,
            vec![
                SilentRun { start: 0, end: 1 },
                SilentRun { start: 2, end: 3 }
            ]
        );
    }

    #[cfg(feature = "flac")]
    #[test]
    fn silent_file_is_one_run_and_tone_has_none() {
        const FIXTURES: &str = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../packages/frustbite/test/fixtures/"
        );
        let silence = FrustbiteAudio::open_file(format!("{FIXTURES}silence.flac"), None).unwrap();
        let frames = silence.info().unwrap().total_frames;
        let (runs, _) = silence.detect_silence(-50.0, 100).unwrap();
        assert_eq!(
            runs,
            vec![SilentRun {
                start: 0,
                end: frames
            }]
        );
        let tone = FrustbiteAudio::open_file(format!("{FIXTURES}tone.flac"), None).unwrap();
        assert!(tone.detect_silence(-50.0, 100).unwrap().0.is_empty());
        assert_eq!(tone.detect_silence(0.5, 100), Err(Code::InvalidParameter));
        assert_eq!(
            tone.detect_silence(f32::NAN, 100),
            Err(Code::InvalidParameter)
        );
    }
}
