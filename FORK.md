# Личный форк Stats

Это форк [exelban/stats](https://github.com/exelban/stats) — macOS menu-bar монитора системы. Тут живут несколько доработок виджетов, которые не вошли в апстрим (либо были закрыты мейнтейнером, либо запланированы как локальный прототип).

## TL;DR

- **Работа всегда происходит на ветке `local/build`** — она содержит фичи + локальные костыли для текущего Xcode
- Фичи лежат отдельно на `feat/personal-tweaks` — её можно пушить в свой GitHub-форк как бэкап
- `master` синхронизирован с `upstream/master`, без своих коммитов
- **`local/build` никогда не пушится** в `origin` (содержит downgrade-патчи для старого Xcode)

## Документация

Детали — в `fork-docs/`:

- [WORKFLOW.md](fork-docs/WORKFLOW.md) — структура веток, ежедневная работа, синхронизация с upstream
- [FEATURES.md](fork-docs/FEATURES.md) — каталог кастомных фич: что добавлено, где в коде, как пользоваться
- [XCODE-COMPAT.md](fork-docs/XCODE-COMPAT.md) — локальные костыли для Xcode 16.0 / macOS 15

## Быстрый старт после клона

```bash
git clone https://github.com/Serj92/stats.git
cd stats
git remote add upstream https://github.com/exelban/stats.git
git fetch upstream
git checkout local/build  # рабочая ветка
```

Сборка из CLI (если не из Xcode GUI):

```bash
xcodebuild -project Stats.xcodeproj -scheme Stats -configuration Debug \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/Stats-bezmwofcmqgusfdxdepofrmqhujt \
  build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Запуск debug-сборки:

```bash
open ~/Library/Developer/Xcode/DerivedData/Stats-bezmwofcmqgusfdxdepofrmqhujt/Build/Products/Debug/Stats.app
```
