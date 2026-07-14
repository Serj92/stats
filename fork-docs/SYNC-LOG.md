# Лог синхронизаций с upstream

Хронология подтягиваний `exelban/stats` в форк. Свежие — сверху. Назначение: чтобы при следующем синке не наступать на те же грабли.

---

## 2026-07-15 — фикс краша Net + v3.0.7 → v3.0.8

Началось с диагностики периодических крашей (два .ips за 12–13.07, оба на билде 820) → фикс гонки в Net, затем синк v3.0.8.

### Часть 1 — фикс краша `ProcessReader.read()` (коммит `8ab339c7`)

Оба краша — в `Modules/Net/readers.swift:833-838` (`EXC_BAD_ACCESS` в `list.firstIndex`, и `arithmetic overflow` на `p.upload - pp.upload`). Причина — **гонка данных на `self.previous`**: `read()` итерирует и переприсваивает его без синхронизации, а вызывается из двух потоков одновременно (диспатч в `Reader.start()` vs тик `Repeater`, плюс колбэк настроек зовёт `read()` напрямую с фоновой очереди).
- `Kit/module/reader.swift` — новый приватный `readIfIdle()` (NSLock + флаг `reading`); все плановые вызовы (`start()`, оба репитера) идут через него → второй вызов, пока первый в полёте, отбрасывается.
- `Modules/Net/readers.swift` — `ProcessReader` получил свой guard (он зовётся и вне планировщика) + `previous` читается снапшотом и публикуется под локом.
Проверено: попап Net жив, `nettop` в один инстанс (fast-poll 50мс/20с — max 1).

### Часть 2 — v3.0.7 → v3.0.8 (взяли 10 из 11)

`8dcfd55e..upstream/master` = 11 коммитов (10 содержательных + бамп `08121bfd`). Метод — cherry-pick `-x` в хронологии. ⚠️ После пиков `HEAD..upstream/master` показывает **всю** историю (хеши разошлись) — ориентироваться на исходный список от `8dcfd55e`, не на `..upstream/master`.

**Взято:** `68b7e5fe` (#3414 m5 super cores), `0dd8835a` (#3362 spacer), `0830f5df` (#3395 status bar constraint), `efc4ae3d` (#3396 disk details changed), `50ca9459` (tests), `f88af61c` (#3385 unit multiplier), `425a15bc` (async improvements + deregister), `be597ceb` (#3432 zero SSD), `c3fb1fee` (lang), `8ab8e1ef` (#3437 spike mechanism). **Пропущено:** `08121bfd` (бамп 3.0.8).

**Конфликты (все с нашим перф-кодом):**
- **`reader.swift`** (`425a15bc`) — апстрим переписал жизненный цикл ридера (`alignWorkItem` → `alignGeneration` + `alignQueue.sync` во всех методах). Взял их структуру, **наш `readIfIdle()` guard сохранён** и подставлен вместо их `self.read()` во всех точках (оба репитера + aligned async). Наш гард и их async-фиксы совместимы и дополняют друг друга.
- **`DB.swift`** (`425a15bc`) — оставили наши shared `encoder/decoder` + аксессоры `setValue/value(for:)`; **взяли их атомарный compare-and-set** троттла записи (закрывает гонку между проверкой и установкой `writeTS`, которую наши два раздельных `queue.sync` оставляли открытой). Удалили ставшие мёртвыми `writeTS(for:)`/`setWriteTS`.
- **`Clock/main.swift`** (`425a15bc`) — и мы, и апстрим кэшируем `DateFormatter`. **Взял апстримовый** (`formattersQueue.sync`, ключ по `timeZone.identifier`) — каноничнее, меньше дрейфа; выкинул наш `NSLock`-вариант.
- **`Sensors/readers.swift`** (`425a15bc`) — апстрим перевёл `read()` на **локальный снапшот `var sensors` + атомарный `self.list.update {}`** (потокобезопасность — тот же класс фикса). **Уступили наш `sensorIndex` (O(1) кэш) целиком** — `git checkout --theirs`. Корректность > микро-опт; к тому же **Sensors у пользователя выключен** (`Sensors_state=0`), в рантайме код не исполняется. ⚠️ Если Sensors включат и перф важен — переприменить `sensorIndex`.
- **`CPU/readers.swift`** (`68b7e5fe`) — ложный конфликт: их правка тут = `launchPath`→`executableURL` для `uptime`, а мы `uptime` убрали (`getloadavg`). Оставили наш `getloadavg`; реальные хунки коммита (super cores `/Double(eCores.count)`, `channels.first`, `pmset`) легли. Проверено попапом: load avg 4.6/7.5/5.9, E/P-частоты раздельно.
- **`Disk/readers.swift`** (`efc4ae3d`) — 3 конфликтных блока (SMART-walk, `driveDetails` media, `getDeviceIOParent`) = наши leak-фиксы vs их. Оставили наши; фича коммита (`driveIdentityChanged` + новые SMART-поля + release родителя на путях удаления) в неконфликтных хунках легла сама.
- **`extensions.swift`** (`0dd8835a`) — наш перф уже добавил тот же `keyMonitor`+`deinit`, что и их фикс; убрали дубль.

**i18n.** Апстрим `c3fb1fee` добавил `"Deregister text"`, но забыл сам ключ `"Deregister"` (кнопка + заголовок алерта) → не-EN видели англ. fallback. Добрали `"Deregister"` в EN/RU/UK (коммит `c30444af`). Наша `"Max fan speed"` цела.

**Версия (коммит `4f44a0f1`).** `MARKETING_VERSION 3.0.7 → 3.0.8`; `CFBundleVersion → 821` (**своя нумерация форка от 820**; апстримовы инкременты, притащенные пиками в Info.plist до 823, перебиты). Апстрим v3.0.8 = 825.

**Сборка.** Debug compile-check (без подписи) — **BUILD SUCCEEDED**, 0 ошибок/unused. Release под личным сертификатом — **BUILD SUCCEEDED**; app + SMC-хелпер оба `TeamIdentifier=T5V6W6793A`, версия 3.0.8 (821).

**Деплой (2026-07-15).** Бэкап установленной **820** → `/tmp/Stats-backup.app`; `ditto` в `/Applications`. SHA бинаря build==installed, `codesign --verify --deep --strict` зелёный, версия **3.0.8 (821)**, поднялось. Проверены попапами **все 5 включённых модулей** (Net/Disk/CPU/RAM/GPU) — значения живые, крашей нет. Кулерами не управляем → пароль на SMC-хелпер не спрашивался.

**Откат:** ветка `backup/local-build-pre-v3.0.8` (git) + `/tmp/Stats-backup.app` (бинарь 820).

---

## 2026-07-08 — перф-проход №2 + v3.0.6 → v3.0.7 (катч-ап, 3 из 4)

Две части в одной сессии: сначала закоммичен висевший в рабочем дереве второй проход по производительности, затем поверх него подтянут v3.0.7.

### Часть 1 — второй перф-проход (коммит `2d74b940`)

Продолжение оптимизации от 29.06 тем же принципом (срезать посекундную работу readers + per-frame аллокации). Был **несохранённым** в рабочем дереве — закоммичен перед синком (иначе терялся при cherry-pick, как с хвостами 28.06). Что вошло:
- **GPU** (`reader.swift`): кэш io-хэндлов акселераторов, точечное чтение `PerformanceStatistics`/`AGCInfo` через `IORegistryEntryCreateCFProperty` вместо `fetchIOService` каждый тик; re-resolve при устаревшем хэндле (eGPU), release/`deinit`.
- **CPU** (`readers.swift`): `getloadavg()` вместо fork/exec `/usr/bin/uptime` каждые 15с; (`popup`+`portal`) кэш `coreTypeByID` — O(1) вместо O(cores²)-`first(where:)`.
- **Disk** (`readers.swift`): точечное чтение `Statistics`; **фикс утечек io-хэндлов** (release промежуточных parent в `getDeviceIOParent`, release `media`).
- **Net** (`readers.swift`): резолв `interfaceID`/`CWInterface` раз на тик; один get-modify-set `usage`. (`portal`/`popup`/`Speed.swift`) кэш настроек Store, обновление по новому нотифайку `.networkChartSettings` вместо чтения на тик/draw.
- **SMC** (`smc.swift`): негативный кэш отсутствующих ключей (`missingKeys`); error-`print` под `#if DEBUG`.
- **Charts**: кэш `NSGradient` по цвету (Column), O(1) gap-check через `lastPointTs` (Line).
- `DB.swift`: in-place аксессоры (убран COW-копия словаря + двойной `queue.sync` на insert), общий `JSONEncoder/Decoder`. `Store.swift`: `@autoclosure` defaults. `process.swift`: иконка/тултип только при смене pid. `Logger.swift`: общий `DateFormatter`. `SystemStats.swift`: ленивый `MQTTManager`. `AppDelegate.swift`: key-monitor ставится только при заданном popup-шорткате (`.keyboardShortcutChanged`).
- Массово `.display()` → `needsDisplay` по виджетам/попапам/чартам.
- Плюс фича: тумблер **«Max fan speed»** в CPU-попапе (мост к `fun-fan-control`, пишет флаг-файл; EN/RU/UK).

⚠️ **Новые локальные расхождения — пережить при следующем rebase**: файлы 29.06 плюс `DB.swift`, `Store.swift`, `process.swift`, `SystemStats.swift`, `GPU/reader.swift`, `Net/{portal,popup,readers}.swift`, `AppDelegate.swift`, `Kit/module/popup.swift`.

### Часть 2 — v3.0.6 → v3.0.7 (взяли 3 из 4)

`v3.0.6..v3.0.7` = 4 коммита (3 содержательных + бамп `223a2d04`). Метод — cherry-pick `-x` в хронологии поверх перф-коммита.

**Взято:**
- `a3f7a40a` (было `0b847238`) — мелкие улучшения виджетов (BarChart/LineChart/Mini/Stack/widget/types). 3-way свёл **чисто**.
- `66173683` (было `f2b05710`) — фикс цветовых констант. **Конфликт** `CPU/portal.swift`: их фикс чинит реальный баг — `sCoresColor` читал `eCoresColorState` вместо `sCoresColorState`. Взял их фикс + сохранил наш `coreTypeByID`. (В `CPU/popup.swift` этот баг уже был исправлен ранее — не трогали.)
- `34a89e9c` (было `1c87299f`, #3407) — **тумблер ATA SMART** (по умолчанию выкл., «проблемы драйверов»): гейт `if self.ATASMART` на `getATASMART`, retry `SMARTReadData` через `smartEnableAttempted`, overflow-safe умножение LBA, свитч в `Disk/settings.swift`, строка в 40 языках. **Конфликт** `Disk/readers.swift` (только блок свойств) — добавил их `smartEnableAttempted` рядом с нашими `session/smartCache/smartCacheTTL`; авто-слияние само наложило гейт/retry поверх нашего cache-враппера и leak-фиксов (проверено grep'ом — и то, и другое на месте). **Конфликт** 2× `Info.plist` — build `813` vs `819`, взял **819**.

**Пропущено:** `223a2d04` (бамп 3.0.7 — форк ведёт свою нумерацию; версию подняли вручную).

**Версия (коммит `428b87c4`).** `MARKETING_VERSION 3.0.6 → 3.0.7` (2 строки pbxproj, Debug+Release главного таргета) + `Widgets/Info.plist` ShortVersionString `3.0.6 → 3.0.7` (билд-фаза строки 2128 всё равно перезапишет его из `MARKETING_VERSION` + CFBundleVersion из `Stats/Info.plist`, но исходник держим совпадающим, чтобы билд не давал лишний dirty). CFBundleVersion → **819**.

**i18n.** Строка ATA пришла с готовыми ru/uk («ATA SMART данные» / «ATA SMART дані») — добор не нужен. Наша «Max fan speed» цела.

**Сборка.** Debug (compile-check, без подписи) — **BUILD SUCCEEDED**, 0 ошибок, наши файлы реально перекомпилированы (200 `SwiftCompile`). Release под личным сертификатом — **BUILD SUCCEEDED**; app + SMC-хелпер оба `TeamIdentifier=T5V6W6793A`, версия 3.0.7 (819).

**Деплой (2026-07-08).** Бэкап установленной **3.0.6/813** → `/tmp/Stats-backup.app`; `ditto` в `/Applications`. Проверено: SHA-256 бинаря build == installed (`eb8ca0ac…`), `codesign --verify --deep --strict` зелёный, `TeamIdentifier=T5V6W6793A`, версия **3.0.7 (819)**, приложение поднялось и не упало. Кулерами не управляем → админ-пароль на SMC-хелпер не запрашивался.

**Откат:** ветка `backup/local-build-v3.0.6` (git) + `/tmp/Stats-backup.app` (бинарь 813).

### Часть 3 — добор 3 невышедших после v3.0.7 (тем же днём)

Догнали `v3.0.7..upstream/master` (3 коммита, все невышедшие). Cherry-pick `-x`:
- `486ed396` (было `f121597c`) — **обёртка переменных виджетов в `self.queue.sync`** (защита от гонки, 9 виджетов). Конфликт только `Memory.swift` `setValue`: совместил наш redraw-skip guard с их `queue.sync` по их же паттерну из `setPressure` (compare-and-set внутри `queue.sync { () -> Bool }` + `guard updated`). `queue` — из базового `WidgetWrapper`. Остальные 8 виджетов слились чисто.
- `bd28de33` (было `7ba5282d`, #3408) — **interface details при process-based**: `read()` в process-ветке зовёт новый `readInterfaceStatus()`; логика интерфейса вынесена в `updateInterfaceInfo()`; `getBytesInfo()` переписан с per-entry `AF_LINK ifa_data` на **`sysctl NET_RT_IFLIST2` по индексу** (надёжнее). Конфликты `portal.swift` + `readers.swift` — оба на нашем перф-коде. Резолв: **уступили наши per-tick микро-оптимизации Net-ридера** (единый get-set `usage`, hoisting `CWInterface`) в пользу апстримовой структуры — тут это копейки, корректность важнее. Сохранили наш `getLocalIP`-возврат (адаптировали `updateInterfaceInfo`) и `fetchPublicIP`. В `portal.usageCallback` убрали задвоенный `addValue` (апстрим вынес его наверх) и не тащили обратно per-tick `setBase/…` (у нас это в `load()` + `settingsUpdated()`).
- `5490339d` (было `8dcfd55e`, #3403) — Ethernet в нативном виджете, 1 строка, **чисто**.

**Версия/сборка/деплой.** `CFBundleVersion 819 → 820` (MARKETING_VERSION остался 3.0.7 — фиксы невышедшие). Debug compile-check зелёный (0 ошибок); Release под подписью — app+helper `T5V6W6793A`. Бэкап 819 → `/tmp/Stats-backup.app`, `ditto` в `/Applications`, SHA build==installed (`421b2850…`), `codesign --verify --deep --strict` зелёный, версия **3.0.7 (820)**, поднялось и не упало. После этого `upstream/master` **вычерпан полностью** (после `8dcfd55e` ничего нет).

⚠️ **На будущее (rebase):** наш Net-ридер стал ближе к апстриму (микро-опт уступлены); в виджетах теперь их `queue.sync` поверх наших `needsDisplay`. Точка отката для Части 3 — `git reset --hard 0d511257` (или `origin/local/build` до пуша).

---

## 2026-07-05 — v3.0.5 → v3.0.6 (катч-ап, взяли 7 из 8, пропустили Preset-мастер)

Обычный патч-релиз, не мажор. `v3.0.5..v3.0.6` = 9 коммитов (8 содержательных + бамп версии `f2654977`). Метод: cherry-pick `-x` в хронологическом порядке поверх вершины `local/build`, не merge — чтобы точечно выкинуть один коммит и сохранить авторство upstream.

**Взято (7 коммитов, свежие снизу — как легли):**
- `957213a7` (было `9d78a633`) — фикс обновления GPU-попапа при открытии. 8 строк, чисто.
- `51d67483` (было `061caec3`, #3357) — **ATA SMART reader для Disk**. Читает SMART (темп./износ/power-on-hours) для **ATA/SATA**-дисков; NVMe-путь вынесен в `getNVMeSMART`, ATA — в `getATASMART`, `getSMARTDetails` теперь диспетчер. **Конфликт** с нашим perf-патчем (см. ниже).
- `f1ef9b31` (было `8e404d97`, #3374) — фикс выравнивания сегментов в попапе батареи. Off-модуль, косметика.
- `3c203cde` (было `986a8d91`) — новый способ рисовать точку в виджете батареи (убирает баг с видимым `.destinationOut`). Off-модуль.
- `301f2239` (было `8eca489f`) — **⭐ главное: переделка проверки CodeSign в SMC-хелпере.** Валидация XPC-подключения переехала с PID (`kSecGuestAttributePid`) на **audit token** (`kSecGuestAttributeAudit`) — закрывает классическую PID-reuse гонку в XPC-хелперах. Плюс: `setSMCPath`/`callSMC` проверяют подпись `smc`-бинаря (`matchesSelf`) и путь (не symlink/не директория/исполняемый), и уход от `syncShell("/bin/sh -c …")` к `task.executableURL` + массив аргументов (убрана инъекционная поверхность). Новый `import Security` в `SMC/Helper/main.swift`.
- `271bd884` (было `d4877f2f`) — улучшенный сбор WiFi-деталей в Net-ридере. Только `Modules/Net/readers.swift`, чисто (наш perf-патч там же — 3-way свёл без конфликта).
- `b9bb91ec` (было `4ace5241`, #3383) — super-cores цвета в combined-preview. Подбор цвета ядра по `id` (было по индексу с гардом `count ==`), + обработка `.super` в `portal.swift`. CPU-код лёг чисто.

**Пропущено сознательно:**
- `d5d882ae` — **Preset selector** (шаг мастера первого запуска: выбор набора модулей/виджетов). 234 строки в `Setup.swift` + локализация на **40 языков**. Срабатывает только на чистой установке — на уже настроенной машине ноль пользы, а i18n-поверхность огромная. Не берём.
- `f2654977` — бамп версии до 3.0.6 (форк ведёт свою нумерацию, взяли только `CFBundleVersion` 810→**813** из #3383).

**Конфликты (2 файла, оба разрулены):**
- `Modules/Disk/readers.swift` — наш perf-патч (кэш SMART 60с: `getSMARTDetails` → cache-враппер + worker `readSMARTDetails`; переиспользование `DASession`; чистка `_list` по живым PID) пересёкся с ATA-рефактором (тот же `getSMARTDetails` → диспетчер NVMe/ATA). **Резолв:** наш cache-враппер `getSMARTDetails` теперь оборачивает апстримовый диспетчер, который уехал в `readSMARTDetails` (walk по IORegistry + `getNVMeSMART`/`getATASMART`). Плюс держим оба свойства: наши `session`/`smartCache`/`smartCacheTTL` и апстримовый `smartTotals` (нужен ATA — он не отдаёт кумулятивные байты напрямую). Авто-слияние 3-way легло почти идеально, руками только блок свойств.
- `Stats/…/Info.plist` + `Widgets/…/Info.plist` — только `CFBundleVersion` (наш 810 vs апстрим 813). Взяли 813.

**Подпись — проверено, наш кастом сохранён.** `SMC/Helper/Info.plist`: `SMAuthorizedClients` по-прежнему требует личный `subject.OU = T5V6W6793A` (апстрим в этом файле трогает только версию хелпера **1.1.0 → 1.2.0 / build 3 → 4**, требование не задевает — неконфликтные хунки). ⚠️ На будущее: бамп версии хелпера означает, что `checkForUpdate` при следующем запуске захочет **переустановить** хелпер — но это происходит только при включённом управлении кулерами, которым мы не пользуемся, так что путь дремлет. Весь новый CodeSign-код (`matchesSelf`, audit-token) в наших сценариях (только чтение датчиков) не исполняется — но компилироваться обязан.

**i18n.** Ни один `Localizable.strings` в 7 взятых коммитах не затронут (весь i18n-груз был в пропущенном Preset-мастере) → добора EN/RU/UK не требуется.

**Сборка.** Release под личным сертификатом (рецепт SIGNING.md, инкрементально поверх существующего `build/`) → **`** BUILD SUCCEEDED **`**, ошибок нет (единственный варнинг — «SwiftLint not installed», безобидный).

**Деплой (2026-07-05).** `ditto` в `/Applications` по рецепту SIGNING.md, бэкап `810` (v3.0.5) → `/tmp/Stats-backup.app`. Проверено: SHA-256 бинаря build == installed, `CFBundleVersion` 810 → **813**, `TeamIdentifier = T5V6W6793A`, `codesign --verify --deep --strict` зелёный, приложение поднялось из `/Applications/Stats.app`. Управление кулерами не трогали → админ-пароль на переустановку SMC-хелпера не запрашивался (checkForUpdate под `guard status == .enabled` вышел рано).

**Бамп версии + редеплой (2026-07-05).** Первый деплой оставил `MARKETING_VERSION = 3.0.5` (мы пропустили бамп-коммит `f2654977`), из-за чего в настройках показывалось «3.0.5», хотя контент уже v3.0.6 → путаница. Подняли `MARKETING_VERSION` в двух местах `project.pbxproj` (Debug+Release главного таргета) `3.0.5 → 3.0.6` (те же 2 строки, что и в `f2654977`), пересобрали Release, передеплоили. Теперь в настройках честно **3.0.6 (build 813)**; подпись/SHA/verify перепроверены зелёными. **Урок на будущее:** при синке ярлык версии живёт в `MARKETING_VERSION` (`project.pbxproj`), а не в Info.plist (`$(MARKETING_VERSION)`) — если берём контент релиза, но пропускаем его бамп-коммит, версию надо поднять руками, иначе UI врёт. Точка отката осталась `810`/v3.0.5.

Всё запушено в `origin/local/build` (бэкап-форк).

---

## 2026-06-29 — проход по производительности (кэши, утечки, пауза-при-невидимости, старт)

Не синк — локальная оптимизация по запросу «максимум скорости, минимум RAM». Сделана **после** катч-апа на v3.0.5 (запись ниже), тем же днём. 6 коммитов поверх вершины `local/build`. Цель — срезать посекундную работу readers и per-frame аллокации always-on виджетов, плюс перестать опрашивать, когда ничего не видно.

**Метод.** Аудит трёх подсистем (readers / виджеты+charts / Kit-инфраструктура) + ручная проверка. Приоритезация по **реально включённым модулям** (вкл: CPU, Disk, GPU, Network, RAM; выкл: Bluetooth, Battery, Sensors, Clock). Ключевой вывод: фикс reader'а выключенного модуля даёт **ноль** локально — его таймер не тикает (`Module.mount()` под `guard self.enabled`, `disable()` зовёт `reader.stop()`). Поэтому Bluetooth `system_profiler`/`pmset`-каждую-секунду и Sensors/Battery-регекспы **сознательно НЕ трогали** — это кандидаты в upstream-PR, локальной пользы нет.

**Коммиты (`local/build`, свежие снизу):**
- `ca79a8e6` — кэши per-tick + per-frame виджеты + 2 утечки (14 файлов):
  - SMC (`SMC/smc.swift`): кэш метаданных ключа (dataSize/dataType) под `NSLock` → −1 syscall (`readKeyInfo`) на каждое чтение значения. Локально полезно — SMC дёргают CPU и GPU.
  - Sensors (`Modules/Sensors/readers.swift`): ~18 O(n)-поисков по ключу за тик → O(1)-карта `[String:Int]` (`rebuildSensorIndex` на смену списка + self-healing гард `sensorIndex(_:)`). Sensors off → upstream-ценность.
  - Disk (`Modules/Disk/readers.swift`): `DASession` переиспользуется (был `DASessionCreate` каждый тик ×2 reader'а); SMART кэш 60с (частота чтения та же); `_list` процессов чистится до живых PID (утечка).
  - SystemStats (`Kit/plugins/SystemStats.swift`): флаги monitoring/control/update кэшируются в памяти — нет чтения UserDefaults на каждый reader-callback.
  - Clock (`Modules/Clock/main.swift`): `DateFormatter` кэш по (calendar,tz,format). Clock off → upstream.
  - helpers (`Kit/helpers.swift`): `ByteCountFormatter` / `NumberFormatter` / `MeasurementFormatter` + system-temp-unit кэшируются (раньше — новый объект на каждый вызов). Локально: RAM/Net/Disk `getReadable*`.
  - Reader base (`Kit/module/reader.swift`): `moduleKey` строится один раз (`lazy`, был `NSStringFromClass`+интерполяция каждый тик); две `DispatchQueue` с одинаковым label → один `NSLock`.
  - Always-on виджеты: `NetworkChart` (single-pass max), `Speed` (`input/outputColor` из computed-замыканий → методы), `Memory` (static font/style), `Stack` (состояние раз на `draw`, не `queue.sync` на каждую ячейку).
  - Утечки: event-monitor в `KeyboardShartcutView` снимается в `deinit` (`Kit/extensions.swift`); Disk `_list`; Net-обсерверы в `terminate()` (`Modules/Net/readers.swift`, там же reorder `VPNMode && vpnConnection` + reuse `wifiClient`).
  - CPU (`Modules/CPU/readers.swift`): E/P/S-разбиение ядер предрасчитано в `setup()` (было 3× filter/тик); буферы через `removeAll(keepingCapacity:)`.
- `886c9236` — пауза readers на **сон дисплея / блокировку экрана**.
- `77bbbb91` — параллельный старт `SystemKit` (`Kit/plugins/SystemKit.swift`): 3 subprocess-зонда RAM/GPU/Disk через `DispatchGroup`, wall-clock = max, а не сумма; `getDisplayInfo` остаётся на потоке init (AppKit/NSScreen).
- `86e83da1` — redraw-skip при неизменном значении (`Memory.setValue` + Pie/Tachometer/Gauge `setSegments`).
- `9e97cb27` — пауза readers в **фуллскрине** (occlusion статус-окон).
- `933ea04c` — polish popup-графиков (`Charts.swift`: кэш `NSGradient` в LineChartView, single-pass minMax, удалён мёртвый `list` в BarChartView, `list`-только-при-ховере в ColumnChartView).

**Пауза-при-невидимости — поведенческое изменение, детали в [FEATURES.md](FEATURES.md) №4.** ⚠️ Главное на будущее: опрос **полностью встаёт**, когда меню-бар не виден (сон дисплея / блокировка / фуллскрин), и графики истории на это время **замирают** (пропуск точек, продолжают с того же места). Если когда-нибудь увидишь «пропуски в графиках после сна/фуллскрина» — это **НЕ баг, это фича**. Occlusion-сигнал (фуллскрин) — наименее детерминированный (зависит от версии macOS), fail-safe: не нашли `NSStatusBarWindow` → считаем видимым. На текущей macOS проверено вживую — паузит/оживляет корректно.

**Новые локальные расхождения с upstream — пережить при следующем rebase.** Perf-дельты в: `SMC/smc.swift`, `Kit/helpers.swift`, `Kit/extensions.swift`, `Kit/module/reader.swift`, `Kit/module/module.swift`, `Kit/plugins/{SystemStats,SystemKit,Charts}.swift`, `Kit/Widgets/{Memory,NetworkChart,Speed,Stack}.swift`, `Modules/{CPU,Disk,Net,Sensors}/readers.swift`, `Modules/Clock/main.swift`, `Stats/AppDelegate.swift`. **Зона риска при синке** — `Charts.swift`, `Speed.swift`, `helpers.swift`, `SystemStats.swift` (апстрим их трогает); 3-way скорее всего сведёт, но проверять поведение.

**Сборка/деплой.** Каждый батч — компиляция Debug без подписи (рецепт SIGNING.md), финал — Release под личным сертификатом, sanity-check зелёный (3 OU = `T5V6W6793A`), версия 3.0.5 (не бампали — отличие только в бинаре). `ditto` в `/Applications`, SHA-256 build == installed, в бинаре подтверждены `menuBarOcclusionChanged` и `SystemKit.probe`. Бэкап `/tmp/Stats-backup.app` обновлялся перед каждым деплоем. Всё запушено в `origin/local/build` (бэкап-форк, правило №1).

**Что осталось (опционально).** Регекспы (`String.matches`/`findAndCrop` мимо `RegexCache`) — горячи лишь в popup-gated ридерах, локально почти ноль. Upstream-PR для off-модулей (Bluetooth `system_profiler`/`pmset` каждую секунду и пр.). На steady-state двигать практически нечего.

---

## 2026-06-29 — v3.0.4 → v3.0.5 (катч-ап, «на всякий случай»)

Мелкий патч-релиз. Поводом был не must-have, а гигиена — пока дельта мала, синк дёшев.

**Объём:** `v3.0.4..v3.0.5` = 7 коммитов. Для нас почти всё мимо: фиксы вентиляторов (`#3360` откат расчёта % на 0–max rpm, `#3344` доп. состояние кнопки fan-helper — кулерами не управляем), разделение подписи ёмкости и уровня в попапе **батареи** (`00d43b96`, `Modules/Battery/popup.swift` — косметика), бенгальский (`#3348`) + добор переводов. Единственное содержательное — **`#3231` (`cda6b990`): опция «фиксированная единица» (Auto/KB/MB/…) для модулей Net и Disk** (автор IonBazan).

**Как делали.** Сначала закоммитили два висевших с 28.06 хвоста (иначе терялись при rebase): `local: strip debug() logging from Release` (тот самый Logger no-op) и `docs:` (запись 28.06 + get-task-allow в SIGNING). Затем `git rebase --onto v3.0.5 v3.0.4 local/build`. **Ноль конфликтов** — все 14 коммитов (12 наших + 2 новых) легли чисто. Бэкап: `backup/local-build-v3.0.4`.

**Грабли тега — снова в самом теге (как v3.0.4).** Бамп `MARKETING_VERSION = 3.0.5` сидит **прямо в `v3.0.5`** (`2fff0dfb`), не в tag+1. Проверено по объекту Release-конфига главного таргета `9A141107229E721200D29793`. И `v3.0.5..upstream/master` пусто → тег = вершина master. База rebase = сам тег, без сдвига. (Маинтейнер по-прежнему непостоянен — **проверяй каждый раз**.)

**Зона риска — `Speed.swift` — пережила.** `#3231` правит `Kit/Widgets/Speed.swift` (+`helpers.swift`/`types.swift`/`Charts.swift`, Net/Disk модули) — ровно там, где наши `split-bar I/O` и `Net speed widget gap`. 3-way свёл чисто; вживую проверено, что в дереве **сосуществуют** наш split-io (`twoRows`/`oneRow`, gap 4pt) и апстримный fixed-unit (`NetworkSpeedUnit*` в `types.swift`).

**i18n.** Все **7 кастомных ключей** (split download/upload, split read/write, color cores E/P, memory pressure indicator + 3 цвета) живы в en/ru/uk несмотря на коммиты «missing translations» и бенгали. Проверено поимённо — `i18n.py fix` не понадобился.

**Xcode 16.0 — в этот раз НИ ОДНОГО нового trailing-comma спота** (в отличие от v3.0.1 и v3.0.4, каждый из которых добавлял по одному). Сборка чистая из коробки. Косметика: v3.0.5 в pbxproj сменил в build-phase версии `$(PWD)` → `${SRCROOT}` — безвредно.

**Сборка/деплой.** `BUILD SUCCEEDED` под Xcode 16.0 (рецепт SIGNING.md без изменений), sanity-check зелёный (3 OU = `T5V6W6793A`), версия 3.0.5. Бэкап текущей 3.0.4 → `/tmp/Stats-backup.app`, `ditto` в `/Applications`, SHA-256 бинаря build == installed, запущено — работает 3.0.5.

**Зеркало.** `local/build` force-push'нута в `origin/local/build` (бэкап в свой форк, правило №1). Старая вершина — в `backup/local-build-v3.0.4`.

**Триггер следующего обязательного синка — без изменений:** удаление апстримом legacy-ветки `SMJobBless`. Косметику можно тянуть когда угодно.

---

## 2026-06-28 — локальная правка логгера + ре-деплой Release (RAM-гигиена)

Не синк — локальная оптимизация по запросу «выкинуть debug из шипнутой сборки».

**`debug()` → no-op в Release.** `Kit/plugins/Logger.swift`: сигнатура переведена на `@autoclosure () -> String`, тело обёрнуто в `#if DEBUG`. Раньше каждый из **60 вызовов** `debug()` всегда строил префикс (с **новым `DateFormatter` на каждый вызов**!) и писал в stderr — даже в Release, фильтра по уровню в `NextLog` нет. Теперь в Release строка-сообщение **не вычисляется вообще**. `info()`/`error()` не трогали (низкочастотные, полезны для диагностики).

⚠️ **Новое локальное расхождение с upstream** — при следующем rebase должно пережить merge (`Logger.swift` апстрим трогает редко). Закоммичено отдельным `local:`-коммитом перед rebase на v3.0.5 (см. запись 2026-06-29 ниже).

**`get-task-allow` — это НЕ признак Debug-сборки.** По ходу выяснилось: `com.apple.security.get-task-allow=1` сидит и в Release тоже — он инжектится при подписи **dev-сертификатом «Apple Development»**, а не конфигурацией Debug. Убирается только Distribution-подписью (Developer ID, у нас нет). На RAM/работу не влияет — лишь разрешает присоединять отладчик. Раньше это ошибочно принималось за «в /Applications лежит Debug». Вписано в [SIGNING.md](SIGNING.md).

**Ре-деплой.** Пересобрали v3.0.4 (804) в Release (рецепт из SIGNING.md без изменений), sanity-check зелёный (3 OU = `T5V6W6793A`), `ditto` в `/Applications` с бэкапом `/tmp/Stats-backup.app`. SHA-256 установленного бинаря == собранного. Исполняемый файл ~16 КБ меньше прежнего; на установившуюся RAM правка почти не влияет (реальные рычаги — число модулей, длина истории графиков, частота опроса).

---

## 2026-06-24 — v3.0.1 → v3.0.4 (катч-ап, **#3237 взят как есть**)

Развернули решение от 14.06 «остаёмся на v3.0.1»: подтянули диапазон `v3.0.1..v3.0.4`. Поводом был не конкретный must-have, а гигиена — пока дельта мала, синк дёшев; проверили это замером (ниже), а не на веру.

**Объём:** `v3.0.1..v3.0.4` = 84 файла, +1970 / −2902 (минус — во многом апстримовская чистка переводов). Содержимое v3.0.4 — в основном **редизайны попапов** (Battery/Clock/Disk/Fans), плюс фичи: порог уведомлений `#3211`, основной цвет Disk `#3285`, открытие вкладки Activity Monitor; фикс фона Network-виджета `#3268`.

**Как делали.** `git rebase --onto v3.0.4 991d4ceb local/build` (база v3.0.1 = `991d4ceb`). **Ноль конфликтов** — все 9 наших коммитов легли чисто, 3-way развёл и `Localizable.strings`. Тяжёлые файлы наших фич (`BarChart.swift`, `Speed.swift`, CPU/RAM main+settings) апстрим в v3.0.4 **не трогал** — отсюда гладкость. Бэкап: `backup/local-build-v3.0.1`.

**Грабли тега — в этот раз НЕ сработали.** Бамп `MARKETING_VERSION = 3.0.4` сидит **прямо в теге** `v3.0.4` (`9a8e6e26`), а не в tag+1. Т.е. база = сам тег, без сдвига. (Маинтейнер непостоянен: для v3.0.1 бамп был в tag+1 — **проверяй каждый раз**.)

**i18n.** Все **7 наших кастомных ключей** (split download/upload, split read/write, color cores E/P, memory pressure indicator + 3 цвета) выжили в en/ru/uk несмотря на чистку −1655 строк. Проверено поимённо — `i18n.py fix` не понадобился.

**#3237 (SMAppService) — взяли как есть, вопреки плану от 14.06.** План был «всё, кроме #3237» в расчёте на самодостаточность коммита. Оказалось — **переплетён**: поздние коммиты v3.0.4 (`93fa5820`, `7654330b`, `fc8e77c6`, `f5f25f29`) правят те же `Kit/helpers.swift` и `Sensors/popup.swift`. Чистый `revert e6b4c044` даёт **битый полу-откат** (plist удаляется, но SMAppService-код и build-phase остаются → не собирается). Взять целиком оказалось дешевле и чище. Для нас безопасно — кулерами не управляем, `register()` не дёргается. Подробности и sanity-check — в [SIGNING.md](SIGNING.md) (секция теперь «✅ Принятая миграция»).

**Xcode 16.0.** Ровно одно новое trailing-comma место — `Kit/plugins/SystemStats.swift:251` (плагин б. Remote получил новые команды в `bd8826b2`). Правка — отдельным compat-коммитом (интерактивный rebase для дозаписи в основной костыль в окружении недоступен), задокументировано в [XCODE-COMPAT.md](XCODE-COMPAT.md) №5. Больше ничего не сломалось — Wi-Fi-7 костыль в `Net/readers.swift` пережил merge.

**Итог.** `local/build` = `v3.0.4` + 9 наших коммитов + compat-правка SystemStats. Release-сборка под Xcode 16.0 зелёная, все 3 OU = `T5V6W6793A`, версия 3.0.4. Задеплоено в `/Applications`.

**Бэкап + чистка веток.** Снесены стале-ветки `backup/local-build-v2.12.15` и `rebase/v3.0.1` (оставлена `backup/local-build-v3.0.1`). `local/build` force-push'нута в `origin/local/build` (была на v2.12.15) — это **смягчило правило-предохранитель №1**: `local/build` теперь зеркалится в свой форк как бэкап (но по-прежнему не источник upstream-PR), см. [WORKFLOW.md](WORKFLOW.md). Пофичевые `feat/*` на origin (v2.12.14) и локальная `feat/personal-tweaks` (v2.12.15) — **не трогали**, остались устаревшими.

**Триггер следующего обязательного синка:** удаление апстримом legacy-ветки `SMJobBless` (когда `SMAppService` останется единственным путём). Косметику можно тянуть когда угодно — она сливается дёшево.

---

## 2026-06-14 — обзор v3.0.2 / v3.0.3 → решено НЕ синкать (остаёмся на v3.0.1)

Поверх нашей базы вышли два релиза (оба 14.06). Разобрали по коммитам — **синк отложен сознательно**. Единственная реальная ценность для нас — фиксы стабильности, а наблюдаемых крашей у нас нет; всё остальное либо косметика, либо фичи, которыми мы не пользуемся.

| Коммит | Что | Вердикт для нас |
|---|---|---|
| 72f3357e | фикс краша отрисовки графиков `#3297` | ценно (стабильность), но крашей не ловим |
| f5f25f29 | упрочнение optional'ов, 15 файлов | ценно (стабильность), не срочно |
| ba8892e6 / efa9c4f3 | pie / line chart отрисовка `#3294` | косметика |
| 495d04cf | «On Hold» в попапе батареи | по желанию |
| 61fe7d2b | позиция в меню-баре при `Combined modules` | не используем Combined modules |
| 5432cc23 | детект M5 super-cores `#3250` | не наш чип |
| 7654330b | редизайн попапов | косметика |
| c8bf37d9 | апдейтер `cp`→`ditto` `#3218` | НЕ используем встроенный апдейтер (деплой ручной) |
| 68fed43d | чистка переводов −1655 строк | ⚠️ при синке проверить, что наши кастомные ключи (split I/O, memory pressure, E/P cores) выжили |
| **e6b4c044** | **миграция SMC `SMJobBless` → `SMAppService.daemon` `#3237`** | **🚫 НЕ брать — отложенная миграция, см. [SIGNING.md](SIGNING.md)** |

**Триггеры вернуться к синку:** (1) выйдет фича, которую реально захотим — подтянем всё пачкой; (2) переезд на **macOS 27 «Golden Gate»** (совместимость завезли в v3.0.2, коммит 49e0d87e) — тогда синк уже обязателен.

**Когда соберёмся синкать v3.0.2+:** берём весь диапазон `v3.0.1..` **кроме `#3237`** (e6b4c044, самодостаточен — трогает только файлы SMC-хелпера и свой кусок pbxproj, пропускается без конфликтов), затем обычная i18n-сверка (`i18n.py fix`) с проверкой кастомных ключей.

---

## 2026-06-12 — v2.12.15 → v3.0.1 (мажор)

**Объём:** 170 файлов, +5504 / −3472. Не патч — большая переработка.

**Как делали.** Прямой `git rebase --onto` всего стека `local/build` на новую базу (не по цепочке feat-веток — для мажора так проще). Бэкап обязательно:
```bash
git branch backup/local-build-v2.12.15 local/build
git rebase --onto v3.0.1 v2.12.15 local/build
```
Конфликтов — **ноль**: 3-way merge развёл все 9 пересекающихся файлов. Тяжёлые файлы наших фич (`Kit/Widgets/BarChart.swift`, `Speed.swift`, `Modules/CPU,RAM/main+settings`) апстрим в v3 не трогал — поэтому так гладко.

**Новый Xcode-16.0-костыль.** Мажор добавил ровно одно новое место с trailing-запятой — `Modules/Remote/main.swift` (модуль переписан в v3). Вложили в коммит-костыль (см. [XCODE-COMPAT.md](XCODE-COMPAT.md), п.4). Больше под Xcode 16.0 ничего не сломалось.

**⚠️ Грабли версии (важно для будущих синков).** Тег `v3.0.1` указывает на коммит `672ced07`, где `MARKETING_VERSION` ещё **3.0.0**. Бамп `→ 3.0.1` сделан в СЛЕДУЮЩЕМ коммите `991d4ceb` («v3.0.1»), родитель которого — ровно тег. Если собрать с тега, Settings покажет 3.0.0. Передвинули базу с тега на `991d4ceb` (tag+1), кода там нет — только строки версий:
```bash
git rebase --onto 991d4ceb v3.0.1 local/build
```
Похоже, маинтейнер **всегда тегает ДО бампа версии** — проверяй это каждый раз.

**⚠️ Грабли подписи.** При первом Release-билде словили путаницу team ID: решили, что team = `88FBB4GZ5S`, и поменяли Info.plist под него. Оказалось, `88FBB4GZ5S` — это individual-id в commonName сертификата, а **реальный team (OU) = `T5V6W6793A`**, и исходный Info.plist был верным. Откатили правку, пересобрали. Подробности и проверки — в [SIGNING.md](SIGNING.md).

**Решение по дублю фич.** v3 добавил **свой** memory-pressure: цвет «Based on pressure» (для bar/line/mini/memory) + отдельный **Dot-виджет** (ключ `state`). Это частично дублирует нашу `feat: memory pressure bar indicator`. Сравнили вживую — **оставили нашу** (у неё кастомные цвета normal/warning/critical, у апстрима фиксированные).

**Итог.** `local/build` = `991d4ceb` (v3.0.1) + 8 наших коммитов; собирается под Xcode 16.0; задеплоено в `/Applications` как **v3.0.1**.

**Хвост (не сделано):**
- `feat/personal-tweaks` и `feat/*` остались на базе v2.12.15 — перебазировать на v3 (для бэкапа на GitHub; `local/build` не пушится).
- На `upstream/master` после v3.0.1 висят 2 невышедших fix'а: краш отрисовки графика (#3297) и упрочнение optional'ов — можно cherry-pick при желании. (Третий, фича macOS 27 «Golden Gate», нам не нужен.)
- Подчистить страховочные ветки `backup/local-build-v2.12.15` и `rebase/v3.0.1`, когда v3 устаканится.
