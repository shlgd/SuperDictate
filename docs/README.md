<div align="center">

# 🎙️ SuperDictate

**Быстрая, локальная и приватная голосовая диктовка для macOS на Apple Silicon.**

[![Swift](https://img.shields.io/badge/Swift-5.10%2B-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-macOS-007ACC?style=flat-square&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![CoreML](https://img.shields.io/badge/CoreML-Apple%20Silicon-FF6F00?style=flat-square&logo=apple&logoColor=white)](https://developer.apple.com/documentation/coreml)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014%2B%20(Apple%20Silicon)-000000?style=flat-square&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](../LICENSE)

[Возможности](#-ключевые-возможности) • [Установка](#-быстрая-установка) • [Горячие клавиши](#-горячие-клавиши) • [Сборка](#-сборка-из-исходников) • [English Version](README.en.md)

</div>

---

## 📌 Обзор

**SuperDictate** — нативное приложение для транскрибации речи в текст (Speech-to-Text) для macOS. Распознавание работает полностью на устройстве через **Apple Neural Engine (ANE)** на базе оптимизированных CoreML-моделей Whisper, без облака и задержек.

---

## ✨ Ключевые возможности

- 🔒 **100% On-Device и Приватно:** Аудиопоток не покидает Mac. Без сторонних серверов, аналитики и телеметрии.
- ⚡ **Мгновенный отклик (< 0.2 мс):** Кэш Fast Fingerprint исключает задержки инициализации модели.
- 🌊 **ProMotion 120 Гц UI:** Плавающая капсула записи с аппаратной анимацией звуковой волны.
- 🌍 **Мультиязычность:** Распознавание русской, английской и других языковых дорожек с автоопределением.
- 🔋 **Оптимизация под 8 ГБ+ RAM:** Эффективный менеджмент буферов инференса и минимальный расход батареи.
- ⌨️ **Глобальный Push-to-Talk:** Удержание или нажатие глобальной клавиши для ввода текста в любое активное приложение.

---

## 🚀 Быстрая установка

### Требования
- Mac с процессором **Apple Silicon** (от M1 или A18 Pro).
- **macOS 14 (Sonoma)** или новее.

```bash
curl -fsSL https://raw.githubusercontent.com/shlgd/SuperDictate/main/install.sh | /usr/bin/arch -arm64 /bin/bash
```

1. Запустите SuperDictate и выдайте системные разрешения: **Микрофон**, **Универсальный доступ** и **Мониторинг ввода**.
2. Нажмите **Правый Command** и говорите. Нажмите его еще раз для вставки текста.

---

## ⌨️ Горячие клавиши

| Действие | Горячая клавиша | Поведение |
| :--- | :--- | :--- |
| **Push-to-Talk** | `Правый ⌘ (Удержание)` | Запись при удержании, вставка при отпускании |
| **Режим переключения** | `Правый ⌘ (Клик)` | Клик для старта, второй клик для вставки |
| **Отмена записи** | `Escape` | Сброс записи без вставки |

---

## 🛠️ Сборка из исходников

```bash
# Клонировать репозиторий
git clone https://github.com/m0rvey/SuperDictate.git
cd SuperDictate

# Сборка через Swift Package Manager
swift build -c release
```

---

## 📄 Лицензия

Распространяется под лицензией **MIT**. Подробнее см. [LICENSE](../LICENSE).  
Оригинальная кодовая база создана [shlgd](https://github.com/shlgd/SuperDictate).
