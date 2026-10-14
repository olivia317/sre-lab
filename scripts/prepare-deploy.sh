#!/usr/bin/env bash
set -euo pipefail
umask 077

# 参数：这次准备部署的镜像，必须使用确定的摘要。
target_image="${1:-}"
if [[ ! "$target_image" =~ ^ghcr\.io/olivia317/sre-lab@sha256:[0-9a-f]{64}$ ]]; then
  echo "用法：sudo bash prepare-deploy.sh ghcr.io/olivia317/sre-lab@sha256:<64位摘要>"
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "请使用 sudo 执行。"
  exit 1
fi

deploy_dir="/home/sre/sre-lab-build/v2.0"
cd "$deploy_dir"

# 检查目标镜像代入配置后，配置是否合法。
APP_IMAGE="$target_image" \
  docker compose -f compose.parameterized.yaml config -q

# 记录正式容器实际使用的旧镜像，而不是凭文件推测。
old_image_id="$(docker inspect --format '{{.Image}}' sre-app-dev)"
old_image_ref="$(docker inspect --format '{{.Config.Image}}' sre-app-dev)"
running="$(docker inspect --format '{{.State.Running}}' sre-app-dev)"

if [[ "$running" != "true" ]]; then
  echo "正式容器当前未运行，停止准备，请先检查业务。"
  exit 1
fi

docker image inspect "$old_image_id" >/dev/null

echo "当前镜像：$old_image_ref"
echo "目标镜像：$target_image"

# 下载失败时，脚本会停止，正式容器不受影响。
docker pull "$target_image"
target_image_id="$(docker image inspect --format '{{.Id}}' "$target_image")"

# 每次准备使用独立目录，避免覆盖之前的记录。
mkdir -p /var/lib/sre-lab/releases
release_dir="$(mktemp -d "/var/lib/sre-lab/releases/$(date +%Y%m%d-%H%M%S)-XXXXXX")"

cp compose.yaml "$release_dir/compose.before.yaml"
cp compose.parameterized.yaml "$release_dir/compose.target.yaml"

printf '%s\n' "$old_image_ref" > "$release_dir/previous-image-ref"
printf '%s\n' "$old_image_id" > "$release_dir/previous-image-id"
printf '%s\n' "$target_image" > "$release_dir/target-image-ref"
printf '%s\n' "$target_image_id" > "$release_dir/target-image-id"
printf '%s\n' "prepared" > "$release_dir/status"

echo "准备完成，记录目录：$release_dir"
echo "本脚本尚未切换正式容器。"