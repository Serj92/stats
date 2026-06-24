# Workflow

## Структура веток

```
master                       ← синхрон с upstream/master, БЕЗ своих коммитов
└── feat/personal-tweaks     ← 3 фича-коммита (split I/O, RAM pressure, CPU cores color)
                                + коммит с этой документацией
    └── local/build          ← + 1 коммит-костыль (Xcode 16.0 compat)
                               ↑ ТЕКУЩАЯ РАБОЧАЯ ВЕТКА
```

**Why такая структура:**

- **`master` чистый** — даёт всегда воспроизводимую точку синхронизации с апстримом. Никаких "merge-конфликтов с самим собой".
- **`feat/personal-tweaks` отдельно от костылей** — фичи можно безопасно пушить в свой форк, показывать другим, или конвертировать в PR. Если перенесёшь фичу в апстрим, она там не утянет за собой downgrade-патчи.
- **`local/build` поверх** — даёт работающую локальную сборку на старом Xcode без загрязнения фича-веток. Если завтра поставишь свежий Xcode, эту ветку просто удалишь.

## Ежедневная работа

**Всегда работай на `local/build`.** Это единственная ветка, где код реально собирается на твоей машине.

```bash
git checkout local/build
# ... пишешь код, тестируешь ...
git add <файлы фичи>
git commit -m "feat: краткое описание"
```

Новый коммит ляжет **на вершину** `local/build`, после коммита с костылями. Это нормально для повседневной работы. Когда фича готова — переноси её на `feat/personal-tweaks` (см. ниже).

### Перенос новой фичи на feat/personal-tweaks

После коммита на `local/build`:

```bash
git log --oneline -3                          # узнать hash нового коммита
git checkout feat/personal-tweaks
git cherry-pick <hash>                        # копируем коммит сюда
git checkout local/build
git rebase feat/personal-tweaks               # переставляем костыль-коммит наверх
```

Результат: новая фича теперь и в `feat/personal-tweaks` (чистая), и в `local/build` (с костылём поверх).

### Проверка целостности

После любой реорганизации убеждайся, что **коммит-костыль остаётся последним** на `local/build`:

```bash
git log --oneline local/build
# Последний (HEAD) должен быть: "local: Xcode 16.0 build compatibility — DO NOT MERGE"
```

Если съехал — `git rebase -i feat/personal-tweaks` и переставь руками.

## Синхронизация с upstream

Когда в `exelban/stats` выходит новый релиз или просто появились коммиты, делаем три ребейза по цепочке:

### Шаг 1 — обновить master

```bash
git fetch upstream
git checkout master
git merge --ff-only upstream/master           # только fast-forward, без своих коммитов это всегда сработает
git push origin master                        # обновить свой форк на GitHub
```

Если `--ff-only` отказал — значит на master случайно появился коммит. Не должно быть никогда. Если случилось — разберись прежде чем продолжать.

### Шаг 2 — подтянуть upstream под фичи

```bash
git checkout feat/personal-tweaks
git rebase master
```

Конфликты здесь — **реальные пересечения** между апстрим-изменениями и твоими фичами. Резолвить руками:

```bash
# Открываешь конфликтный файл, выбираешь что оставить
git add <файл>
git rebase --continue
```

После успешного ребейза:

```bash
git push --force-with-lease origin feat/personal-tweaks
```

`--force-with-lease` (а не `--force`) защищает от случайной перезаписи, если кто-то ещё пушил.

### Шаг 3 — подтянуть фичи под костыль

```bash
git checkout local/build
git rebase feat/personal-tweaks
```

Конфликты здесь — **только в 3 файлах из костыля** (или вообще никаких, если апстрим не трогал `SystemKit.swift` / `GPU/main.swift` / `Net/readers.swift`).

### Шаг 4 — пересобрать

```bash
xcodebuild -project Stats.xcodeproj -scheme Stats -configuration Debug \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/Stats-bezmwofcmqgusfdxdepofrmqhujt \
  build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Если апстрим завёл новые места, которые не компилируются на старом Xcode — нужно расширить коммит-костыль. См. [XCODE-COMPAT.md](XCODE-COMPAT.md).

### ⚠️ Нюанс: релизный тег указывает на коммит ДО бампа версии

Маинтейнер ставит тег `vX.Y.Z` на коммит, где `MARKETING_VERSION` ещё **старая**, а бамп версии делает СЛЕДУЮЩИМ коммитом (он так и называется — «vX.Y.Z»). Если перебазироваться на сам тег — приложение в Settings покажет предыдущую версию (так мы один раз получили 3.0.0 вместо 3.0.1).

**Поэтому базу бери на бамп-коммит (`<тег>` + 1), а не на сам тег:**

```bash
git log --oneline <тег>..upstream/master | tail -1     # нижний коммит = бамп "vX.Y.Z"
git rebase --onto <bump-hash> <старая-база> local/build
git show local/build:Stats.xcodeproj/project.pbxproj | grep -m1 MARKETING_VERSION   # проверка: новая версия
```

### Мажорные апдейты — прямой rebase всего стека

Для крупных версий (например v2→v3) проще перебазировать `local/build` целиком одной командой, а feat-ветки подтянуть отдельно потом. **Бэкап обязательно:**

```bash
git branch backup/local-build-<старая-версия> local/build
git rebase --onto <новая-база> <старая-база> local/build
```

Фактический лог синков (что менялось, какие грабли) — в [SYNC-LOG.md](SYNC-LOG.md).

### Когда синк делает Claude — без `git rebase -i`

В среде Claude Code интерактивный rebase (`-i`) недоступен. Чтобы вложить правку в коммит-костыль (или любой не-HEAD коммит) **без `-i`** — через detached-amend + переналожение:

```bash
git checkout --detach <commit>                  # встаём на нужный коммит
# ... правим файлы ...
git commit --amend                              # вложили правку
git rebase --onto HEAD <commit> <старый-HEAD>   # переналожили всё, что было выше
git branch -f local/build HEAD && git switch local/build
```

### Деплой

Release-сборку с подписью и установку в `/Applications` (чтобы новая версия стала постоянной и работали датчики) — см. [SIGNING.md](SIGNING.md).

## Если апстрим сам реализует одну из твоих фич

Например, апстрим в каком-то релизе сделает split-bar I/O сам (issue #3233 был закрыт но мейнтейнер обещал нечто похожее). Тогда после `git rebase master`:

```bash
git checkout feat/personal-tweaks
git rebase -i master
```

В интерактивном rebase удали строку с устаревшим коммитом (или замени `pick` на `drop`). Если апстримная реализация конфликтует с твоей — придётся разрешать руками; обычно проще выбросить свою и принять апстримную.

## Правила-предохранители

1. **`local/build` зеркалится ТОЛЬКО в свой форк (`origin`) как бэкап и НИКОГДА не уходит в upstream / не служит источником upstream-PR.** На ветке лежит коммит-костыль «DO NOT MERGE» (regressions) + смена signing-идентичности — этому не место в PR апстриму. Upstream-PR'ы делаются cherry-pick'ом из `feat/*`-веток, не из `local/build`. Бэкап `origin/local/build` обновляется force-push'ем на синке (только `--force-with-lease`, не голый `--force`).

   > История правила: до 2026-06 формулировка была «вообще не пушить `local/build` в origin». На синке v3.0.4 смягчено — бэкап деплоимой ветки в **свой публичный форк** безопасен (PR'ы оттуда не делаются, SHA-1 серта и team-ID в `SIGNING.md` не секреты). Если надо именно снять с origin: `git push origin --delete local/build`.

2. **`master` пушится только после `--ff-only` merge с upstream**. Никогда не коммить туда напрямую.

3. **`feat/personal-tweaks` после ребейза требует `--force-with-lease`**. Это нормально (история переписалась), но никогда не используй просто `--force` без `--with-lease`.

4. **Коммит-костыль на `local/build` должен быть последним** (HEAD). Если съехал после новых коммитов — `git rebase -i` и переставь.

5. **Доку обновлять при структурных изменениях**. Если меняешь схему веток или добавляешь фичу — отрази здесь и в [FEATURES.md](FEATURES.md).
