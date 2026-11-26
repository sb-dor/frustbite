# Frustbite, этап 2: редактирование (дизайн)

Дата: 2026-11-26. Основа: §6 «Этапы» в `2026-11-24-frustbite-design.md`.
Автор одобрил объём в чате («давай как ты предлагаешь», затем «да, сделай всё»).

## Зачем

Пакет умеет читать звук. Следующий шаг: частые правки в приложениях без
ffmpeg и без нативного кода в приложении. Типичные задачи:

- вырезать рингтон или превью;
- убрать тишину у голосового сообщения;
- склеить подкаст из частей;
- положить голос на фоновую музыку;
- привести звук к 16 кГц моно для распознавания речи.

Результат редактирования можно сразу сохранить в WAV.

## Цели

- Операции:
  - `trim`, `concat` (+ кроссфейд), `gain`, `normalize` (по пику),
    `fadeIn`/`fadeOut`, `resample`, `toMono`/`toStereo`;
  - `trimSilence`, `detectSilence`, `mix`.
- Ленивый пайплайн. Dart собирает список операций, весь список выполняется
  одним нативным вызовом.
- Результат — новый `Frustbite`. Над ним работает всё API: `info`, `waveform`,
  `decode`, повторное `edit`.
- Запись WAV (16 бит, 24 бита, 32-бит float): `toWav()` → байты, `saveWav(path)`
  на нативных платформах. Работает для любого `Frustbite`, поэтому заодно есть
  конвертер «что угодно → WAV».
- Всё работает и на вебе (wasm); на вебе нет только `saveWav`.
- Async-варианты всех тяжёлых операций, как у `decodeAsync`.
- Бенчмарк ресэмплинга и записи WAV в `packages/benchmark`.

## Не цели (этот этап)

- LUFS (`normalizeLoudness`), реверс, отступы, выбор канала, темп/тон, фильтры,
  шумоподавление, BPM.
- Сжатые форматы записи (FLAC, Opus) и запись тегов: этап 3.
- Потоковая обработка больших файлов: этап 4. Сейчас пайплайн держит PCM
  в памяти.

## Анти-цели

- Тихо портить звук. Ошибка в параметрах — это `InvalidParameterException`,
  а не «как-нибудь».
- Ломать чтение. API этапа 1 не меняется.
- Тянуть C-зависимости или GPL.

## Подходы

1. **Список операций в JSON, один вызов `frustbite_render` (выбран).** Dart
   кодирует операции в JSON и передаёт его вместе с массивом дополнительных
   источников (для `append`/`mix`). Rust декодирует, применяет операции и
   отдаёт новый handle или WAV-байты.
   - Плюсы: один переход через FFI, новые операции не меняют сигнатуры ABI,
     одинаково просто для FFI и wasm. `serde_json` уже в зависимостях.
   - Минус: разбор JSON (микросекунды, на фоне декодирования не виден).
2. **Массив `#[repr(C)]` структур операций.** Строгие типы в заголовке, но
   каждая новая операция или параметр меняет layout. Для wasm layout придётся
   повторить вручную, как сейчас для `FrustbiteAudioInfo`.
3. **Отдельная FFI-функция на операцию над буфером PCM.** Буфер ходит через
   границу на каждом шаге (или нужен ещё один тип handle). Противоречит
   «одним вызовом» из спеки.

## Решения

### API (Dart)

```dart
final edited = audio.edit()
    .trimSilence()                       // thresholdDb: -50
    .trim(start: 2.seconds, end: 30.seconds)
    .fadeIn(500.ms).fadeOut(1.seconds)
    .gain(-3)
    .normalize()                         // peakDb: -1
    .resample(16000)
    .toMono()
    .append(other, crossfade: 2.seconds)
    .mix(music, gainDb: -12, offset: Duration.zero)
    .render();                           // Frustbite; или renderAsync()

Frustbite.concat([a, b, c], crossfade: ...); // AudioEdit
audio.toWav(format: WavFormat.pcm16);        // Uint8List (+ toWavAsync)
audio.saveWav(path, format: ...);            // native (+ saveWavAsync)
edit.toWav() / edit.saveWav(path)            // без промежуточного handle
audio.detectSilence(thresholdDb: -50, minDuration: 500.ms); // List<SilenceRange>
```

- `AudioEdit` неизменяемый: каждый метод возвращает новый builder, исходный
  `Frustbite` не меняется.
- `render()` возвращает новый `Frustbite`, его нужно `dispose()`.

### Семантика операций

Операции выполняются по порядку над текущим PCM. «Текущий формат» означает
частоту и каналы после предыдущих шагов.

- **`trim(start, end)`** — позиции в текущем звуке. `end` по умолчанию до
  конца. Если `start > end`, это ошибка параметра. Если позиция за концом,
  она ограничивается длиной (результат может быть пустым).
- **`gain(db)`** — умножение на `10^(db/20)`. `db` должно быть конечным.
- **`normalize(peakDb = -1)`** — масштаб, при котором пик равен `peakDb`.
  Требуется `peakDb <= 0`. Тишина остаётся без изменений.
- **`fadeIn(d)` / `fadeOut(d)`** — линейная огибающая. Если `d` длиннее
  звука, огибающая идёт по всей длине.
- **`resample(rate)`** — rubato `Fft` (синхронный, высокое качество).
  `rate` в 1..=768000. Если частота та же, ничего не происходит.
- **`toMono`** — среднее всех каналов.
- **`toStereo`** — из моно дублирование, из стерео ничего, из >2 каналов
  первые два.
- **`trimSilence(thresholdDb = -50)`** — убирает кадры в начале и конце, где
  max |sample| по всем каналам ниже порога. Полностью тихий звук становится
  пустым. Порог `<= 0`.
- **`append(other, crossfade = 0)`** — `other` приводится к текущему формату:
  - частота через `resample`;
  - каналы: в моно через среднее, из моно дублированием, иначе канал `i`
    берётся из `i % N`.

  Кроссфейд равной мощности (sin/cos) по `min(crossfade, len_a, len_b)`.
- **`mix(other, gainDb = 0, offset = 0)`** — `other` приводится к текущему
  формату, умножается на gain и прибавляется с позиции `offset`. Длина
  результата `max(len, offset + len_other)`. Ограничителя нет: значения могут
  выйти за ±1. Сохранение в 16/24 бит их обрезает, float32 хранит как есть.
  Документация советует ставить `normalize()` после `mix`.
- **`Frustbite.concat(list, crossfade)`** — первый элемент + `append` остальных.
  Пустой список — ошибка аргумента.

### detectSilence

Отрезки `[start, end)`, где каждый кадр ниже порога и длина не меньше
`minDuration` (по умолчанию 500 мс). Значения возвращаются в микросекундах.

Работает потоково по `PacketDecoder` и не держит весь PCM в памяти. Порог
`<= 0`, `minDuration` в мс как `u32`: u64-параметры неудобны в wasm (BigInt).

### WAV

- `FrustbiteWavFormat`: `Pcm16 = 0`, `Pcm24 = 1`, `Float32 = 2`.
- Целые форматы: `round(x * 2^(n-1))` с ограничением `[-2^(n-1), 2^(n-1)-1]`.
  Чтение делит на `2^(n-1)`, поэтому круг «16-бит WAV → decode → pcm16» точен
  без потерь.
- Float32 пишется с `WAVE_FORMAT_IEEE_FLOAT`: fmt из 18 байт (cbSize = 0)
  и чанк `fact`.
- Больше 4 ГиБ данных не помещается в RIFF; это `InvalidParameter`.
- Результат `render()` внутри хранится как float32 WAV в памяти и открывается
  обычным `open_memory`. Так новый handle не требует нового типа источника,
  а промежуточные данные не теряют точность.

### ABI

ABI версии 2: новые функции нужны Dart-пакету, поэтому старый бинарник с новым
Dart должен отклоняться.

```c
FrustbiteErrorCode frustbite_render(const FrustbiteAudio *audio,
    const FrustbiteAudio *const *sources, size_t sources_len,
    const uint8_t *ops, size_t ops_len, FrustbiteAudio **out);
FrustbiteErrorCode frustbite_render_wav(... те же ..., uint32_t format,
    uint8_t **out, size_t *out_len);           // free: frustbite_free_bytes
FrustbiteErrorCode frustbite_detect_silence(const FrustbiteAudio *audio,
    float threshold_db, uint32_t min_duration_ms,
    uint64_t **out, size_t *out_len);          // пары start/end в мкс
void frustbite_free_u64(uint64_t *ptr, size_t len);
```

- `ops` — UTF-8 JSON-массив, теги `op` в snake_case. Неизвестные поля и
  операции дают `InvalidParameter`.
- `sources` и `ops` могут быть null только при длине 0.
- `source` в `append`/`mix` — индекс в `sources`.

### Зависимость

`rubato 5.1` (MIT OR Apache-2.0) тянет audioadapter*, realfft/rustfft, num-*,
primal-check, strength_reduce, transpose, windowfunctions,
audio-codec-algorithms (0BSD OR Apache-2.0) и proc-macro visibility. Все чистый
Rust, собираются под wasm32, лицензии из разрешённого списка.
`THIRD_PARTY_LICENSES.md` перегенерируется.

### Ограничения

- Весь звук в памяти: источник + доп. источники + результат. Для часа стерео
  44,1 кГц это ~1,3 ГБ f32 на каждый. Это задокументировано; потоковая
  обработка придёт на этапе 4.
- Async: на нативе `Isolate.run` с адресами всех handle. Счётчик `_busy`
  ставится на все участвующие `Frustbite`, чтобы ни один не освободили
  посреди вызова.
- Web: все источники должны принадлежать одному экземпляру wasm, иначе
  `StateError`.

## Оставлено билдеру

- Точные имена внутренних модулей Rust (`edit.rs`, `wav.rs`, `silence.rs`,
  `resample.rs`).
- Набор тестов: по тесту на каждую операцию, FFI-тесты на ошибки и out-параметры,
  Dart-тесты (native + wasm).
- Документация: страница «Editing» на сайте, README, CHANGELOG (Unreleased),
  ROADMAP, DECISIONS. Версия пакета не повышается, релиз выпускает автор.
