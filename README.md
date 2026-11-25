# capk-worker-node-images

Worker node images for [Cluster API Provider KubeVirt](https://github.com/kubernetes-sigs/cluster-api-provider-kubevirt) (CAPK), made for [Kamaji](https://kamaji.clastix.io) tenant clusters.

Built with [image-builder](https://github.com/kubernetes-sigs/image-builder) from the Ubuntu minimal cloud images, one tag per Kubernetes version. Not for control plane nodes.

```
ghcr.io/hayama17/capk-worker-node-images/ubuntu-2404-minimal:<version>
```

## Build

Run the `build` workflow with an OS and a Kubernetes version. `ubuntu-2604-minimal` is not published yet, because it does not pass the smoke test. Each build boots the disk and brings up a one-node cluster before anything is pushed. Published tags are never overwritten.
