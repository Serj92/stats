# Подпись и деплой

Как собрать **Release** под личным сертификатом и поставить в `/Applications`, чтобы работали все модули включая Sensors (датчики).

## Сертификат и Team ID — ВАЖНО, не перепутать

- Локальная подпись — личным сертификатом **«Apple Development: seregaijko@gmail.com»**, SHA-1 `431DDD8EC0F96883FB8F26B7404510F9CE69102D`.
- ⚠️ **Team ID = `T5V6W6793A`.** Это `organizationalUnitName` (OU) сертификата, оно же `TeamIdentifier` подписанного бинаря и значение `subject.OU` в codesign-требованиях.
- ⚠️ **`88FBB4GZ5S` — это НЕ team.** Это individual-id внутри `commonName` сертификата (`Apple Development: seregaijko@gmail.com (88FBB4GZ5S)`). Очень легко принять скобки за team — **не путать**. (Однажды уже перепутали и сломали SMC — см. [SYNC-LOG.md](SYNC-LOG.md).)
- Проверить реальный OU:
  ```bash
  security find-certificate -a -p -c "Apple Development: seregaijko@gmail.com" \
    | openssl x509 -noout -subject -nameopt multiline
  # organizationalUnitName = T5V6W6793A   ← вот это team
  # commonName = Apple Development: ... (88FBB4GZ5S)   ← скобки = individual-id, НЕ team
  ```

## Где зашит Team ID (3 места — коммит «switch signing identity»)

| Файл | Ключ | Что значит |
|---|---|---|
| `Stats/Supporting Files/Info.plist` | `SMPrivilegedExecutables` | приложение требует, чтобы SMC-хелпер был подписан этим OU |
| `Stats/Supporting Files/Info.plist` | `TeamId` | team приложения |
| `SMC/Helper/Info.plist` | `SMAuthorizedClients` | хелпер требует, чтобы клиент-приложение было подписано этим OU |

Все три — `... certificate leaf[subject.OU] = T5V6W6793A`. **Должны совпадать с реальной подписью**, иначе привилегированный SMC-хелпер не регистрируется и **модуль Sensors (температура / кулеры / питание) не работает** (остальное — CPU/RAM/Disk/Net/GPU/батарея — работает и без хелпера).

(Проект в build-настройках `project.pbxproj` всё ещё на апстримном `DEVELOPMENT_TEAM = RP2S87B72W` — мы перебиваем его флагом при сборке.)

## ✅ Принятая миграция: SMC `SMJobBless` → `SMAppService.daemon` (upstream #3237, взято с v3.0.4)

В **v3.0.2** апстрим перевёл установку SMC-хелпера со старого `SMJobBless` на новый `SMAppService.daemon` (коммит `e6b4c044`). До v3.0.4 мы этот коммит **сознательно пропускали**; **на синке v3.0.4 (2026-06-24) — взяли как есть**. Ниже: что это, почему развернули решение и что проверили в сборке.

**Что это.** Меняется только **механизм установки** привилегированного хелпера, не функциональность. Старый API (`SMJobBless`) задепрекейчен в macOS 13. Новый путь активен на macOS 13+, legacy остаётся под `else` для < 13.

**Почему развернули «не брать» → «взять».** План от 14.06 был «синкать всё, кроме #3237» в расчёте, что коммит самодостаточен. На деле при синке v3.0.4 оказалось, что **#3237 переплетён с поздними коммитами релиза**: редизайны попапов (`93fa5820`, `7654330b`, `fc8e77c6`) и фикс optional'ов (`f5f25f29`) правят те же `Kit/helpers.swift` и `Modules/Sensors/popup.swift`. Чистый `git revert e6b4c044` поверх v3.0.4 даёт **битый полу-откат**: plist удаляется, но `SMAppService`-вызовы в `helpers.swift` и build-phase «Copy LaunchDaemons» в pbxproj остаются → не собирается. Альтернатива — ручная хирургия, оставляющая постоянный кастомный дельта в подписи-чувствительных файлах (тот самый «дрейф форка»). Вывод: дешевле и чище **взять миграцию целиком**.

**Почему для нас это безопасно.** Хелпер нужен **только для управления кулерами** (запись оборотов в SMC). Чтение датчиков (температура/питание/сенсоры) идёт **без** хелпера — см. таблицу выше. Кулерами мы не управляем → `SMAppService.register()` у нас вообще не дёргается (срабатывает только при установке хелпера, т.е. при включении управления кулерами). Если когда-нибудь понадобится: на не-нотаризованной Development-сборке регистрация может повиснуть в `.requiresApproval` — включать вручную в System Settings → Login Items.

**Что миграция привнесла (теперь в нашей сборке).**
- Build phase **«Copy LaunchDaemons»** → кладёт `eu.exelban.Stats.SMC.Helper.plist` в `Contents/Library/LaunchDaemons/` (в plist: `Label`, `BundleProgram` на хелпер в `LaunchServices/`, `MachServices`, `AssociatedBundleIdentifiers = eu.exelban.Stats`).
- `Kit/helpers.swift` — `SMCHelper.install/isInstalled/uninstall/checkForUpdate` получили ветку `#available(macOS 13)` на `SMAppService.daemon(plistName:)`; legacy-код (`SMJobBless` + `AuthorizationCreate`) уехал в `installLegacy`/`legacyIsInstalled`.
- `Modules/Sensors/popup.swift`, `settings.swift` — мелкие правки под новый статус.

**Проверено в Release-сборке v3.0.4 (sanity-check прошёл).**
- `LaunchDaemons/…Helper.plist` — это только манифест; `BundleProgram` ссылается на хелпер в `Contents/Library/LaunchServices/`, отдельного бинаря для подписи нет.
- Все **3 team-ID места** (`SMPrivilegedExecutables` / app `TeamIdentifier` / хелпер) = `T5V6W6793A` → датчики работают.
- Сборка под Xcode 16.0 потребовала ровно одну новую trailing-comma правку (`Kit/plugins/SystemStats.swift`, см. [XCODE-COMPAT.md](XCODE-COMPAT.md) №5).

## Release-сборка

```bash
xcodebuild -project Stats.xcodeproj -scheme Stats -configuration Release \
  -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=431DDD8EC0F96883FB8F26B7404510F9CE69102D \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=88FBB4GZ5S PROVISIONING_PROFILE_SPECIFIER="" build
```

- `CODE_SIGN_IDENTITY` — обязательно **SHA-1, не строка** (`"Apple Development"` Xcode мапит в несуществующий «Mac Development» и падает).
- `CODE_SIGN_STYLE=Manual` — `Automatic` триггерит ту же «Mac Development» ошибку.
- `DEVELOPMENT_TEAM=88FBB4GZ5S` здесь безвреден: manual-подпись берёт явный SHA, чья подпись всё равно даёт OU `T5V6W6793A`. (Менять на `T5V6W6793A` не обязательно — собирается и так.)
- `build/` в `.gitignore` — артефакты не засоряют репозиторий.

## Проверка перед деплоем (sanity-check)

OU в требовании Info.plist должно **совпадать** с `TeamIdentifier` подписи приложения И хелпера:

```bash
REL=build/Build/Products/Release/Stats.app
/usr/libexec/PlistBuddy -c "Print :SMPrivilegedExecutables:eu.exelban.Stats.SMC.Helper" "$REL/Contents/Info.plist"   # ... subject.OU] = T5V6W6793A
codesign -dvvv "$REL" 2>&1 | grep TeamIdentifier                                                                     # T5V6W6793A
codesign -dvvv "$REL/Contents/Library/LaunchServices/eu.exelban.Stats.SMC.Helper" 2>&1 | grep TeamIdentifier         # T5V6W6793A
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$REL/Contents/Info.plist"                             # версия
```

Все три OU = `T5V6W6793A` → датчики заработают. Различаются → Sensors сломается.

## Деплой в /Applications

```bash
osascript -e 'quit app "Stats"'
mv /Applications/Stats.app /tmp/Stats-backup.app          # /Applications юзер-писабелен, sudo не нужен
ditto build/Build/Products/Release/Stats.app /Applications/Stats.app
open /Applications/Stats.app
```

- При **первом запуске** свежего билда macOS попросит **админ-пароль** для (пере)установки привилегированного SMC-хелпера — авторизовать вручную, скриптом нельзя.
- **Откат:** `mv /tmp/Stats-backup.app /Applications/Stats.app` (предварительно убив запущенную копию).
- login-item запускает именно `/Applications/Stats.app`, так что после деплоя постоянной станет новая версия.

## Debug-сборка только для проверки компиляции (без подписи)

Когда нужно лишь «собирается ли под Xcode 16.0» — быстрая ad-hoc сборка, **без датчиков**:

```bash
xcodebuild -project Stats.xcodeproj -scheme Stats -configuration Debug \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/Stats-bezmwofcmqgusfdxdepofrmqhujt \
  build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```
