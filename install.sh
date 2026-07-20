#!/bin/bash

set -euo pipefail

REPOSITORY="shlgd/SuperDictate"
RELEASE_VERSION="0.2.31"
RELEASE_SHA256="d9065b55cd2a2b4ef6b2471fd2afb31a9fa524dd21d099e99b8441f6e9d1c2ce"
RELEASE_URL="${SUPERDICTATE_RELEASE_URL:-https://github.com/$REPOSITORY/releases/download/v$RELEASE_VERSION/SuperDictate.zip}"
EXPECTED_SHA256="${SUPERDICTATE_RELEASE_SHA256:-$RELEASE_SHA256}"
REF="${SUPERDICTATE_REF:-main}"
APP_PATH="${SUPERDICTATE_APP_PATH:-/Applications/SuperDictate.app}"
BUILD_FROM_SOURCE="${SUPERDICTATE_BUILD_FROM_SOURCE:-0}"
NO_OPEN="${SUPERDICTATE_NO_OPEN:-0}"
AGENT_LABEL="com.local.superdictate.agent"

say() {
    printf '\033[1;36mSuperDictate:\033[0m %s\n' "$*"
}

fail() {
    printf '\033[1;31mSuperDictate:\033[0m %s\n' "$*" >&2
    exit 1
}

version_at_least_14() {
    local major
    major="$(sw_vers -productVersion | cut -d. -f1)"
    [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 14 ))
}

run_as_admin() {
    if [[ -w "$(dirname "$APP_PATH")" ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

verify_app() {
    local app="$1"
    local executable="$app/Contents/MacOS/SuperDictate"
    local bundle_id version minimum_system entitlements_file audio_input microphone

    [[ -x "$executable" ]] || fail "В архиве нет исполняемого файла SuperDictate."
    bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")"
    [[ "$bundle_id" == "com.local.superdictate" ]] || fail "Неверный идентификатор приложения: $bundle_id"
    version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
    [[ "$version" == "$RELEASE_VERSION" ]] || fail "Ожидалась версия $RELEASE_VERSION, получена $version."
    minimum_system="$(plutil -extract LSMinimumSystemVersion raw -o - "$app/Contents/Info.plist")"
    [[ "$minimum_system" == "14.0" ]] || fail "Неожиданная минимальная версия macOS: $minimum_system"
    file "$executable" | grep -q 'arm64' || fail "Сборка не предназначена для Apple Silicon."
    codesign --verify --deep --strict "$app" || fail "Проверка подписи приложения не прошла."
    entitlements_file="$WORK_DIR/verified-entitlements.plist"
    codesign -d --entitlements :- "$app" > "$entitlements_file" 2>/dev/null
    audio_input="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$entitlements_file")"
    microphone="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.microphone' "$entitlements_file")"
    [[ "$audio_input" == "true" && "$microphone" == "true" ]] || fail "В сборке отсутствуют разрешения микрофона."
}

download_release() {
    local work_dir="$1"
    local archive="$work_dir/SuperDictate.zip"
    local actual

    say "Скачиваю готовую сборку $RELEASE_VERSION..."
    curl --fail --location --silent --show-error --retry 3 --retry-delay 1 --retry-all-errors \
        "$RELEASE_URL" \
        -o "$archive"

    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    [[ "$actual" == "$EXPECTED_SHA256" ]] || fail "Контрольная сумма загрузки не совпала."

    ditto -x -k "$archive" "$work_dir/release"
    [[ -d "$work_dir/release/SuperDictate.app" ]] || fail "В релизе нет SuperDictate.app."
    ditto "$work_dir/release/SuperDictate.app" "$work_dir/SuperDictate.app"
}

build_from_source() {
    local work_dir="$1"
    local source_dir

    command -v swift >/dev/null 2>&1 || {
        say "Для сборки из исходников нужны бесплатные инструменты Apple. Открываю их установку..."
        xcode-select --install >/dev/null 2>&1 || true
        printf '\nПосле установки снова запустите ту же команду.\n'
        exit 0
    }

    say "Скачиваю открытый исходный код..."
    curl --fail --location --silent --show-error --retry 3 --retry-delay 1 --retry-all-errors \
        "https://github.com/$REPOSITORY/archive/$REF.zip" \
        -o "$work_dir/source.zip"
    ditto -x -k "$work_dir/source.zip" "$work_dir/source"
    source_dir="$(find "$work_dir/source" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [[ -n "$source_dir" ]] || fail "Не удалось распаковать исходный код."
    "$source_dir/scripts/build-app.sh" "$work_dir/SuperDictate.app"
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Работает только на macOS."
[[ "$(uname -m)" == "arm64" ]] || fail "Нужен Mac с Apple Silicon (M1 или новее)."
version_at_least_14 || fail "Нужна macOS 14 или новее."

for command_name in curl ditto shasum plutil file codesign; do
    command -v "$command_name" >/dev/null 2>&1 || fail "Не найдена системная команда: $command_name"
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/superdictate-install.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ "$BUILD_FROM_SOURCE" == "1" ]]; then
    build_from_source "$WORK_DIR"
else
    download_release "$WORK_DIR"
fi

verify_app "$WORK_DIR/SuperDictate.app"
say "Устанавливаю приложение в $APP_PATH..."

if [[ "$APP_PATH" == "/Applications/SuperDictate.app" ]]; then
    /bin/launchctl bootout "gui/$UID/$AGENT_LABEL" >/dev/null 2>&1 || true
    /usr/bin/pkill -x SuperDictate >/dev/null 2>&1 || true
fi

INCOMING="$(dirname "$APP_PATH")/.SuperDictate.install.$$"
BACKUP="$(dirname "$APP_PATH")/.SuperDictate.previous.$$"
run_as_admin rm -rf "$INCOMING"
run_as_admin rm -rf "$BACKUP"
run_as_admin ditto "$WORK_DIR/SuperDictate.app" "$INCOMING"
verify_app "$INCOMING"

if [[ -e "$APP_PATH" ]]; then
    run_as_admin mv "$APP_PATH" "$BACKUP"
fi
if ! run_as_admin mv "$INCOMING" "$APP_PATH"; then
    if [[ -e "$BACKUP" ]]; then
        run_as_admin mv "$BACKUP" "$APP_PATH"
    fi
    fail "Не удалось заменить приложение; предыдущая версия восстановлена."
fi

verify_app "$APP_PATH"
run_as_admin rm -rf "$BACKUP"

if [[ "$NO_OPEN" == "1" ]]; then
    say "Готово. Проверенная сборка установлена."
else
    say "Готово. Открываю SuperDictate..."
    open "$APP_PATH"
    printf '\n1. Нажмите Grant для Microphone, Accessibility и Input Monitoring.\n'
    printf '2. Дождитесь загрузки локальной модели и статуса Ready.\n'
    printf '3. Нажмите правый Command и начинайте говорить.\n\n'
fi
