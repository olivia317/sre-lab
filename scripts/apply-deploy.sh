#!/usr/bin/env bash
set -euo pipefail
umask 077

release_dir="${1:-}"
deploy_dir="/home/sre/sre-lab-build/v2.0"

if [[ "$EUID" -ne 0 ]]; then
  echo "请使用 sudo 执行。"
  exit 1
fi

# 只接受准备脚本生成的记录目录。
[[ "$release_dir" =~ ^/var/lib/sre-lab/releases/[A-Za-z0-9-]+$ ]]
[[ "$(cat "$release_dir/status")" == "prepared" ]]

# 同一时间只能执行一次部署。
exec 9>/var/lib/sre-lab/deploy.lock
flock -n 9 || { echo "已有部署正在执行。"; exit 1; }

target_image="$(cat "$release_dir/target-image-ref")"
target_id="$(cat "$release_dir/target-image-id")"
old_id="$(cat "$release_dir/previous-image-id")"
old_ref="$(cat "$release_dir/previous-image-ref")"

[[ "$target_image" =~ ^ghcr\.io/olivia317/sre-lab@sha256:[0-9a-f]{64}$ ]]

# 如果准备之后有人改过配置或更换了镜像，停止执行，重新准备。
cmp -s "$deploy_dir/compose.yaml" "$release_dir/compose.before.yaml" ||
  { echo "当前配置已变化，请重新执行准备脚本。"; exit 1; }

[[ "$(docker inspect --format '{{.Image}}' sre-app-dev)" == "$old_id" ]]
[[ "$(docker image inspect --format '{{.Id}}' "$old_ref")" == "$old_id" ]]
[[ "$(docker image inspect --format '{{.Id}}' "$target_image")" == "$target_id" ]]

# 本项目只有一个应用服务；将目标镜像写入持久化配置。
[[ "$(grep -cE '^[[:space:]]*image:' "$release_dir/compose.target.yaml")" == "1" ]]

sed -E "s|^([[:space:]]*image:).*|\1 \"$target_image\"|" \
  "$release_dir/compose.target.yaml" > "$release_dir/compose.deploy.yaml"

docker compose --project-directory "$deploy_dir" \
  -f "$release_dir/compose.deploy.yaml" config -q

compose() {
  docker compose --project-directory "$deploy_dir" \
    -f "$deploy_dir/compose.yaml" "$@"
}

check_db() {
  local url="$1"
  local code
  code="$(curl --silent --show-error --max-time 10 \
    --output /dev/null --write-out '%{http_code}' "$url")" || return 1
  [[ "$code" == "200" ]]
}

need_rollback=0

finish() {
  local rc=$?
  trap - EXIT

  if [[ "$need_rollback" == "1" ]]; then
    echo "部署未完成，保存日志并尝试回退。"
    compose logs --tail 80 app > "$release_dir/failed-app.log" 2>&1 || true

    if cp -a "$release_dir/compose.before.yaml" "$deploy_dir/compose.yaml" &&
       compose up -d --no-deps --pull never --wait --wait-timeout 120 app &&
       [[ "$(docker inspect --format '{{.Image}}' sre-app-dev)" == "$old_id" ]] &&
       check_db http://127.0.0.1:8001/api/servers &&
       check_db http://127.0.0.1/api/servers; then
      printf '%s\n' "rolled-back" > "$release_dir/status"
      echo "已回退，旧镜像和数据库接口验证通过。"
    else
      printf '%s\n' "rollback-failed" > "$release_dir/status"
      echo "自动回退未通过，请立即人工检查：$release_dir"
    fi
    rc=1
  fi

  exit "$rc"
}

trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s\n' "deploying" > "$release_dir/status"
need_rollback=1

# 临时文件写完后再替换正式配置。
cp "$release_dir/compose.deploy.yaml" "$deploy_dir/.compose.deploy.tmp"
mv "$deploy_dir/.compose.deploy.tmp" "$deploy_dir/compose.yaml"

compose up -d --no-deps --pull never --wait --wait-timeout 120 app

[[ "$(docker inspect --format '{{.Image}}' sre-app-dev)" == "$target_id" ]]
check_db http://127.0.0.1:8001/api/servers
check_db http://127.0.0.1/api/servers

printf '%s\n' "deployed" > "$release_dir/status"
need_rollback=0

echo "部署成功：$target_image"
echo "容器健康检查、镜像核对、直连及 Nginx 数据库接口检查通过。"