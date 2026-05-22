# Xcode 16.0 build compatibility

Этот документ описывает локальные downgrade-патчи, которые живут одним коммитом на ветке `local/build` (но не на `feat/personal-tweaks`). Они нужны только для того, чтобы код апстрима собрался на старой версии Xcode.

## Почему они нужны

- Хост-машина: **macOS 15.7.7 Sequoia** (Apple Silicon, arm64)
- Доступный Xcode: **16.0** (последний поддерживаемый этой версией macOS)
- Апстрим `exelban/stats` использует фичи и SDK более свежих Xcode (16.4+ / 26.x), которые требуют macOS 26.2 для установки

При обновлении хоста до macOS 26.x (когда станет возможным) и установке свежего Xcode — **этот коммит надо удалить целиком**, апстрим заработает as-is.

## Что в коммите

Три точечных изменения в файлах апстрима:

### 1. `Kit/plugins/SystemKit.swift`

Удалена trailing comma после case `.unknown` в одном из enum'ов / списков. Trailing commas в вызовах функций и литералах разрешены начиная с Swift 6.0 ([SE-0438](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0438-trailing-comma.md)), который шипит с Xcode 16.4. Xcode 16.0 их не парсит.

### 2. `Modules/GPU/main.swift`

То же самое — trailing comma после аргумента `preview: self.previewView` в вызове `super.init(...)`. Удалена.

### 3. `Modules/Net/readers.swift`

Закомментирован case `case .mode11be: return "802.11be"` в switch'е по `CWPHYMode`. Wi-Fi 7 (`.mode11be`) — это enum value в `CoreWLAN`, появившийся в SDK более новой macOS. В SDK поставляемой с Xcode 16.0 этого case нет, и компилятор падает на нём с "unknown member" в exhaustive switch.

## Что делать когда апстрим что-то новое не собирается

Сценарий: ты сделал `git rebase master` в рамках синхронизации, перешёл на `local/build`, собрал — и Xcode жалуется на новые места.

1. **НЕ паникуй и НЕ правь апстримный код "лучшим способом".** Этот коммит — намеренный downgrade, он должен быть минимально-инвазивным и точечным.
2. На ветке `local/build` сделать `git rebase -i feat/personal-tweaks` и в режиме `edit` отредактировать коммит-костыль, добавив новые точечные правки.
3. В commit message добавить новый bullet с пояснением какое именно место и зачем downgrade'нуто.
4. `git rebase --continue`.

Цель этого коммита — оставаться **точным, маленьким, и легко отменяемым** одной командой `git reset --hard feat/personal-tweaks` когда обновится Xcode.

## Что делать когда станет доступен свежий Xcode

1. Установить новый Xcode и macOS
2. Переключиться на `feat/personal-tweaks` и собрать оттуда. Если собирается без проблем — отлично.
3. Удалить ветку `local/build` целиком:
   ```bash
   git branch -D local/build
   ```
4. Дальше работать прямо на `feat/personal-tweaks` (или создать новую ветку под фичи в работе).
5. Обновить [WORKFLOW.md](WORKFLOW.md) — убрать упоминания `local/build`.

## Почему нельзя просто закоммитить эти патчи в `feat/personal-tweaks`

Эта ветка концептуально "то, что мог бы быть PR в апстрим". Trailing commas и закомменченый `.mode11be` — это **regression** относительно того, что апстрим хочет поддерживать (Swift 6.0 синтаксис, Wi-Fi 7). Если их втащить в `feat/personal-tweaks`, любой PR оттуда будет автоматически отклонён, и сам форк перестанет быть полезным как бэкап чистой работы.

Поэтому костыли изолированы в отдельный коммит на отдельной ветке, которая **никогда не пушится** в `origin`.
