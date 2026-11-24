# capk-worker-node-images

Worker node images for [Cluster API Provider KubeVirt](https://github.com/kubernetes-sigs/cluster-api-provider-kubevirt) (CAPK), made for [Kamaji](https://kamaji.clastix.io) tenant clusters.

Built with [image-builder](https://github.com/kubernetes-sigs/image-builder) from the Ubuntu 26.04 minimal cloud image, one tag per Kubernetes version. Not for control plane nodes.

```
ghcr.io/hayama17/capk-worker-node-images/ubuntu-2604-minimal:<version>
```

## Build

Run the `build` workflow with a Kubernetes version. Each build boots the disk and brings up a one-node cluster before anything is pushed. Published tags are never overwritten.
