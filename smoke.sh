#!/usr/bin/env bash
# Boot the built disk the way CAPK does (q35, config drive on virtio) and bring up a one-node cluster on it.
set -euo pipefail

name=$OS-kube-$VERSION
dir=$(mktemp -d)
mkdir -p "$dir/openstack/latest"
echo '{"uuid": "smoke", "hostname": "smoke"}' > "$dir/openstack/latest/meta_data.json"
cat > "$dir/openstack/latest/user_data" <<GUEST
#!/bin/bash
# A getty that starts later hangs up the port and kills this script
systemctl mask --runtime --now serial-getty@ttyS0
exec > /dev/ttyS0 2>&1
set -e
finish() { trap - EXIT; echo "SMOKE_RESULT=\$1"; sleep 2; poweroff -f; }
trap 'set +e; systemctl --failed --no-pager; journalctl -u kubelet -u containerd --no-pager | tail -60; kubectl get pods -A -o wide; kubectl logs dns; kubectl -n kube-system logs ds/kube-proxy --tail=40; kubectl -n kube-system logs deploy/coredns --tail=40; { journalctl -k --no-pager; cat /var/log/audit/audit.log; } | grep DENIED | tail -20; finish NG' EXIT
export KUBECONFIG=/etc/kubernetes/admin.conf
systemctl is-active qemu-guest-agent
# Nothing from the build may let anyone log in
if getent passwd builder; then exit 1; fi
if grep -qE '^[^:]+:[\$]' /etc/shadow; then exit 1; fi
mkdir -p /run/sshd
sshd -T | grep -x 'passwordauthentication no'
if ls -d /usr/lib/snapd; then exit 1; fi
containerd --version; runc --version; crictl --version; /opt/cni/bin/bridge --version
crictl images
if crictl images | grep -E '/(kube-apiserver|etcd) '; then exit 1; fi
kubeadm init --kubernetes-version $VERSION --pod-network-cidr 10.244.0.0/16
kubectl apply -f https://github.com/flannel-io/flannel/releases/download/v0.28.11/kube-flannel.yml
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl wait --for=condition=Ready node --all --timeout=5m
kubectl -n kube-system rollout status deploy/coredns --timeout=5m
# Not Docker Hub, which rate-limits shared runners
kubectl run dns --image=registry.k8s.io/e2e-test-images/agnhost:2.39 --restart=Never --command -- sh -c 'cat /proc/self/attr/current; sleep 60 & kill \$! && { nslookup kubernetes.default.svc.cluster.local || { cp /usr/bin/nslookup /tmp/copy; /tmp/copy kubernetes.default.svc.cluster.local; exit 1; }; }'
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/dns --timeout=3m
kubectl logs dns
# containerd/containerd#14485; auditd takes the denials away from the kernel log
if { journalctl -k --no-pager; cat /var/log/audit/audit.log; } | grep -E 'DENIED.*operation=.signal'; then exit 1; fi
kubectl get nodes -o wide
kubectl get pods -A -o wide
df -h /
finish OK
GUEST
xorriso -as mkisofs -quiet -V config-2 -J -r -o "$dir/config.iso" -graft-points "openstack=$dir/openstack"

touch serial.log
tail -f serial.log &
timeout 25m qemu-system-x86_64 -M q35 -accel kvm -cpu host -smp 2 -m 4096 -display none -no-reboot -snapshot \
  -serial file:serial.log \
  -drive "file=image-builder/images/capi/output/$name/$name,if=virtio,format=qcow2" \
  -drive "file=$dir/config.iso,if=virtio,format=raw,readonly=on" \
  -device pcie-root-port,id=rp1,slot=1 -netdev user,id=n0 -device virtio-net-pci,bus=rp1,netdev=n0 \
  -device virtio-serial -chardev null,id=ga -device virtserialport,chardev=ga,name=org.qemu.guest_agent.0 || true
kill %1

grep -q 'SMOKE_RESULT=OK' serial.log
