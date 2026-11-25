# capk-worker-node-images

**Optimized [Cluster API Provider KubeVirt](https://github.com/kubernetes-sigs/cluster-api-provider-kubevirt) (CAPK) worker node images for Hosted Control Plane architectures.**

With a hosted control plane, the API server and etcd run outside the cluster's own nodes, so every VM is a worker. General-purpose node images still carry the control plane. These leave it out, at less than half the size.

[Kamaji](https://kamaji.clastix.io) is the main use case, but nothing in the images is specific to it. They only expect workers that join with kubeadm.

| v1.34.1 | Pull (compressed) | Disk |
|---|---:|---:|
| `quay.io/capk/ubuntu-2404-container-disk` | 2,167 MB | 4.38 GB |
| Ubuntu minimal as the base | 1,239 MB | 2.72 GB |
| **+ no control plane images (this repository)** | **964 MB (-56%)** | **2.18 GB (-50%)** |

```
ghcr.io/hayama17/capk-worker-node-images/ubuntu-2404-minimal:<kubernetes version>
```

[Published versions](https://github.com/hayama17/capk-worker-node-images/pkgs/container/capk-worker-node-images%2Fubuntu-2404-minimal). Pulling needs no login.

`<version>` moves to the newest build of that Kubernetes version. `<version>-<UTC time>` stays, so use it to pin or roll back.

## What makes it small

- **Minimal base.** The Ubuntu minimal cloud image, plus the packages image-builder expects and `qemu-guest-agent`.
- **No control plane images.** `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` and `etcd` are never pulled during the build. Only `kube-proxy`, CoreDNS and `pause` are preloaded.

CI fails if `kube-apiserver` or `etcd` ends up on the disk.

The price:

- These images are not meant for control plane nodes, which would have to pull everything first.
- `open-iscsi` and `nfs-common`, which some storage drivers expect on the node, are not included.

## Use

Point the `KubevirtMachineTemplate` of your workers at the tag that matches the Kubernetes version of the cluster:

```yaml
volumes:
  - name: containervolume
    containerDisk:
      image: ghcr.io/hayama17/capk-worker-node-images/ubuntu-2404-minimal:v1.37.2
      imagePullPolicy: Always # pick up rebuilds of the same tag
```

## What is inside

- Ubuntu 24.04, amd64
- kubelet, kubeadm and kubectl of the tagged version
- containerd
- `qemu-guest-agent`

## What is tested

Nothing is pushed before it passes [`smoke.sh`](smoke.sh). It boots the disk the way CAPK does, with q35 and a virtio config drive. The script then checks kubeadm, Flannel, CoreDNS, the guest agent, and signals inside a container.

It does not run Kamaji, CAPK, Cilium or storage drivers.

## Build your own

Fork the repository, enable Actions, and run the [`build`](.github/workflows/build.yml) workflow. Set `publish` to push to the GHCR of the fork.

```bash
gh workflow run build.yml -R <you>/capk-worker-node-images -f version=v1.37.2 -f publish=true
```

[`build.sh`](build.sh) drives a pinned [image-builder](https://github.com/kubernetes-sigs/image-builder). `ubuntu-2604-minimal` can be built too, but it is not published because it fails the smoke test.

## Verify

New builds carry a build provenance and an SPDX SBOM of the disk. Older ones may not.

```bash
image=oci://ghcr.io/hayama17/capk-worker-node-images/ubuntu-2404-minimal:v1.37.2
gh attestation verify "$image" --repo hayama17/capk-worker-node-images
gh attestation verify "$image" --repo hayama17/capk-worker-node-images --predicate-type https://spdx.dev/Document/v2.3
```

## License

[Apache-2.0](LICENSE). The software inside the images keeps its own licenses.
