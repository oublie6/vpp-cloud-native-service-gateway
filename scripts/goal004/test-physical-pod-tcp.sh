#!/usr/bin/env bash
# 在现有两个 Ready 节点上验证 Pod IPv4 和 TCP，退出时删除本脚本创建的资源。
set -Eeuo pipefail

(( EUID == 0 )) || { printf '需要 root\n' >&2; exit 1; }
source /etc/goal004-worker-tcp.env
remote_host=${GOAL004_REMOTE_HOST:?}
askpass=${GOAL004_SSH_ASKPASS:?}
known_hosts=${GOAL004_KNOWN_HOSTS:?}
remote_user=${GOAL004_REMOTE_USER:-root}
local_node=${GOAL004_LOCAL_NODE_NAME:-hk-worker}
remote_node=${GOAL004_REMOTE_NODE_NAME:-ser730417996259}
namespace=goal004-tcp-check
created=false

remote_ssh() {
  env DISPLAY=:0 SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$askpass" setsid -w ssh \
    -o ConnectTimeout=8 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    "$remote_user@$remote_host" "$@"
}
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$created" == true ]]; then
    remote_ssh "kubectl delete namespace $namespace --wait=true --timeout=120s" || status=1
  fi
  printf 'Goal 004 Pod TCP cleanup status=%s\n' "$status"
  exit "$status"
}
trap cleanup EXIT

systemctl is-active --quiet goal004-worker-tcp-link || { printf 'TCP 节点链路未运行\n' >&2; exit 1; }
[[ $(ip route show exact "${GOAL004_REMOTE_NODE_IP:?}/32") == *' dev tun3 '* ]] || {
  printf '远端 Node IP 未经 tun3 路由\n' >&2; exit 1;
}
remote_ssh "! kubectl get namespace $namespace >/dev/null 2>&1" || {
  printf 'namespace %s 已存在，拒绝覆盖\n' "$namespace" >&2; exit 1;
}
remote_ssh "kubectl create namespace $namespace"
created=true
remote_ssh 'kubectl apply -f -' <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: us-server
  namespace: $namespace
spec:
  nodeName: $remote_node
  restartPolicy: Never
  containers:
    - name: server
      image: busybox:1.36
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "while true; do printf 'goal004-tcp-ok\\n' | nc -l -p 18080; done"]
      ports:
        - containerPort: 18080
          name: tcp-check
---
apiVersion: v1
kind: Pod
metadata:
  name: hk-client
  namespace: $namespace
spec:
  nodeName: $local_node
  restartPolicy: Never
  containers:
    - name: client
      image: busybox:1.36
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 3600"]
YAML
remote_ssh "kubectl -n $namespace wait --for=condition=Ready pod/us-server pod/hk-client --timeout=180s"
remote_ssh "kubectl -n $namespace get pods -o wide"
server_ip=$(remote_ssh "kubectl -n $namespace get pod us-server -o jsonpath='{.status.podIP}'")
[[ "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf '无效的远端 Pod IP: %s\n' "$server_ip" >&2; exit 1;
}
remote_ssh "kubectl -n $namespace exec hk-client -- ping -c 2 -W 2 $server_ip"
response=$(remote_ssh "kubectl -n $namespace exec hk-client -- sh -c 'printf goal004-request | nc -w 5 $server_ip 18080'")
[[ "$response" == goal004-tcp-ok ]] || { printf 'TCP 返回值异常: %s\n' "$response" >&2; exit 1; }
printf 'Goal 004 Pod TCP E2E: %s -> %s:%s, response=%s\n' "$local_node" "$server_ip" 18080 "$response"
