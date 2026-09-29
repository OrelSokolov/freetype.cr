# freetype.cr — ftgrays + ttinterp на Crystal (этапы B1–B2 из PLAN.md)

Порт растеризатора FreeType `ftgrays.c` и интерпретатора TrueType-байткода
`ttinterp.c` (снапшот 2.14.3, `~/freetype`) на Crystal — самодостаточный,
без зависимостей от остального FreeType.
Цель: unhinted- и hinted-шрифты растеризуются **пиксель-в-пиксель** как
системная libfreetype, без самой библиотеки.

**Статус B1: выполнен.** Оракул-диф (PLAN.md §7): 32 000 растеризаций
глифов по 16 unhinted-шрифтам (Roboto всех начертаний, Noto Sans/Serif/
Mono; размеры 12/13/16/24/37) — **диф 0 пикселей**, включая размеры
битмапов и смещения. Синтетический smoke — 5/5.

**Статус B2: выполнен.** Полный конвейер TTF → контур → хинтинг →
растеризация целиком на Crystal. Приёмка: **198 790 hinted-глифов**
(Liberation, DejaVu, Verdana, Times и др.; 12/13/16/24/37 px) —
контур+битмап **диф 0**, плюс 80 997 unhinted-глифов — диф 0.
Зарегистрировано 2 «версионно-чувствительных» глифа (LiberationMono,
12/13 px), где системная libfreetype 2.13.3 расходится с мастером FT —
наш вывод совпадает с мастером (проверено локальной сборкой).

## Состав

- `src/ftgrays.cr` — ядро: `Ftgrays::Raster` + `Ftgrays::Outline`
  (точки 26.6, y вверх). Порт `gray_render_line` (64-битный вариант),
  коник через DDA (`gray_render_conic`), кубик через бисекцию
  (`gray_render_cubic`), клетки покрытия и свип с fill-rule.
  Битовая точность перенесена явно: wrapping-арифметика (`&+ &- &*`),
  арифметические сдвиги, C-деление `tdiv`, точная реплика `FT_UDIV`.
  Пул клеток/биссекция полос заменены динамическими массивами
  (интегрирование площадей от разбиения на полосы не зависит).
- `src/ftrender.cr` — клей `ftsmooth.c`/`ftobjs.c` для
  FT_RENDER_MODE_NORMAL: control-box → пиксельный bbox (floor/ceil как в
  `ft_glyphslot_preset_bitmap`) → трансляция → растеризация.
  Результат — `Ftrender::GlyphBitmap` (top-down 8-bit coverage).

## Состав B2 (хинтинг)

- `src/fttrigon.cr` — порт `fttrigon.c` (тригонометрия на fixed-point:
  `FT_Vector_Rotate`, `FT_Vector_Norm_Len` и т.п. — нужен для проекций
  на произвольные оси в байткоде).
- `src/tt/sfnt.cr` — минимальный парсер SFNT: head, maxp, hhea, hmtx,
  cmap (формат 4), loca, glyf, cvt, fpgm, prep, gasp. Только то, что
  нужно для загрузки контуров и хинтинга.
- `src/tt/loader.cr` — порт hint-glue из `ttgload.c`/`ttobjs.c`:
  масштабирование, `exec.run_fpgm`/`run_prep` (cvt в 26.6, как в C),
  `backward_compatibility`, загрузка простых и композитных глифов,
  grid-fit advance (`ft_glyphslot_grid_fit_metrics`), write-back точек,
  scan-conversion флаг в tags[0].
- `src/tt/ttinterp.cr` (~4 600 строк) — порт VM `ttinterp.c`: стек,
  зоны/точки, CVT, storage, функции, ~190 опкодов; wrapping-арифметика
  (`&+ &- &*`), C-семантика деления и сдвигов. Встроен трассер
  (`TT_TRACE=1` — пооператорный дамп VM, нулевая стоимость при
  выключенном флаге).

Важная деталь: FT отдаёт шрифты без байткода (`fpgm` пуст, `prep` ≤ 7
байт) автохинтеру (ftobjs.c:1016-1020) — поэтому unhinted-корпус
(например, Roboto) в hinted-приёмке не участвует и покрывается отдельной
unhinted-спекой.

## Тесты

  Важная деталь, найденная отладкой: FreeType применяет
  `FT_Outline_Translate` **до** декомпозиции контура, поэтому середины
  коник (`v_start`/`v_middle`, C-деление `/2` с усечением к нулю)
  округляются на сдвинутых координатах — порт применяет сдвиг при чтении
  точек в `decompose`, а не при апскейле.

## Тесты

- `crystal run spec/ftgrays_smoke.cr` — синтетика: квадрат, треугольник,
  круг из коник, кубик, even-odd.
- `crystal run --release spec/ftgrays_diff.cr [-- шрифты...]` —
  приёмочный тест B1: диф против системной libfreetype (FFI-оракул,
  PLAN.md §7). Шрифты авто-классифицируются (unhinted = контуры с
  хинтингом и без совпадают); hinted пропускаются с пометкой (им нужны
  B2/C). `DUMP_DIFFS=n` — ASCII-дамп первых n расхождений.
- `crystal run --release spec/tt_unhinted_diff.cr [-- шрифты...]` —
  полный конвейер B1+B2 без хинтинга, диф контуров/битмапов/advanсов
  против FT_LOAD_NO_HINTING (80 997 глифов, диф 0).
- `crystal run --release spec/tt_hinted_diff.cr [-- шрифты...]` —
  приёмочный тест B2: hinted-глифы, сравнение контуров (точки+теги с
  маской 0xE7 — TOUCH-биты являются внутренностями VM и между версиями
  FT расходятся), битмапов и advanсов против FT_LOAD_DEFAULT
  (198 790 глифов, диф 0).
- `spec/interp_probe.cr` — ручные пробы VM на синтетике;
- `tmp_c/` — standalone-сборка `ftgrays.c` из снапшота (второй оракул
  для бисектов: вход — текстовый дамп контура, выход — coverage).
  NB: собирается с `ftint64_shim.h` (макрос `FT_INT64`), иначе
  компилируется старый до-2.13 путь растеризации.
- `spec/bisect_dbg.cr` — трёхсторонний бисект глифа (наш / C-ftgrays /
  системный FT); `spec/ffi_dbg.cr` — проверка FFI-зеркала структур;
  `spec/circle_dbg.cr` — сверка синтетики с C-оракулом.

## Дальше (по PLAN.md)

1. ~~B1: растеризатор + спека-диф (диф == 0)~~ ✓
2. ~~B2: порт `ttinterp` + sfnt-loader, спека-диф на hinted (диф == 0)~~ ✓
3. Включить в `LightHintedFonts` (egui.cr) вместо FFI/эвристики,
   суперсэмплер и `freetype.cr` — в отставку (FFI остаётся как
   debug-оракул в спеках)
4. libfreetype удаляется из зависимостей egui.cr

