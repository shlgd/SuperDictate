#!/bin/bash

set -euo pipefail

REPOSITORY="${SUPERDICTATE_REPOSITORY:-shlgd/SuperDictate}"
RELEASE_VERSION="0.2.44"
RELEASE_SHA256="84c9909fa9887a630cfffdf78ae67d2b9692f8c9831c5d613ff0931b267e536e"
SOURCE_COMMIT="68e4c07c6ef5461133f790d975c6199f620b827b"
RELEASE_URL="${SUPERDICTATE_RELEASE_URL:-https://github.com/$REPOSITORY/releases/download/v$RELEASE_VERSION/SuperDictate.zip}"
EXPECTED_SHA256="${SUPERDICTATE_RELEASE_SHA256:-$RELEASE_SHA256}"
MODEL_RELEASE_SHA256="078cc5e085c9544324267d5c827a8441f22f1a3fa1d0c848d0d3e83f71091bfb"
MODEL_CONTENT_SHA256="66e79161c28717a7869b552453eab474975e801ba5dee28a964d79f952690dff"
MODEL_ASSET_NAME="SuperDictate-Model-v3.zip"
MODEL_RELEASE_URL="${SUPERDICTATE_MODEL_URL:-https://github.com/$REPOSITORY/releases/download/v$RELEASE_VERSION/$MODEL_ASSET_NAME}"
EXPECTED_MODEL_SHA256="${SUPERDICTATE_MODEL_SHA256:-$MODEL_RELEASE_SHA256}"
MODEL_CACHE_DIR="${SUPERDICTATE_MODEL_DIR:-$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3}"
REF="${SUPERDICTATE_REF:-$SOURCE_COMMIT}"
EXPECTED_SOURCE_COMMIT="${SUPERDICTATE_SOURCE_COMMIT:-$SOURCE_COMMIT}"
APP_PATH="${SUPERDICTATE_APP_PATH:-/Applications/SuperDictate.app}"
BUILD_FROM_SOURCE="${SUPERDICTATE_BUILD_FROM_SOURCE:-0}"
NO_OPEN="${SUPERDICTATE_NO_OPEN:-0}"
SKIP_MODEL_INSTALL="${SUPERDICTATE_SKIP_MODEL_INSTALL:-0}"
AGENT_LABEL="com.local.superdictate.agent"

say() {
    printf '\033[1;36mSuperDictate:\033[0m %s\n' "$*"
}

fail() {
    printf '\033[1;31mSuperDictate:\033[0m %s\n' "$*" >&2
    exit 1
}

download_with_progress() {
    local label="$1"
    local url="$2"
    local output="$3"

    say "$label"
    curl --fail --location --show-error --progress-bar \
        --retry 3 --retry-delay 1 --retry-all-errors \
        --connect-timeout 20 --speed-limit 1024 --speed-time 60 \
        "$url" \
        -o "$output"
}

version_at_least_14() {
    local major
    major="$(sw_vers -productVersion | cut -d. -f1)"
    [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 14 ))
}

is_apple_silicon() {
    local machine translated

    machine="$(/usr/bin/uname -m)"
    [[ "$machine" == "arm64" ]] && return 0

    # A shell launched through Rosetta reports x86_64 even on Apple
    # Silicon. Apple exposes this flag specifically for that case.
    translated="$(/usr/sbin/sysctl -in sysctl.proc_translated 2>/dev/null || true)"
    [[ "$machine" == "x86_64" && "$translated" == "1" ]]
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

    download_with_progress "Скачиваю SuperDictate $RELEASE_VERSION..." "$RELEASE_URL" "$archive"

    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    [[ "$actual" == "$EXPECTED_SHA256" ]] || fail "Контрольная сумма загрузки не совпала."

    ditto -x -k "$archive" "$work_dir/release"
    [[ -d "$work_dir/release/SuperDictate.app" ]] || fail "В релизе нет SuperDictate.app."
    ditto "$work_dir/release/SuperDictate.app" "$work_dir/SuperDictate.app"
}

model_content_sha256() {
    local model_dir="$1"
    local file_manifest="$WORK_DIR/model-files.sha256"
    local file_count

    [[ -d "$model_dir" && ! -L "$model_dir" ]] || return 1
    for required in \
        Decoder.mlmodelc \
        Encoder.mlmodelc \
        JointDecisionv3.mlmodelc \
        Preprocessor.mlmodelc; do
        [[ -d "$model_dir/$required" && ! -L "$model_dir/$required" ]] || return 1
    done
    [[ -f "$model_dir/parakeet_vocab.json" && ! -L "$model_dir/parakeet_vocab.json" ]] || return 1

    if find \
        "$model_dir/Decoder.mlmodelc" \
        "$model_dir/Encoder.mlmodelc" \
        "$model_dir/JointDecisionv3.mlmodelc" \
        "$model_dir/Preprocessor.mlmodelc" \
        ! -type d ! -type f -print -quit | grep -q .; then
        return 1
    fi

    (
        cd "$model_dir"
        {
            find \
                Decoder.mlmodelc \
                Encoder.mlmodelc \
                JointDecisionv3.mlmodelc \
                Preprocessor.mlmodelc \
                -type f -print
            printf '%s\n' parakeet_vocab.json
        } | LC_ALL=C sort | while IFS= read -r model_file; do
            /usr/bin/shasum -a 256 "$model_file"
        done
    ) > "$file_manifest" || return 1

    file_count="$(wc -l < "$file_manifest" | tr -d '[:space:]')"
    [[ "$file_count" == "21" ]] || return 1
    /usr/bin/shasum -a 256 "$file_manifest" | awk '{print $1}'
}

verify_model_directory() {
    local model_dir="$1"
    local actual

    actual="$(model_content_sha256 "$model_dir")" || return 1
    [[ "$actual" == "$MODEL_CONTENT_SHA256" ]]
}

assert_sufficient_model_disk_space() {
    local available_kb
    local required_kb=$((2 * 1024 * 1024))

    available_kb="$(df -Pk "$HOME" | awk 'END {print $4}')"
    if [[ "$available_kb" =~ ^[0-9]+$ ]] && (( available_kb < required_kb )); then
        fail "Для безопасной установки модели нужно не менее 2 ГБ свободного места."
    fi
}

validate_model_cache_path() {
    local parent

    [[ "$(basename "$MODEL_CACHE_DIR")" == "parakeet-tdt-0.6b-v3" ]] || \
        fail "Небезопасный путь установки модели: $MODEL_CACHE_DIR"
    parent="$(dirname "$MODEL_CACHE_DIR")"
    [[ "$MODEL_CACHE_DIR" != "/" && "$parent" != "/" && "$parent" != "$HOME" ]] || \
        fail "Небезопасный путь установки модели: $MODEL_CACHE_DIR"
}

install_model_atomically() {
    local source_dir="$1"
    local parent incoming backup

    validate_model_cache_path
    parent="$(dirname "$MODEL_CACHE_DIR")"
    incoming="$parent/.parakeet-tdt-0.6b-v3.incoming.$$"
    backup="$parent/.parakeet-tdt-0.6b-v3.previous.$$"

    mkdir -p "$parent"
    rm -rf "$incoming" "$backup"
    ditto "$source_dir" "$incoming"
    verify_model_directory "$incoming" || fail "Распакованная модель не прошла проверку файлов."

    if [[ -e "$MODEL_CACHE_DIR" ]]; then
        mv "$MODEL_CACHE_DIR" "$backup"
    fi
    if ! mv "$incoming" "$MODEL_CACHE_DIR"; then
        if [[ -e "$backup" ]]; then
            mv "$backup" "$MODEL_CACHE_DIR"
        fi
        fail "Не удалось установить модель; предыдущая копия восстановлена."
    fi
    rm -rf "$backup"
}

ensure_speech_model() {
    local work_dir="$1"
    local archive="$work_dir/$MODEL_ASSET_NAME"
    local extracted="$work_dir/model-release"
    local source_dir="$extracted/parakeet-tdt-0.6b-v3"
    local actual

    if [[ "$SKIP_MODEL_INSTALL" == "1" ]]; then
        say "Тестовый режим: установка модели пропущена."
        return
    fi

    say "Проверяю локальную модель распознавания..."
    if verify_model_directory "$MODEL_CACHE_DIR"; then
        say "Модель уже установлена и проверена — повторная загрузка не нужна."
        return
    fi

    assert_sufficient_model_disk_space
    download_with_progress \
        "Скачиваю локальную модель с GitHub (около 460 МБ)..." \
        "$MODEL_RELEASE_URL" \
        "$archive"
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    [[ "$actual" == "$EXPECTED_MODEL_SHA256" ]] || fail "Контрольная сумма модели не совпала."

    say "Проверяю и устанавливаю локальную модель..."
    mkdir -p "$extracted"
    ditto -x -k "$archive" "$extracted"
    [[ -d "$source_dir" ]] || fail "В архиве нет каталога модели parakeet-tdt-0.6b-v3."
    verify_model_directory "$source_dir" || fail "Файлы модели не прошли проверку целостности."
    install_model_atomically "$source_dir"
    say "Модель установлена. При запуске повторное скачивание не потребуется."
}

verify_source_ref() {
    local actual

    [[ "$EXPECTED_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "Ожидался полный 40-символьный SHA исходников."

    actual="$(curl --fail --location --silent --show-error --retry 3 --retry-delay 1 --retry-all-errors \
        "https://api.github.com/repos/$REPOSITORY/commits/$REF" \
        | sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' \
        | head -n 1)"

    [[ -n "$actual" ]] || fail "Не удалось проверить коммит исходников $REF."
    [[ "$actual" == "$EXPECTED_SOURCE_COMMIT" ]] || fail "Коммит исходников не совпал: ожидался $EXPECTED_SOURCE_COMMIT, получен $actual."
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

    say "Проверяю закреплённый коммит исходного кода..."
    verify_source_ref

    say "Скачиваю открытый исходный код..."
    curl --fail --location --silent --show-error --retry 3 --retry-delay 1 --retry-all-errors \
        "https://github.com/$REPOSITORY/archive/$REF.zip" \
        -o "$work_dir/source.zip"
    ditto -x -k "$work_dir/source.zip" "$work_dir/source"
    source_dir="$(find "$work_dir/source" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [[ -n "$source_dir" ]] || fail "Не удалось распаковать исходный код."
    "$source_dir/scripts/build-app.sh" "$work_dir/SuperDictate.app"
}

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "Работает только на macOS."
is_apple_silicon || fail "Нужен Mac с Apple Silicon (M1 или новее)."
version_at_least_14 || fail "Нужна macOS 14 или новее."

for command_name in curl ditto shasum plutil file codesign sed head; do
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
if [[ -d "$APP_PATH" ]]; then
    codesign --verify --deep --strict "$APP_PATH" || fail "Подпись установленного приложения повреждена. Обновление остановлено."
    signing_details="$(codesign -dv "$APP_PATH" 2>&1)" || fail "Не удалось проверить прежнюю подпись."
    if ! printf '%s\n' "$signing_details" | grep -q '^Signature=adhoc$'; then
        requirement="$(codesign -d -r- "$APP_PATH" 2>&1 | sed -n 's/^designated => //p')"
        [[ -n "$requirement" ]] || fail "Не удалось определить прежнюю подпись."
        codesign --verify --deep --strict "-R=$requirement" "$WORK_DIR/SuperDictate.app" \
            || fail "Подпись обновления отличается. Чтобы не потерять разрешения macOS, текущая версия сохранена."
    else
        say "Установлена старая ad-hoc-сборка. При переходе на постоянную подпись macOS может один раз запросить права заново."
    fi
fi
ensure_speech_model "$WORK_DIR"
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
    printf '\n1. Нажмите «Разрешить» для микрофона, универсального доступа и мониторинга ввода.\n'
    printf '2. Дождитесь подготовки Neural Engine и статуса «Работает» — модель уже установлена.\n'
    printf '3. Нажмите правый Command и начинайте говорить.\n\n'
fi
