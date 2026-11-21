# Head-related impulse response sets shipped by component `surround`

The four files in `hrir/` are 14-channel, 48 kHz impulse response sets in the
HeSuVi channel layout. They are derived from published measurements and stay
under the licences of those measurements, not under the GPL-2.0-only licence
of the rest of ally-x20-steamos.

| File | SHA-256 | Source | Licence |
|---|---|---|---|
| `sadie-d2-dry.wav` | `abbfc8cb54b5294bfabda3d6ea5d2aaa695d2b0035c6e54c1e08f7a730e836e3` | SADIE II database, subject D2 (KEMAR mannequin) | Apache-2.0 (`LICENSE.Apache-2.0`) |
| `hutubs-pp1-dry.wav` | `c564d819b4725b4c4c536d690d008d783932fe704d7b532663f9963c0c45ead1` | HUTUBS database, subject pp1, measured | CC BY 4.0, https://creativecommons.org/licenses/by/4.0/ |
| `mit-kemar-dry.wav` | `0fd292d7061f5861342223034ce56b0897aba2ee2589d9651c884607ffdf59f7` | MIT KEMAR, normal pinna | no usage restrictions; citation requested |
| `mit-kemar-large-dry.wav` | `b7d6d1694061f3389029298b8574558681a6a7152f7ffaaabd5004016c889768` | MIT KEMAR, large pinna | no usage restrictions; citation requested |

## Attribution

- **SADIE II**, subject D2 (KEMAR mannequin). Copyright 2018 University of
  York, AudioLab, Department of Electronic Engineering. C. Armstrong,
  L. Thresh, D. Murphy, G. Kearney, "A Perceptual Evaluation of Individual
  and Non-Individual HRTFs: A Case Study of the SADIE II Database", Applied
  Sciences 8(11), 2018. Licensed under the Apache License 2.0. Source file:
  `https://sofacoustics.org/data/database/sadie/D2_48K_24bit_256tap_FIR_SOFA.sofa`
  (SHA-256 `bb5980288fc5c990c821e02c5ddfa274759079b723973cd6ca47ac577243aa0c`).
- **HUTUBS** head-related transfer function database, subject pp1
  (measured), which is the FABIAN head and torso simulator. Audio Communication Group, TU Berlin; HUAWEI Munich Research
  Center; Sennheiser. F. Brinkmann et al., "A cross-evaluated database of
  measured and simulated HRTFs including 3D head meshes, anthropometric
  features, and headphone impulse responses", J. Audio Eng. Soc. 67(9),
  2019. Licensed CC BY 4.0. Source file:
  `https://sofacoustics.org/data/database/hutubs/pp1_HRIRs_measured.sofa`
  (SHA-256 `f626d335c590db687608fff5992972725230d594067b2e6906893bddc85e5173`).
- **MIT Media Lab KEMAR** HRTF measurements, normal and large pinna.
  B. Gardner and K. Martin, "HRTF Measurements of a KEMAR", J. Acoust. Soc.
  Am. 97(6), 1995. "Provided without any usage restrictions; please cite
  Gardner and Martin (1995)." SOFA conversion by ARI (sofacoustics.org).
  Source files:
  `https://sofacoustics.org/data/database/mit/mit_kemar_normal_pinna.sofa`
  (SHA-256 `e7035994f5fd754058424c061380ee92b1d5ed58fccef2887a4266916616acdf`)
  and `https://sofacoustics.org/data/database/mit/mit_kemar_large_pinna.sofa`
  (SHA-256 `93a6f4e1a21fb2f16162fbe49508c35e5ddbcc60acfe7e3c4aa2847364d066d7`).

## Changes made to the measurements

The files are not the original data. For each set:

1. The measured responses nearest to the seven 7.1 loudspeaker directions at
   ear level were taken as they are, without interpolation: front left and
   right at 30 degrees, centre at 0, sides at 90, rears at 150. The MIT sets
   were resampled to 48 kHz.
2. They were written in the HeSuVi channel order, with one common gain.
3. The front left, front right and centre responses were replaced by plain
   delayed impulses ("dry fronts"): front left to the left ear only, front
   right to the right ear only, the centre to both. The impulses sit where
   the original front responses began and are as loud as those were. The
   side and rear responses are unchanged.

They were produced with `tools/surround-test` of this project (pull request
#70: `fetch-sofa.sh`, `render_sofa.py`, `hrir_tool.py dry`), which pins the
source files by the SHA-256 values above.
