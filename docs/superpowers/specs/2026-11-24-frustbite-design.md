# frustbite — дизайн

_Дата: 2026-11-24. Статус: на одобрении автора (проверка билдером пройдена, ответы внесены)._

## 1. Что это и зачем

**frustbite** — быстрая кроссплатформенная библиотека обработки аудио для Dart,
ядро на Rust через FFI. Работает во Flutter, на сервере и в CLI, на Android, iOS,
macOS, Linux, Windows, а через WebAssembly — в браузере.

Образец — [pixer](https://github.com/hawkkiller/pixer) (Michael Lazebny, MIT):
«самая быстрая библиотека картинок для Dart». frustbite повторяет его архитектуру,
структуру репозитория, подход к бинарникам, бенчмаркам, документации и релизам —
но для звука. Код пишется свой; pixer — образец устройства, не источник копипасты.

**Почему:** в Dart нет одной быстрой библиотеки, которая на всех платформах
(включая десктоп, сервер и веб) умеет читать любой популярный аудиоформат,
строить волну, читать теги, редактировать и конвертировать звук. Существующие
пакеты либо на чистом Dart (медленно), либо через нативные API только Android/iOS,
либо тянут FFmpeg (тяжело, лицензии), либо покрывают один формат или одну задачу.

**Успех:** опубликованный на pub.dev пакет `frustbite`, который ставится одной
строкой в pubspec без установки Rust, работает на всех целевых платформах и вебе,
и на бенчмарках заметно быстрее существующих Dart-пакетов — с таблицей и графиком,
как у pixer.

## 2. Цели, не-цели, анти-цели

**Цели** (все, этапами — см. §6):
- информация о файле, декодирование в PCM, волна, теги и обложка;
- редактирование: обрезка, склейка, громкость/нормализация, fade, ресэмплинг, моно/стерео;
- запись в wav, flac, opus; запись тегов;
- потоковая обработка больших файлов, CLI;
- бенчмарки против существующих пакетов, showcase-приложение, сайт документации;
- публикация на pub.dev.

**Не-цели:**
- воспроизведение (это `just_audio` и т.п.);
- запись с микрофона (это `record`);
- эффекты в реальном времени во время проигрывания, микшер, DAW;
- видео;
- **запись** mp3 и aac (лицензии/патенты: LAME — LGPL, свободного AAC-энкодера нет).
  Чтение этих форматов — да.

**Анти-цели** (провал, даже если «работает»):
- пользователю нужно ставить Rust или FFmpeg, чтобы просто использовать пакет;
- не работает в вебе или на десктопе — тогда это ещё один «только мобильный» пакет;
- бенчмарки нечестные (разные настройки, тёплый кэш против холодного) или без
  воспроизводимой методики;
- волна или декодирование часового файла съедает сотни мегабайт памяти;
- C-зависимости с копилефт-лицензией (GPL/LGPL) в бинарниках по умолчанию.

## 3. Ограничения

- Чистый Dart-пакет, не Flutter-плагин; никаких platform channels / pigeon.
- Rust-ядро обязано собираться в `wasm32-unknown-unknown` целиком. Отсюда
  предпочтение crates на чистом Rust; C-код допустим только если он собирается
  в wasm, иначе функция помечается «не в вебе».
- Лицензия проекта — MIT; все зависимости совместимы (MIT/Apache/BSD/Zlib/MPL-2.0).
- Целевые платформы — те же 12, что у pixer: android arm/arm64/x64,
  ios arm64 + simulator arm64/x64, linux arm64/x64, macos arm64/x64,
  windows arm64/x64; плюс `frustbite.wasm`.
- Готовые бинарники — в GitHub Releases публичного репозитория
  **github.com/sb-dor/frustbite** (решение автора); релизы бинарников выпускаются
  уже с этапа 1, каждый push и тег — с подтверждения автора. Хеши зашиты в пакет.
  Этот URL используется в hook, `repository` в pubspec и адресе docs (GitHub Pages).
- **Только чистый Rust** (решение автора): никаких C-декодеров ради скорости.
  Если на каких-то строках бенчмарка frustbite медленнее `audio_decode`, это честно
  показывается в таблице; ставка — на охват (все форматы, все платформы и веб,
  волна, теги, редактирование, запись в одном пакете) и на память. Критерий успеха
  «заметно быстрее» относится к пакетам на чистом Dart и к сквозным сценариям,
  а не к каждой строке против C.
- На машине автора сейчас нет Rust (`rustup` ставится как первый шаг).
- Имя `frustbite` на pub.dev свободно (проверено 2026-11-24).

## 4. Подходы

| Подход | Плюсы | Минусы |
|---|---|---|
| **A. Как pixer: C-ABI из Rust (cbindgen) + ffigen + build hooks (`hooks`, `code_assets`, `native_toolchain_rust`) + отдельный wasm-бэкенд** | проверен pixer'ом на pub.dev; чистый Dart; минимальный рантайм; веб работает; полный контроль ABI | больше ручного FFI-кода |
| B. flutter_rust_bridge | генерация биндингов, удобные async/stream | тяжелее рантайм, ориентирован на Flutter, веб требует потоков и COOP/COEP-заголовков |
| C. Flutter-плагин с нативкой под каждую ОС | системные кодеки | Flutter-only, разное поведение по платформам, нет сервера/CLI — противоречит «почему» |

**Выбран A** — по решению автора («чтобы всё было почти как у pixer») и потому что
B и C противоречат цели «везде, включая веб и сервер».

## 5. Как устроено (решено)

### 5.1 Репозиторий (pub workspace, как у pixer)

```
frustbite/
├─ native/                       Rust crate `frustbite`
│  ├─ Cargo.toml                 crate-type = ["staticlib","cdylib"]; features по форматам
│  ├─ rust-toolchain.toml        закреплённый toolchain + targets (вкл. wasm32)
│  ├─ cbindgen.toml, .cargo/config.toml
│  ├─ RESEARCH.md                выбор crates и замеры (как у pixer)
│  └─ src/  lib.rs, ffi.rs, …    C-ABI, коды ошибок, модули decode/waveform/tags/edit/encode
├─ packages/
│  ├─ frustbite/                 публикуемый Dart-пакет
│  │  ├─ hook/build.dart         скачать бинарник + проверить хеш, либо собрать из исходников
│  │  ├─ lib/frustbite.dart      публичный API
│  │  ├─ lib/src/bindings/       сгенерировано ffigen (не править руками)
│  │  ├─ lib/src/hook/           targets, version, hashes, download, local_build, android config
│  │  ├─ lib/src/web/            wasm-бэкенд
│  │  ├─ lib/src/abi.dart        проверка версии ABI
│  │  ├─ native/include/frustbite.h  сгенерировано cbindgen
│  │  ├─ bin/frustbite.dart      CLI
│  │  ├─ tool/                   build, build_wasm, generate_bindings, generate_asset_hashes
│  │  ├─ example/, test/
│  │  └─ README.md, CHANGELOG.md, LICENSE, .pubignore
│  ├─ benchmark/                 бенчмарки, results.json, chart.html → chart.png, README с таблицей
│  └─ showcase/                  Flutter-приложение: открыть файл → инфо, волна, теги, операции
├─ docs/                         сайт документации на Blume (как у pixer), деплой на GitHub Pages
├─ scripts/build.sh
├─ .github/workflows/
│  ├─ build_release.yaml         preflight, rust (fmt/clippy/test), wasm (+ тесты в Chrome
│  │                             dart2js и dart2wasm), матрица 12 целей, релиз по тегу
│  │                             `frustbite-assets-vX.Y.Z`
│  └─ docs.yaml
├─ AGENTS.md, README.md, LICENSE (MIT), pubspec.yaml (workspace)
```

### 5.2 Нативное ядро (Rust)

- Decode/контейнеры: `symphonia` (mp3, aac/m4a, alac, flac, vorbis/ogg, wav,
  контейнер mkv/webm). _Моё решение по покрытию:_ AAC — только AAC-LC; HE-AAC/HE-AACv2
  не поддерживаются (нет свободного decoder'а под наши ограничения) — это явно
  написано в README и бросает `UnsupportedFormatException`. Opus — в Ogg **и** в
  WebM/Matroska (браузерная запись). Файлы от пакета `record` (m4a AAC-LC, opus)
  входят в тестовый набор этапа 1.
- Opus: crate на чистом Rust (`opus-decoder` или `ropus` — выбрать в RESEARCH.md
  по корректности на тестовых векторах, скорости и наличию энкодера).
- Теги и обложки: `lofty` (чтение; запись — этап 3).
- Ресэмплинг: `rubato`.
- Запись: `hound` (wav), `flacenc` (flac), opus — энкодер из выбранного crate
  или libopus, если он собирается в wasm; иначе opus-запись помечается «не в вебе».
- Cargo features по форматам (`mp3`, `aac`, `alac`, `flac`, `vorbis`, `opus`, `wav`),
  по умолчанию все. Как у pixer: пользователь может сузить набор через
  `hooks.user_defines.frustbite.formats` — тогда пакет собирается из исходников.
- C-ABI: `#[repr(u32)]` коды ошибок, выходные значения только через out-параметры
  при `Success`, явные функции освобождения памяти, версия ABI, проверяемая Dart'ом
  до первого вызова. Паника не пересекает FFI-границу (`panic = "abort"` в release
  как у pixer + `catch_unwind` там, где нужно вернуть код ошибки).
- Release-профиль: `opt-level=3`, `lto="fat"`, `codegen-units=1`, `strip`.

### 5.3 Публичный Dart-API (форма)

Модель как у pixer: объект-источник + ленивый неизменяемый пайплайн, вся цепочка
исполняется одним нативным вызовом, промежуточные данные остаются в Rust.

```dart
final audio = Frustbite.fromFile('song.mp3');      // или fromMemory(bytes, format: …)

audio.info;      // AudioInfo: codec, container, duration, sampleRate, channels, bitrate
audio.tags;      // AudioTags: title, artist, album, year, track, genre, … , cover (bytes + mime)

final peaks = audio.waveform(buckets: 200);         // Float32List 0..1 (опции: per-channel, rms/peak)
final pcm   = audio.decode();                       // AudioPcm: Float32List interleaved, sampleRate, channels

final bytes = audio
    .trim(start: Duration(seconds: 5), end: Duration(seconds: 35))
    .fadeIn(Duration(milliseconds: 300))
    .normalize()
    .resample(16000)
    .toMono()
    .encode(const FrustbiteOpusEncoder(bitrate: 32000));

audio.trim(...).saveToFile('clip.flac', const FrustbiteFlacEncoder());
Frustbite.concat([a, b]).encode(const FrustbiteWavEncoder());

audio.dispose();
```

- У каждого тяжёлого терминала (`decode`, `waveform`, `encode`, `saveToFile`) есть
  асинхронный вариант, который не блокирует UI-поток Flutter. Механизм — на выбор
  билдера (см. §7), но он обязан быть в API с этапа 1.
- Ошибки — типизированные исключения (`FrustbiteException` и наследники,
  `UnsupportedFormatException` и т.д.), как у pixer.
- Веб: только байтовый API (`fromMemory`, `encode`); `fromFile`/`saveToFile`
  бросают `UnsupportedError`. `Frustbite.initialize()` загружает `frustbite.wasm`
  (или `wasmUri` / `wasmBytes`). _Моё решение:_ как у pixer — пользователь кладёт
  `frustbite.wasm` из GitHub Release соответствующей версии в web root (один ручной
  шаг, описан в README и docs); ABI кэшированного wasm проверяется при `initialize`.
  Поэтому критерий успеха для веба — «один файл в web root», а не «ноль шагов».
- `normalize()` — пиковая нормализация (до −1 dBFS по умолчанию, параметр `peakDb`).
  _Моё решение;_ громкостная (EBU R128 / LUFS) — отдельный `normalizeLoudness()`
  позже, не в этапах 1–5.
- Освобождение: явный `dispose()` + `NativeFinalizer` как страховка.

### 5.4 Память

- Источник хранит закодированные байты/файл, а не весь PCM.
- `waveform`, `info`, `tags` и пайплайны, заканчивающиеся записью в файл, работают
  потоково (пакет за пакетом): память не растёт с длиной файла.
- `decode()` в Dart по определению отдаёт весь PCM — в документации предупреждение
  и потоковый вариант (этап 4).

### 5.5 Бенчмарки (`packages/benchmark`, как у pixer)

- `dart run bin/main.dart` печатает и пишет `benchmark_results.json`; `chart.html`
  рендерится в `chart.png`; README содержит таблицу «Операция | frustbite | пакет |
  ускорение», дату, железо, версию Dart и методику.
- Соперники (живые на 2026-11):
  - `audio_decode` — декодирование mp3/ogg/wav (C через FFI);
  - `glint_audio_pure` — mp3 на чистом Dart;
  - `wav` — чтение/запись wav на чистом Dart;
  - `audio_metadata_reader` — теги на чистом Dart.
- Сценарии (минимум): info/probe; decode mp3, ogg vorbis, flac, wav; waveform
  1000 точек из 3-мин mp3; чтение тегов + обложки; ресэмплинг 44.1→16 кГц;
  запись wav и flac. Где соперника нет — абсолютные цифры frustbite.
- Честность: одинаковые входы и настройки, прогрев, медиана N прогонов,
  отдельно «из памяти» и «из файла».
- Тестовые аудиофайлы — только с лицензией, разрешающей распространение
  (CC0/сгенерированные), с указанием источника.

### 5.6 Тесты

- Rust: `cargo test` + `clippy -D warnings` + `fmt --check`, сборка с урезанным
  набором features.
- Dart: юнит-тесты API, файловые тесты, CLI-тесты, wasm-тесты в Chrome
  (dart2js и dart2wasm) — как у pixer.
- Корректность декодеров: сравнение с эталонным PCM / тестовыми векторами
  с допуском; opus — официальные тестовые векторы.

### 5.7 Релиз

- Версия пакета и тег бинарников совпадают (`frustbite-assets-vX.Y.Z`),
  preflight проверяет pubspec, `version.dart`, CHANGELOG и что тег на `main`.
- После релиза бинарников — `generate_asset_hashes` → хеши в пакет →
  `dart pub publish --dry-run` → публикация.
- **Публикацию на pub.dev делает/подтверждает автор лично** — необратимо.

## 6. Этапы и критерии приёмки

Каждый этап заканчивается рабочим состоянием (тесты зелёные на всех целях CI).

1. **Каркас + чтение.** Репозиторий по §5.1, сборка из исходников и скачивание
   бинарников, wasm. API: `fromFile`/`fromMemory`, `info`, `tags`, `waveform`,
   `decode` (+ async). Все форматы чтения, включая opus. Бенчмарки этих операций,
   showcase с волной и тегами, docs «Getting started».
   _Приёмка:_ `dart test` и wasm-тесты проходят; showcase на macOS и Android/iOS
   показывает волну и теги для mp3/m4a/flac/ogg/opus/wav; волна 1-часового файла
   не превышает ~50 МБ RSS сверх базового.
2. **Редактирование.** `trim`, `concat`, `gain`, `normalize`, `fadeIn/Out`,
   `resample`, `toMono/toStereo`; ленивый пайплайн одним вызовом. Бенчмарк ресэмплинга.
3. **Запись.** Энкодеры wav, flac, opus; `encode`/`saveToFile`; запись тегов.
   _Моё решение:_ теги переписываются через `lofty` без перекодирования звука,
   и по умолчанию результат пишется в **новый** файл (`writeTags(tags, to: path)`);
   изменение исходного файла — только явным `inPlace: true` с записью во временный
   файл и атомарной заменой, чтобы сбой не портил данные пользователя.
4. **Большие файлы и CLI.** Потоковое декодирование (`Stream` чанков PCM),
   CLI `frustbite info|waveform|convert|trim …`, docs по всем разделам.
5. **Публикация.** Первый релиз бинарников, хеши, `pub publish --dry-run`, публикация
   (с подтверждением автора). Пакет можно опубликовать и раньше — после этапа 1 —
   если автор захочет.

## 7. Оставлено билдеру

- Выбор opus-crate и способ opus-записи (по RESEARCH.md).
- Механизм async-терминалов: `Isolate.run` вокруг синхронного вызова против
  нативного потока + `NativeCallable.listener`; в вебе — синхронно или через
  Web Worker. Критерий: UI не блокируется, отмена/ошибки корректны.
- Точный формат волны по умолчанию (peak vs RMS, min/max пары).
- Минимальные версии Dart SDK, iOS, Android (ориентир — как у pixer).
- Внутреннее устройство модулей Rust и Dart.
- Оформление docs-сайта и showcase.

## 8. Решения, принятые мной (Claude), а не автором

Автор может поправить любое:
- 12 целевых платформ и wasm — как у pixer.
- Набор форматов и crates в §5.2; mp3/aac — только чтение.
- Форма API (источник + ленивый пайплайн, как у pixer).
- Список соперников и сценариев бенчмарков.
- Ограничение лицензий зависимостей (без GPL/LGPL).
- Порядок этапов.
