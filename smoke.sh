#!/usr/bin/env bash
# Boot the built disk the way CAPK does (q35, config drive on virtio) and bring up a one-node cluster on it.
set -euo pipefail

name=ubuntu-2604-minimal-kube-$VERSION
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
trap 'set +e; systemctl --failed --no-pager; journalctl -u kubelet -u containerd --no-pager | tail -60; kubectl get pods -A -o wide; finish NG' EXIT
export KUBECONFIG=/etc/kubernetes/admin.conf
systemctl is-active qemu-guest-agent
kubeadm init --kubernetes-version $VERSION --pod-network-cidr 10.244.0.0/16
kubectl apply -f https://github.com/flannel-io/flannel/releases/download/v0.28.11/kube-flannel.yml
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl wait --for=condition=Ready node --all --timeout=5m
kubectl -n kube-system rollout status deploy/coredns --timeout=5m
kubectl run dns --image=busybox:1.37 --restart=Never -- nslookup kubernetes.default.svc.cluster.local
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/dns --timeout=3m
kubectl get nodes -o wide
kubectl get pods -A -o wide
systemd-analyze
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
