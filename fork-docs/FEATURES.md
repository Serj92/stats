# Кастомные фичи

Каталог доработок, добавленных в этом форке. Каждая фича — отдельный коммит на ветке `feat/personal-tweaks`.

---

## 1. Split-bar I/O для виджетов Disk и Network

**Идея.** В существующий вертикальный bar-виджет добавить опциональный split-режим:
- **Disk:** нижняя половина — чтение (read, синий, растёт снизу), верхняя — запись (write, красный, складывается **поверх** read'а)
- **Network:** аналогично — download внизу, upload над ним

Высота сегмента — отношение текущего значения к peak'у, накопленному за сессию (peak пересчитывается на лету). Это значит бар самокалибруется и не требует ручной настройки пороговых значений.

**Issue.** [exelban/stats#3233](https://github.com/exelban/stats/issues/3233) — закрыт мейнтейнером, но он сделал не совсем то, что просили. Это локальная реализация ближе к исходному запросу.

**Файлы.**

- `Kit/Widgets/BarChart.swift` — общая инфраструктура: persistent `splitState`, `peakInput` / `peakOutput`, отдельная ветка рендеринга в `draw()` (рисует два прямоугольника друг над другом вместо стандартного стека), новый метод `setSplitValue(input:output:)`, gated UI-переключатель в `settings()` (показывается только когда `title == "Disk" || title == "Network"`).
- `Modules/Disk/main.swift` — две callback-ветки в `loadCallback`: обычная `capacityCallback` (когда split выключен — рисует заполнение по %) + `activityCallback` (когда split включён — вызывает `setSplitValue(input: read, output: write)`).
- `Modules/Net/config.plist` — добавлена секция `bar_chart` (Order=3, по умолчанию выключен).
- `Modules/Net/main.swift` — в `usageCallback` добавлена ветка `case let widget as BarChart where widget.isSplitMode: widget.setSplitValue(input: download, output: upload)`.

**Как пользоваться (Disk).**

1. Settings → Disk → секция bar_chart уже есть по дефолту
2. Шестерёнка bar_chart в menu bar → переключатель **Split read/write**

**Как пользоваться (Network).**

1. Settings → Network → секция Widgets → включить **bar_chart** (по дефолту выключен)
2. Шестерёнка bar_chart в menu bar → переключатель **Split download/upload**

**Известные ограничения.**

- Peak считается **с момента запуска приложения**, не персистится между запусками. После рестарта Stats бар какое-то время будет показывать почти пустоту, пока не накопится peak.
- Если значение резко превышает предыдущий peak — peak обновляется, и относительные размеры сегментов "сдуваются" пока не пройдёт пик.

---

## 2. Memory Pressure Bar для виджета RAM

**Идея.** Зеркало индикатора **Memory Pressure** из macOS Activity Monitor (нижняя часть вкладки Memory). Одна тонкая колонка с двумя свойствами:

- **Высота заполнения** = `(wired + compressed) / total` — память, которую система **не может быстро отдать**. Wired pages заблокированы ядром, compressed pages уже сжаты и освобождаются только через swap I/O. Это та же эвристика, что и в Activity Monitor.
- **Цвет** — из kernel pressure verdict (`kern.memorystatus_vm_pressure_level`):
  - `.normal` → зелёный
  - `.warning` → жёлтый
  - `.critical` → красный

Высота движется плавно от состояния системы (обычно 10–30% в покое, растёт когда начинается свопинг), цвет переключается когда ядро объявляет тревогу. Цвет и высота независимы — система может быть на жёлтом давлении при умеренном заполнении или на зелёном при высоком.

**Why такой подход.** Раньше делали гибрид с band'ами по pressure level и compression ratio внутри band'а — давало "вяло и постоянно жёлто". Activity Monitor сам не использует compression ratio для высоты, и его подход куда понятнее визуально: фактическое непереназначаемое потребление + статус ядра как цвет.

**Issue.** [exelban/stats#3234](https://github.com/exelban/stats/issues/3234).

**Файлы.**

- `Modules/RAM/main.swift` — `pressureFillState` (computed из Store), `pressureFill(_ value: RAM_Usage)` helper (возвращает `(ratio: Double, color: NSColor)`), ветка в `loadCallback` BarChart case **перед** `splitValueState`. Три computed property для цветов (`pressureNormalColor` / `pressureWarningColor` / `pressureCriticalColor`) с дефолтами `secondGreen` / `secondYellow` / `secondRed`.
- `Modules/RAM/settings.swift` — `pressureFillState: Bool` поле, чтение из Store в `init`, UI-row "Memory pressure indicator" в bar_chart-секции, handler `togglePressureFill`. Плюс три SColor state'а и три color picker'а (`Memory pressure normal/warning/critical color`) — изменения сохраняются под ключами `RAM_pressureNormalColor` / `_pressureWarningColor` / `_pressureCriticalColor` и читаются обоими файлами.

**Как пользоваться.**

1. Settings → RAM → секция bar_chart → переключатель **Memory pressure indicator**

Эта опция взаимоисключающа с **Split the value (App/Wired/Compressed)** — `pressureFillState` проверяется раньше в `else if` цепочке.

---

## 3. Раскраска CPU bar по типу ядер (E/P)

**Идея.** Один тонкий вертикальный бар, разделённый на сегменты по типам ядер: efficiency cores внизу (свой цвет), performance cores поверх (свой цвет), super cores ещё выше (на чипах где есть). Бар **не расширяется** в ширину — остаётся в одну колонку, в отличие от существующих режимов "Show usage per core" и "Cluster grouping" которые разворачивают бар по количеству ядер/кластеров.

**Как считается высота сегмента.** Вклад каждого кластера = `usageXCores * (xCount / totalCount)`. Сумма даёт средневзвешенную общую нагрузку, что соответствует тому, что отображается без разбивки.

**Цвета** реиспользуют существующие настройки `eCoresColor` / `pCoresColor` / `sCoresColor`, которые редактируются через **popup → Settings → Color** (а не через шестерёнку виджета). Дефолты апстрима: E=teal, P=indigo, S=orange. Менять там же.

**Доступность.** Только на arm64 (на Intel CPU нет разделения на типы ядер). UI-row обёрнут в `#if arch(arm64)`.

**Файлы.**

- `Modules/CPU/main.swift` — computed `coresColorState` (из Store), новая ветка в `loadCallback` BarChart case (между `usagePerCoreState` и `splitValueState`).
- `Modules/CPU/settings.swift` — `coresColorState: Bool` поле, чтение из Store, UI-row "Color cores by type (E/P)" внутри `#if arch(arm64)`, handler `toggleCoresColor`.

**Как пользоваться.**

1. Settings → CPU → секция bar_chart → переключатель **Color cores by type (E/P)**
2. (опционально) Чтобы поменять цвета — открыть **popup** (клик по иконке CPU в menu bar) → вкладка **Settings** → секция **Color** → выпадайки для **Efficiency cores** / **Performance cores** / **Super cores**

**Взаимодействие с другими опциями.** `coresColorState` стоит в `else if` цепочке после `usagePerCoreState` и `groupByClustersState`, но перед `splitValueState`. То есть если включены сразу несколько — `usagePerCore` или `clustersGroup` имеют приоритет. На практике их обычно не включают вместе.

---

## Где найти место под новую фичу

Большинство виджетов — `Kit/Widgets/*.swift` (shared между модулями). Если добавляешь новую опцию виджета: persistent state + UI в `settings()` + публичный API + ветка в `draw()`.

Модули — `Modules/<Name>/main.swift` (callback'и читателей) + `Modules/<Name>/settings.swift` (UI для опций уровня модуля) + `Modules/<Name>/config.plist` (список виджетов модуля).

Если опция чисто-визуальная и применима ко многим модулям — её можно положить в Kit/Widgets и гейтить по `self.title` (как сделано для split). Если опция привязана к семантике конкретного модуля (например, pressure фичу понимает только RAM) — в `Modules/<Name>/settings.swift`.
