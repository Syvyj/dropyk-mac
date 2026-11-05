<img src="docs/banner-uk.png" alt="Dropyk для Mac — файли з Android-телефона на Mac через Quick Share">

[English](README.md) · **Українська**

Приймайте файли з Android-телефонів на Mac через Quick Share. Dropyk живе в рядку меню й зберігає файли в «Завантаження».

**[Завантажити для macOS](https://github.com/Syvyj/dropyk-mac/releases/latest/download/Dropyk.zip)** · **[Сайт](https://dropyk.syvyj.dev/uk/)** · **[Встановлення](#встановлення)**

`macOS 12+` `Wi‑Fi LAN` `Unlicense`

Dropyk — це форк [NearDrop](https://github.com/grishka/NearDrop) від Grishka: він розібрав протокол Quick Share і написав майже весь код. Див. [опис протоколу](PROTOCOL.md). Щоб надсилати на телевізор, є [Dropyk для Android TV](https://github.com/Syvyj/dropyk-android).

## Чим відрізняється від NearDrop

- **Автоприйом.** Перемикач у меню, *Accept transfers automatically*, прибирає підтвердження для кожної передачі. Приймає від будь-кого в мережі, тож вмикайте лише в мережі, якій довіряєте. За замовчуванням вимкнений.
- **Кілька файлів — в окрему теку.** Передача з кількох файлів зберігається в `~/Downloads/<ім'я пристрою> <дата час>/`, і після завершення тека відкривається у Finder. Один файл, як і раніше, йде просто в «Завантаження».
- **Власна назва, іконка й bundle ID** (`com.dokboss.Dropyk`). Не запускайте разом із NearDrop: в мережі з'являться обидва.
- **macOS 12 або новіша**, бо сучасний Xcode більше не збирає для 10.15.

## Встановлення

1. Завантажте [`Dropyk.zip`](https://github.com/Syvyj/dropyk-mac/releases/latest/download/Dropyk.zip), розпакуйте й перенесіть `Dropyk.app` в «Програми».
2. Застосунок не підписаний сертифікатом Apple Developer ID, тож уперше клацніть на ньому правою кнопкою, виберіть **Відкрити** й підтвердьте. Або виконайте `xattr -dr com.apple.quarantine /Applications/Dropyk.app`.
3. Коли macOS спитає, дозвольте Dropyk **знаходити пристрої в локальній мережі** — без цього телефони не побачать Mac — і показувати **сповіщення**.
4. Щоб запускався разом із Mac: Системні параметри → Загальні → Об'єкти входу → додайте Dropyk.

На телефоні: Поділитися → Quick Share і виберіть свій Mac. Телефон і Mac мають бути в одній Wi‑Fi-мережі.

## Обмеження

Ті самі, що в NearDrop:

- **Лише Wi‑Fi у локальній мережі.** Wi‑Fi Direct, Bluetooth та інші способи, які використовує Google, не підтримуються.
- **Видно всім у вашій мережі**, поки застосунок запущений.

## Збірка

```
xcodebuild -project NearDrop.xcodeproj -scheme NearDrop -configuration Release -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
cp -R build/Build/Products/Release/Dropyk.app /Applications/
```

Банери для README робить [`docs/banner.html`](docs/banner.html): `docs/render-banners.sh` (потрібен Google Chrome).

## Ліцензія

[Unlicense](UNLICENSE), як і в NearDrop.

## Підтримати автора

Dropyk безкоштовний і таким лишиться. [Банка Monobank](https://send.monobank.ua/jar/5juJPj142b) · [Ko-fi](https://ko-fi.com/syvyj) · [Buy Me a Coffee](https://buymeacoffee.com/syvyj)
